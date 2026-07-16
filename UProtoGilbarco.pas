unit UProtoGilbarco;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO GILBARCO 2W (basado en UIGASGILBARCO.pas de I-Gas)
  ----------------------------------------------------------------------------
  Protocolo BINARIO de nibbles (Gilbarco Two-Wire). Baja velocidad, un solo
  BYTE DE COMANDO por transaccion:

     Byte de comando = Comando + Posicion    (posicion 16 se envia como 0)
       $0p  solicitar ESTATUS       -> resp. 1 byte (nibble alto = estatus)
       $1p  AUTORIZAR / REANUDAR    -> sin respuesta
       $2p  anuncio de DATA BLOCK   -> resp. 1 byte con nibble alto $D
       $3p  DETENER (stop)          -> sin respuesta
       $4p  LEER VENTA en tiempo real -> data block con palabras de control
       $5p  LEER TOTALIZADORES        -> data block con registros de 30/42
       $6p  VENTA EN PROCESO          -> 6/8 chars BCD (importe)
       $F0  PARO GENERAL (all stop) -> sin respuesta

  DATA BLOCK (tras un $2p aceptado, o como respuesta a $4p/$5p):

     FF  DL  <palabras de control>  FB  LRC  F0

     DL  = $E0 + complemento a 2 del nibble bajo de (longitud + 2)
     LRC = $E0 + ((suma de nibbles bajos XOR $F) + 1) and $F
           calculado sobre TODO lo anterior (FF DL ... FB)
     F0  = fin de transmision (EOT)

     Palabras de control (identificador + datos):
       F1              tipo de preset: VOLUMEN
       F2              tipo de preset: IMPORTE
       F4 / F5         nivel de precio 1 (contado) / 2 (credito)
       F6 + ($E0+g-1)  grado/manguera g
       F7 + BCD        precio (4 dig en 6 digitos, 6 dig en 8 digitos)
       F8 + BCD        monto del preset (5/6 dig o 8 dig)
       F9 + BCD        litros (lectura/total)
       FA + BCD        importe (lectura/total)
       FB              fin de datos

     BCD Gilbarco: cada DIGITO viaja en un caracter $E0+digito, el MENOS
     significativo primero (BcdToStr/BcdToInt usan solo el nibble bajo).

  Las respuestas largas no se auto-describen: usar el combo "Interpretar
  como". Divisores por defecto: todos 100 (con 8 digitos, importe y litros
  de venta usan 1000). GtwTimeout=1000 ms, GtwTiempoCmnd=100 ms.
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorGilbarco = class(TAnalizadorBase)
  private
    FBytes: array of Byte;
    function  HexTokensABytes(const s: string; var b: array of Byte;
      var n: Integer): Boolean;
    function  Hx(b: Byte): string;
    function  HxRango(a, b: Integer): string;
    function  BcdAValor(a, b: Integer): Integer;  // BcdToInt: LSB primero
    function  DescEstatusNibble(hi: Integer): string;
    procedure InterpretaComandoByte(idx: Integer);
    procedure InterpretaDataBlockTX(desde: Integer);
    procedure InterpretaEstatusRX;
    procedure InterpretaLecturaRX(ADigitos: Integer);
    procedure InterpretaTotalesRX(ADigitos: Integer);
    procedure InterpretaVentaProcesoRX(ADigitos: Integer);
    procedure ValidaLRCyEOT(desde: Integer);
  public
    function  Nombre: string; override;
    procedure CargaEjemplos(sl: TStrings); override;
    procedure CargaContextos(sl: TStrings); override;
    procedure Analiza(const AEntrada: string; AContexto: Integer); override;
  end;

implementation

function TAnalizadorGilbarco.Nombre: string;
begin
  Result := 'Gilbarco 2W';
end;

procedure TAnalizadorGilbarco.CargaContextos(sl: TStrings);
begin
  sl.Add('Auto: comando TX (consola -> dispensario)');
  sl.Add('Respuesta a: ESTATUS ($0p)');
  sl.Add('Respuesta a: anuncio de DATA BLOCK ($2p)');
  sl.Add('Respuesta a: LEER VENTA $4p (6 digitos)');
  sl.Add('Respuesta a: LEER VENTA $4p (8 digitos)');
  sl.Add('Respuesta a: TOTALIZADORES $5p (6 digitos)');
  sl.Add('Respuesta a: TOTALIZADORES $5p (8 digitos)');
  sl.Add('Respuesta a: VENTA EN PROCESO $6p (6 digitos)');
  sl.Add('Respuesta a: VENTA EN PROCESO $6p (8 digitos)');
end;

function TAnalizadorGilbarco.HexTokensABytes(const s: string;
  var b: array of Byte; var n: Integer): Boolean;
var
  lst: TStringList;
  i: Integer;
  tok, aux: string;
begin
  Result := False;
  n := 0;
  aux := StringReplace(s, ',', ' ', [rfReplaceAll]);
  aux := StringReplace(aux, #9, ' ', [rfReplaceAll]);
  aux := Trim(aux);
  if (Pos(' ', aux) = 0) and (Length(aux) > 2) and
     (Length(aux) mod 2 = 0) then begin
    tok := '';
    for i := 1 to Length(aux) do begin
      tok := tok + aux[i];
      if (i mod 2 = 0) and (i < Length(aux)) then
        tok := tok + ' ';
    end;
    aux := tok;
  end;
  lst := TStringList.Create;
  try
    lst.Delimiter := ' ';
    lst.DelimitedText := aux;
    if lst.Count = 0 then Exit;
    for i := 0 to lst.Count - 1 do begin
      tok := lst[i];
      if Length(tok) <> 2 then Exit;
      if not (tok[1] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
      if not (tok[2] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
      if n > High(b) then Exit;
      b[n] := StrToInt('$' + tok);
      Inc(n);
    end;
    Result := True;
  finally
    lst.Free;
  end;
end;

function TAnalizadorGilbarco.Hx(b: Byte): string;
begin
  Result := IntToHex(b, 2) + ' ';
end;

function TAnalizadorGilbarco.HxRango(a, b: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := a to b do
    if (i >= 0) and (i <= High(FBytes)) then
      Result := Result + Hx(FBytes[i]);
end;

// BcdToInt real: valor = suma( nibbleBajo(char[i]) * 10^(i-1) ), LSB primero
function TAnalizadorGilbarco.BcdAValor(a, b: Integer): Integer;
var
  i, m: Integer;
begin
  Result := 0;
  m := 1;
  for i := a to b do begin
    if (i < 0) or (i > High(FBytes)) then Break;
    Result := Result + (FBytes[i] and $0F) * m;
    m := m * 10;
  end;
end;

// Mapa de DameEstatus (nibble ALTO de la respuesta de 1 byte)
function TAnalizadorGilbarco.DescEstatusNibble(hi: Integer): string;
begin
  case hi of
    $0:      Result := 'SIN COMUNICACION (estatus I-Gas 0)';
    $6, $E:  Result := 'INACTIVA / Idle (estatus I-Gas 1)';
    $9, $1:  Result := 'DESPACHANDO (estatus I-Gas 2)';
    $A, $B, $3: Result := 'FIN DE VENTA (estatus I-Gas 3)';
    $7:      Result := 'PISTOLA LEVANTADA / Llamando (estatus I-Gas 5)';
    $C, $F:  Result := 'DETENIDA (estatus I-Gas 8)';
    $8:      Result := 'AUTORIZADA (estatus I-Gas 9)';
    $D:      Result := 'LISTA PARA RECIBIR DATA BLOCK (respuesta al $2p)';
  else
    Result := 'Nibble de estatus no mapeado por UIGASGILBARCO';
  end;
end;

procedure TAnalizadorGilbarco.InterpretaComandoByte(idx: Integer);
var
  cmd, p, posr: Integer;
  spos: string;
begin
  cmd  := (FBytes[idx] shr 4) and $0F;
  p    := FBytes[idx] and $0F;
  posr := p;
  if posr = 0 then posr := 16;
  spos := Format('nibble bajo %d -> posicion de carga %d (la 16 viaja como 0)',
    [p, posr]);

  FDireccion := 'TX: Consola I-Gas -> Dispensario';
  case cmd of
    $0: begin
          FTipo := Format('$0p - Solicitar ESTATUS de la posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 0 = poll de estatus; ' + spos);
          FNota := 'Respuesta de 1 byte: nibble alto = estatus, nibble ' +
            'bajo = eco de posicion. Tambien confirma la recepcion del data block del $2p.';
        end;
    $1: begin
          FTipo := Format('$1p - AUTORIZAR / REANUDAR posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 1 = autoriza el despacho (o reanuda si estaba ' +
            'detenida); ' + spos);
          FNota := 'Sin respuesta. Se envia tras el preset ($2p) para activar la bomba.';
        end;
    $2: begin
          FTipo := Format('$2p - Anuncio de DATA BLOCK para la posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 2 = "voy a enviar un data block" (preset, cambio ' +
            'de precio o nivel); ' + spos);
          FNota := 'Respuesta: 1 byte con nibble alto $D (listo). Luego se ' +
            'transmite el bloque FF..F0 y se confirma con un poll $0p.';
        end;
    $3: begin
          FTipo := Format('$3p - DETENER (stop) posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 3 = detiene el despacho en curso; ' + spos);
          FNota := 'Sin respuesta.';
        end;
    $4: begin
          FTipo := Format('$4p - LEER VENTA en tiempo real, posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 4 = solicita manguera, precio, litros e importe ' +
            'de la venta; ' + spos);
          FNota := 'Respuesta: data block con palabras F6 (manguera), F7 ' +
            '(precio), F9 (litros) y FA (importe) + LRC + F0. Minimo 33 ' +
            'bytes (6 dig) o 39 (8 dig). Reintentos por LRC: 3.';
        end;
    $5: begin
          FTipo := Format('$5p - LEER TOTALIZADORES, posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 5 = solicita los totales por manguera; ' + spos);
          FNota := 'Respuesta: byte de posicion + registros de 30 bytes ' +
            '(6 dig) o 42 (8 dig), uno por manguera, con F9 (total litros) ' +
            'y FA (total pesos).';
        end;
    $6: begin
          FTipo := Format('$6p - VENTA EN PROCESO (importe), posicion %d', [posr]);
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Nibble alto 6 = solicita solo el importe acumulado del ' +
            'despacho en curso; ' + spos);
          FNota := 'Respuesta: 6 chars BCD (6 dig) u 8 chars BCD (8 dig), ' +
            'sin LRC.';
        end;
    $F: begin
          FTipo := '$F0 - PARO GENERAL (all stop)';
          AgregaParte(Hx(FBytes[idx]), 'Byte de comando',
            'Detiene todas las posiciones de la cadena. Sin respuesta');
        end;
  else
    FTipo := Format('Comando $%x no documentado en UIGASGILBARCO (pos %d)',
      [cmd, posr]);
    AgregaParte(Hx(FBytes[idx]), 'Byte de comando', 'Nibble alto no reconocido');
  end;
end;

procedure TAnalizadorGilbarco.ValidaLRCyEOT(desde: Integer);
var
  i, suma, calc, recib: Integer;
  okEOT: Boolean;
begin
  // ValidaLRC real: suma nibbles bajos de [desde .. len-3], LRC en len-2, F0 en len-1
  if High(FBytes) - desde < 2 then Exit;
  okEOT := FBytes[High(FBytes)] = $F0;
  suma := 0;
  for i := desde to High(FBytes) - 2 do
    suma := suma + (FBytes[i] and $0F);
  calc  := ((suma xor $0F) + 1) and $0F;
  recib := FBytes[High(FBytes) - 1] and $0F;
  if okEOT and (calc = recib) then
    PonValidacion(Format('EOT $F0 presente y LRC recibido $%x = calculado ' +
      '$%x  -> BLOQUE VALIDO', [recib, calc]), True)
  else if not okEOT then
    PonValidacion('El bloque NO termina en $F0 (EOT)  -> I-Gas lo descartaria',
      False)
  else
    PonValidacion(Format('LRC recibido $%x <> calculado $%x  -> BLOQUE ' +
      'CORRUPTO (posible bit-flip; I-Gas reintenta hasta 3 veces)',
      [recib, calc]), False);
end;

procedure TAnalizadorGilbarco.InterpretaDataBlockTX(desde: Integer);
var
  i, fin, g, v, ndig: Integer;
  tipoPreset: string;
begin
  FDireccion := 'TX: Consola I-Gas -> Dispensario';
  if FTipo <> '' then
    FTipo := FTipo + '  +  DATA BLOCK'
  else
    FTipo := 'DATA BLOCK (enviado tras el anuncio $2p)';
  FNota := '';

  AgregaParte(Hx(FBytes[desde]), 'Inicio', 'FF = inicio del data block');
  if desde + 1 <= High(FBytes) then
    AgregaParte(Hx(FBytes[desde + 1]), 'DL (longitud)',
      Format('$E0 + complemento a 2 del nibble bajo de (longitud+2). ' +
        'Nibble = %d', [FBytes[desde + 1] and $0F]));

  fin := High(FBytes) - 2;  // antes de LRC y F0
  tipoPreset := '';
  i := desde + 2;
  while i <= fin do begin
    case FBytes[i] of
      $F1: begin
             AgregaParte(Hx(FBytes[i]), 'Tipo de preset',
               'F1 = preset por VOLUMEN (litros x GtwDivPresetLts=100)');
             tipoPreset := 'L';
             Inc(i);
           end;
      $F2: begin
             AgregaParte(Hx(FBytes[i]), 'Tipo de preset',
               'F2 = preset por IMPORTE (pesos x GtwDivPresetPesos=100)');
             tipoPreset := '$';
             Inc(i);
           end;
      $F4: begin
             AgregaParte(Hx(FBytes[i]), 'Nivel de precio',
               'F4 = nivel 1 (CONTADO)');
             Inc(i);
           end;
      $F5: begin
             AgregaParte(Hx(FBytes[i]), 'Nivel de precio',
               'F5 = nivel 2 (CREDITO)');
             Inc(i);
           end;
      $F6: begin
             if i + 1 <= fin then begin
               g := (FBytes[i + 1] and $0F) + 1;
               AgregaParte(HxRango(i, i + 1), 'Grado/manguera',
                 Format('F6 + ($E0 + grado - 1): grado %d', [g]));
               Inc(i, 2);
             end
             else begin
               AgregaParte(Hx(FBytes[i]), 'Grado/manguera', 'F6 truncado');
               Inc(i);
             end;
           end;
      $F7: begin
             ndig := 0;
             while (i + 1 + ndig <= fin) and
                   ((FBytes[i + 1 + ndig] and $F0) = $E0) do
               Inc(ndig);
             v := BcdAValor(i + 1, i + ndig);
             AgregaParte(HxRango(i, i + ndig), 'Precio',
               Format('F7 + %d digitos BCD (LSB primero) = %d / ' +
                 'GtwDivPrecio(100) = $%s',
                 [ndig, v, FormatFloat('#,##0.00', v / 100)]));
             Inc(i, ndig + 1);
           end;
      $F8: begin
             ndig := 0;
             while (i + 1 + ndig <= fin) and
                   ((FBytes[i + 1 + ndig] and $F0) = $E0) do
               Inc(ndig);
             v := BcdAValor(i + 1, i + ndig);
             if tipoPreset = 'L' then
               AgregaParte(HxRango(i, i + ndig), 'Monto del preset',
                 Format('F8 + %d digitos BCD (LSB primero) = %d / 100 = ' +
                   '%s L', [ndig, v, FormatFloat('#,##0.00', v / 100)]))
             else
               AgregaParte(HxRango(i, i + ndig), 'Monto del preset',
                 Format('F8 + %d digitos BCD (LSB primero) = %d / 100 = ' +
                   '$%s', [ndig, v, FormatFloat('#,##0.00', v / 100)]));
             Inc(i, ndig + 1);
           end;
      $FB: begin
             AgregaParte(Hx(FBytes[i]), 'Fin de datos', 'FB = fin de datos');
             Inc(i);
           end;
    else
      AgregaParte(Hx(FBytes[i]), 'Dato',
        'Caracter no interpretado por UIGASGILBARCO');
      Inc(i);
    end;
  end;

  if High(FBytes) >= 1 then begin
    AgregaParte(Hx(FBytes[High(FBytes) - 1]), 'LRC',
      '$E0 + ((suma de nibbles bajos XOR $F)+1) and $F, sobre FF..FB');
    AgregaParte(Hx(FBytes[High(FBytes)]), 'EOT', 'F0 = fin de transmision');
  end;
  ValidaLRCyEOT(desde);
  FNota := 'Secuencia del $2p: se envia $2p, se espera $Dp (listo), se ' +
    'transmite este bloque y se confirma con un poll $0p.';
end;

procedure TAnalizadorGilbarco.InterpretaEstatusRX;
var
  hi, lo, posr: Integer;
begin
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  FTipo := 'Respuesta a ESTATUS ($0p) - 1 byte';
  hi := (FBytes[0] shr 4) and $0F;
  lo := FBytes[0] and $0F;
  posr := lo;
  if posr = 0 then posr := 16;
  AgregaParte(Hx(FBytes[0]), 'Byte de estatus',
    Format('Nibble alto $%x: %s. Nibble bajo %d = posicion %d',
      [hi, DescEstatusNibble(hi), lo, posr]));
  FNota := 'Mapa de nibbles: $6/$E=Inactiva(1), $9/$1=Despachando(2), ' +
    '$A/$B/$3=FinDeVenta(3), $0=SinCom(0), $7=PistolaLevantada(5), ' +
    '$C/$F=Detenida(8), $8=Autorizada(9), $D=ListaParaDataBlock.';
end;

procedure TAnalizadorGilbarco.InterpretaLecturaRX(ADigitos: Integer);
var
  i, nPre, nVal, v, divi: Integer;
  visto: Boolean;
begin
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  FTipo := Format('Respuesta a LEER VENTA $4p (%d digitos)', [ADigitos]);
  if ADigitos = 8 then begin
    nPre := 6; nVal := 8; divi := 1000;
  end
  else begin
    nPre := 4; nVal := 6; divi := 100;
  end;

  AgregaParte(Hx(FBytes[0]), 'Encabezado',
    'Primer byte de la respuesta (I-Gas no lo valida en el $4p)');

  i := 1;
  visto := False;
  while i <= High(FBytes) - 2 do begin
    case FBytes[i] of
      $F6: if i + 1 <= High(FBytes) then begin
             AgregaParte(HxRango(i, i + 1), 'Manguera',
               Format('F6 + 1 digito: manguera fisica %d (valor + 1)',
                 [(FBytes[i + 1] and $0F) + 1]));
             Inc(i, 2); visto := True;
           end else Inc(i);
      $F7: begin
             v := BcdAValor(i + 1, i + nPre);
             AgregaParte(HxRango(i, i + nPre), 'Precio',
               Format('F7 + %d digitos BCD (LSB primero) = %d / ' +
                 'GtwDivPrecio(100) = $%s /L',
                 [nPre, v, FormatFloat('#,##0.00', v / 100)]));
             Inc(i, nPre + 1); visto := True;
           end;
      $F9: begin
             v := BcdAValor(i + 1, i + nVal);
             AgregaParte(HxRango(i, i + nVal), 'Litros',
               Format('F9 + %d digitos BCD (LSB primero) = %d / ' +
                 'DivLitros(%d) = %s L',
                 [nVal, v, divi, FormatFloat('#,##0.00', v / divi)]));
             Inc(i, nVal + 1); visto := True;
           end;
      $FA: begin
             v := BcdAValor(i + 1, i + nVal);
             AgregaParte(HxRango(i, i + nVal), 'Importe',
               Format('FA + %d digitos BCD (LSB primero) = %d / ' +
                 'DivImporte(%d) = $%s',
                 [nVal, v, divi, FormatFloat('#,##0.00', v / divi)]));
             Inc(i, nVal + 1); visto := True;
           end;
    else
      Inc(i);
    end;
  end;

  if not visto then
    FNota := 'No se localizaron palabras de control F6/F7/F9/FA en la trama.'
  else
    FNota := 'Cada palabra de control se localiza por busqueda, sin ' +
      'importar el offset; el resto de la trama se ignora.';

  if High(FBytes) >= 2 then begin
    AgregaParte(Hx(FBytes[High(FBytes) - 1]), 'LRC',
      'Verificado con ValidaLRC (suma de nibbles bajos)');
    AgregaParte(Hx(FBytes[High(FBytes)]), 'EOT', 'Debe ser F0');
    ValidaLRCyEOT(0);
  end;
end;

procedure TAnalizadorGilbarco.InterpretaTotalesRX(ADigitos: Integer);
var
  i, tam, nVal, v, base, nreg: Integer;
begin
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  FTipo := Format('Respuesta a TOTALIZADORES $5p (%d digitos)', [ADigitos]);
  if ADigitos = 8 then begin
    tam := 42; nVal := 12;
  end
  else begin
    tam := 30; nVal := 8;
  end;

  AgregaParte(Hx(FBytes[0]), 'Encabezado',
    'Byte de posicion (I-Gas lo elimina antes de recorrer los registros)');

  base := 1;
  nreg := 0;
  while High(FBytes) - base + 1 > tam do begin
    Inc(nreg);
    if base + 1 <= High(FBytes) then
      AgregaParte(HxRango(base, base + 1),
        Format('Registro %d: manguera', [nreg]),
        Format('El nibble bajo del 2o byte + 1 = manguera %d',
          [(FBytes[base + 1] and $0F) + 1]));
    i := base + 2;
    while i < base + tam do begin
      case FBytes[i] of
        $F9: begin
               v := BcdAValor(i + 1, i + nVal);
               AgregaParte(HxRango(i, i + nVal),
                 Format('Reg %d: total litros', [nreg]),
                 Format('F9 + %d digitos BCD = %d / GtwDivTotLts(100) = %s L',
                   [nVal, v, FormatFloat('#,##0.00', v / 100)]));
               Inc(i, nVal + 1);
             end;
        $FA: begin
               v := BcdAValor(i + 1, i + nVal);
               AgregaParte(HxRango(i, i + nVal),
                 Format('Reg %d: total pesos', [nreg]),
                 Format('FA + %d digitos BCD = %d / GtwDivTotImporte(100) ' +
                   '= $%s', [nVal, v, FormatFloat('#,##0.00', v / 100)]));
               Inc(i, nVal + 1);
             end;
      else
        Inc(i);
      end;
    end;
    Inc(base, tam);
  end;

  if base <= High(FBytes) - 2 then
    AgregaParte(HxRango(base, High(FBytes) - 2), 'Resto',
      'Bytes no interpretados');
  if High(FBytes) >= 2 then begin
    AgregaParte(Hx(FBytes[High(FBytes) - 1]), 'LRC', 'Verificado con ValidaLRC');
    AgregaParte(Hx(FBytes[High(FBytes)]), 'EOT', 'Debe ser F0');
    ValidaLRCyEOT(0);
  end;
  FNota := Format('Validacion de longitud del driver: (len - 4) mod %d = 0. ' +
    'Un registro de %d bytes por manguera; el driver lee hasta 3 mangueras.',
    [tam, tam]);
end;

procedure TAnalizadorGilbarco.InterpretaVentaProcesoRX(ADigitos: Integer);
var
  v, divi: Integer;
begin
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  FTipo := Format('Respuesta a VENTA EN PROCESO $6p (%d digitos)', [ADigitos]);
  divi := 100;
  if ADigitos = 8 then divi := 1000;
  v := BcdAValor(0, ADigitos - 1);
  AgregaParte(HxRango(0, ADigitos - 1), 'Importe en proceso',
    Format('%d digitos BCD (LSB primero) = %d / DivImporte(%d) = $%s',
      [ADigitos, v, divi, FormatFloat('#,##0.00', v / divi)]));
  FNota := 'Respuesta corta sin LRC; el driver solo valida la longitud ' +
    'exacta (6 u 8 caracteres).';
end;

procedure TAnalizadorGilbarco.Analiza(const AEntrada: string;
  AContexto: Integer);
var
  b: array[0..255] of Byte;
  n, i, ini: Integer;
begin
  Limpia;

  if not HexTokensABytes(AEntrada, b, n) then begin
    FTipo := 'Entrada no valida: capture los bytes en HEXADECIMAL ' +
      '(ej. "23 FF E2 F2 F4 F6 E1 F8 E0 E0 E0 E5 E2 E0 FB E8 F0")';
    Exit;
  end;
  if n = 0 then begin
    FTipo := 'Sin datos. Capture o pegue una trama.';
    Exit;
  end;

  SetLength(FBytes, n);
  for i := 0 to n - 1 do
    FBytes[i] := b[i];

  // ---- Contextos de respuesta
  case AContexto of
    1: begin
         if n <> 1 then begin
           FTipo := 'La respuesta de estatus es de UN solo byte.';
           Exit;
         end;
         InterpretaEstatusRX;
         Exit;
       end;
    2: begin
         if n <> 1 then begin
           FTipo := 'La respuesta al anuncio $2p es de UN solo byte.';
           Exit;
         end;
         InterpretaEstatusRX;
         if ((FBytes[0] shr 4) and $0F) = $D then
           PonValidacion('Nibble alto $D  -> el dispensario esta LISTO ' +
             'para recibir el data block', True)
         else
           PonValidacion('Nibble alto <> $D  -> el dispensario NO acepto ' +
             'el anuncio; I-Gas abortaria el envio del bloque', False);
         Exit;
       end;
    3: begin InterpretaLecturaRX(6); Exit; end;
    4: begin InterpretaLecturaRX(8); Exit; end;
    5: begin InterpretaTotalesRX(6); Exit; end;
    6: begin InterpretaTotalesRX(8); Exit; end;
    7: begin InterpretaVentaProcesoRX(6); Exit; end;
    8: begin InterpretaVentaProcesoRX(8); Exit; end;
  end;

  // ---- Auto: TX
  if n = 1 then begin
    InterpretaComandoByte(0);
    Exit;
  end;

  ini := 0;
  if FBytes[0] <> $FF then begin
    // byte de comando + data block
    InterpretaComandoByte(0);
    if (n > 1) and (FBytes[1] = $FF) then
      ini := 1
    else begin
      FTipo := FTipo + ' + datos no reconocidos';
      AgregaParte(HxRango(1, n - 1), 'Datos',
        'Se esperaba un data block iniciando en FF');
      Exit;
    end;
  end;

  // Reinterpretar solo el bloque, conservando el byte de comando como parte
  if ini = 1 then begin
    // desplazar: el data block se interpreta desde ini
    InterpretaDataBlockTX(ini);
  end
  else
    InterpretaDataBlockTX(0);
end;

procedure TAnalizadorGilbarco.CargaEjemplos(sl: TStrings);
begin
  // TX: bytes de comando sueltos
  sl.Add('01');                                        // poll estatus pos 1
  sl.Add('12');                                        // autorizar pos 2
  sl.Add('33');                                        // detener pos 3
  sl.Add('44');                                        // leer venta pos 4
  sl.Add('55');                                        // totales pos 5
  sl.Add('66');                                        // venta en proceso pos 6
  sl.Add('10');                                        // autorizar pos 16 (0)
  sl.Add('F0');                                        // paro general
  // TX: anuncio + data block (LRC/DL calculados con el algoritmo real)
  sl.Add('23 FF E2 F2 F4 F6 E1 F8 E0 E0 E0 E5 E2 E0 FB E8 F0'); // preset $250.00 grado 2 pos 3
  sl.Add('23 FF E3 F1 F4 F6 E1 F8 E0 E0 E0 E4 E0 FB EB F0');    // preset 40.00 L grado 2 pos 3
  sl.Add('24 FF E5 F4 F6 E0 F7 E0 E5 E1 E2 FB E8 F0');          // precio $21.50 nivel 1 m1 pos 4
  sl.Add('24 FF E5 F5 F6 E0 F7 E0 E5 E1 E2 FB E7 F0');          // precio $21.50 nivel 2 m1 pos 4
  sl.Add('25 FF EC F4 FB E6 F0');                               // nivel de precio contado pos 5
  // RX de 1 byte (contexto: ESTATUS / DATA BLOCK)
  sl.Add('63');                                        // inactiva pos 3
  sl.Add('91');                                        // despachando pos 1
  sl.Add('75');                                        // pistola levantada pos 5
  sl.Add('82');                                        // autorizada pos 2
  sl.Add('A4');                                        // fin de venta pos 4
  sl.Add('C2');                                        // detenida pos 2
  sl.Add('06');                                        // sin comunicacion pos 6
  sl.Add('D3');                                        // lista para data block pos 3
  // RX largas (elegir el contexto en el combo)
  sl.Add('A1 F6 E1 F7 E0 E5 E1 E2 F9 E0 E5 E5 E2 E0 E0 FA E5 E2 E8 E4 E5 ' +
    'E0 E0 E0 E0 E0 E0 E0 E0 E0 E0 E2 F0');            // $4p 6dig: m2 $21.50 25.50L $548.25
  sl.Add('E1 E0 E0 F9 E6 E5 E4 E3 E2 E1 E0 E0 FA E1 E2 E3 E4 E5 E6 E2 E0 ' +
    'E0 E0 E0 E0 E0 E0 E0 E0 E0 E0 E0 E0 F0');         // $5p 6dig: m1 1,234.56 L / $26,543.21
  sl.Add('E0 E5 E2 E1 E0 E0');                         // $6p 6dig: $12.50
  // LRC incorrecto a proposito (real E8)
  sl.Add('23 FF E2 F2 F4 F6 E1 F8 E0 E0 E0 E5 E2 E0 FB E9 F0');
end;

end.
