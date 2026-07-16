unit UProtoWayne2W;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO WAYNE 2W (basado en UIGASWAYNE2W.pas de I-Gas)
  ----------------------------------------------------------------------------
  Protocolo BINARIO. Cada byte de datos viaja seguido de su complemento a 255:

     Trama TX/RX =  00 00  [D1 ~D1] [D2 ~D2] ... [Dn ~Dn]  FF
       - Comandos de datos: n=5  (trama de 13 bytes)
       - Sondeo de estatus: n=1  (trama de 5 bytes)
       - TODA respuesta valida mide 13 bytes (5 bytes de datos)

  Byte de control (D1) = Posicion*8 + Comando   (pos<=31, cmd<=7)
     cmd 1 = solicitar ESTATUS (trama de 1 byte de datos)
     cmd 0 = operaciones de control:  D2 = byte de operacion
              97h reanudar | A7h detener | 8Fh autorizar todas
              88h+n autorizar solo manguera fisica n+1
     cmd 7 = leer/escribir registros: D2 = registro
              00h leer precio (D3 = manguera fisica - 1)
              01h cambiar precio (D3 = mang-1 nivel1 / 16+mang-1 nivel2;
                                  D4=LSB D5=MSB, binario, centavos)
              21h preset por importe (D3..D5 = BCD LSB-first, x DivImporte)
              23h preset por litros  (D3..D5 = BCD LSB-first, x DivLitros)
              2Ah leer importe venta (resp: BCD D3..D5 / DivImporte)
              26h leer volumen venta (resp: BCD D3..D5 / DivLitros)
              04h/02h/16h totalizador parte 1/2/3 (D3 = 2Fh + mang fisica;
                          resp: BCD D4..D5; total=(p1+p2*1e4+p3*1e8)/100)

  Como las respuestas no se auto-describen, el combo "Interpretar como"
  permite elegir el contexto de la respuesta.
  Divisores por defecto: WtwDivImporte=100, WtwDivLitros=100.
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorWayne2W = class(TAnalizadorBase)
  private
    FBytes : array of Byte;    // bytes de DATOS (ya desempacados)
    FChunk : array of string;  // texto hex mostrado por cada byte de datos
    function  HexTokensABytes(const s: string; var b: array of Byte;
      var n: Integer): Boolean;
    function  ChunkRango(a, b: Integer): string;
    function  BCDDigitos(const idx: array of Integer): string; // MSB->LSB
    function  DescEstatusIGas(e: Integer): string;
    procedure InterpretaTX;
    procedure InterpretaRX(AContexto: Integer);
    procedure DecodificaEstatus(bSt: Byte);
  public
    function  Nombre: string; override;
    function  EsHexPuro: Boolean; override;
    procedure CargaEjemplos(sl: TStrings); override;
    procedure CargaContextos(sl: TStrings); override;
    procedure Analiza(const AEntrada: string; AContexto: Integer); override;
  end;

implementation

function TAnalizadorWayne2W.EsHexPuro: Boolean;
begin
  Result := True;   // protocolo binario: todo el texto es hex, sin ambiguedad con ASCII
end;

function TAnalizadorWayne2W.Nombre: string;
begin
  Result := 'Wayne 2W';
end;

procedure TAnalizadorWayne2W.CargaContextos(sl: TStrings);
begin
  sl.Add('Auto: comando TX (consola -> dispensario)');
  sl.Add('Respuesta a: ESTATUS (cmd 1)');
  sl.Add('Respuesta a: leer PRECIO (reg 00h)');
  sl.Add('Respuesta a: leer IMPORTE de venta (reg 2Ah)');
  sl.Add('Respuesta a: leer VOLUMEN de venta (reg 26h)');
  sl.Add('Respuesta a: TOTALIZADOR parte 1/2/3');
end;

function TAnalizadorWayne2W.HexTokensABytes(const s: string;
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
  // hex continuo sin espacios -> insertar espacios cada 2
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

function TAnalizadorWayne2W.ChunkRango(a, b: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := a to b do
    if i <= High(FChunk) then
      Result := Result + FChunk[i];
end;

// Concatena los digitos BCD de los bytes indicados (orden: MSB -> LSB)
function TAnalizadorWayne2W.BCDDigitos(const idx: array of Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(idx) do
    if idx[i] <= High(FBytes) then
      Result := Result + IntToHex(FBytes[idx[i]], 2);
end;

function TAnalizadorWayne2W.DescEstatusIGas(e: Integer): string;
begin
  case e of
    0: Result := 'Sin comunicacion';
    1: Result := 'Inactiva (Idle)';
    2: Result := 'Despachando';
    3: Result := 'Fin de venta';
    5: Result := 'Pistola levantada (Calling)';
    8: Result := 'Detenida';
    9: Result := 'Autorizada';
  else
    Result := 'Desconocido';
  end;
end;

procedure TAnalizadorWayne2W.DecodificaEstatus(bSt: Byte);
var
  bit: array[0..7] of Boolean;
  i, mang: Integer;
  ss: string;
begin
  for i := 0 to 7 do
    bit[i] := (bSt and (1 shl i)) <> 0;
  mang := (bSt and 7);   // campo de manguera (bits 0..2)

  ss := 'Bits: ';
  for i := 7 downto 0 do
    if bit[i] then ss := ss + '1' else ss := ss + '0';
  ss := ss + '. ';

  if bit[7] then begin
    if mang = 7 then
      ss := ss + 'Motor encendido con mangueras colgadas: FIN DE VENTA ' +
        '(si ya hubo importe) o AUTORIZADA (importe=0).'
    else
      ss := ss + Format('DESPACHANDO con manguera fisica %d.', [mang + 1]);
    if bit[4] then
      ss := ss + ' Ademas bit4=1: DETENIDA.';
  end
  else if bit[3] then
    ss := ss + 'AUTORIZADA (bit3), esperando levantar pistola.'
  else if bit[4] then
    ss := ss + 'DETENIDA en fin de venta (I-Gas envia Reanudar y la ' +
      'pasa a Fin de Venta).'
  else if mang <> 7 then
    ss := ss + Format('PISTOLA LEVANTADA: manguera fisica %d ' +
      '(bits 0-2 + 1). Solicita autorizacion.', [mang + 1])
  else
    ss := ss + 'INACTIVA: todas las mangueras colgadas (bits 0-2 = 111).';

  AgregaParte(FChunk[4], 'Byte de estatus', ss);
  FNota := 'Estatus interno I-Gas Wayne: 0=SinCom, 1=Inactiva, ' +
    '2=Despachando, 3=FinVenta, 5=PistolaLevantada, 8=Detenida, ' +
    '9=Autorizada (numeracion distinta a Bennett).';
end;

procedure TAnalizadorWayne2W.InterpretaTX;
var
  ctrl, pos, cmd, op, reg, mang: Integer;
  v: Integer;
  digs: string;
begin
  ctrl := FBytes[0];
  pos  := ctrl div 8;
  cmd  := ctrl mod 8;

  FDireccion := 'TX: Consola I-Gas -> Dispensario';
  AgregaParte(FChunk[0], 'Byte de control',
    Format('$%s = Posicion %d x 8 + Comando %d (bits 7-3 = posicion, ' +
      'bits 2-0 = comando)', [IntToHex(ctrl, 2), pos, cmd]));

  // ---- Sondeo de estatus: 1 solo byte de datos
  if Length(FBytes) = 1 then begin
    if cmd = 1 then
      FTipo := Format('Cmd 1 - SOLICITA ESTATUS de la posicion %d', [pos])
    else
      FTipo := Format('Comando corto %d no documentado (posicion %d)',
        [cmd, pos]);
    Exit;
  end;

  case cmd of
    0: begin
         op := FBytes[1];
         case op of
           $97: begin
                  FTipo := Format('Cmd 0 / op 97h - REANUDAR despacho Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Operacion',
                    '97h = reanudar el despacho detenido');
                end;
           $A7: begin
                  FTipo := Format('Cmd 0 / op A7h - DETENER despacho Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Operacion',
                    'A7h = detener el despacho en curso (paro)');
                end;
           $8F: begin
                  FTipo := Format('Cmd 0 / op 8Fh - AUTORIZAR Pos %d (todas las mangueras)', [pos]);
                  AgregaParte(FChunk[1], 'Operacion',
                    '8Fh = autorizar; selector de manguera = 7 (todas)');
                end;
         else
           if (op >= $88) and (op <= $8E) then begin
             mang := op - $88 + 1;
             FTipo := Format('Cmd 0 - AUTORIZAR Pos %d SOLO manguera fisica %d',
               [pos, mang]);
             AgregaParte(FChunk[1], 'Operacion',
               Format('$%s = 88h + %d: autoriza restringiendo a la manguera ' +
                 'fisica %d', [IntToHex(op, 2), mang - 1, mang]));
           end
           else begin
             FTipo := Format('Cmd 0 - operacion de control $%s no documentada (Pos %d)',
               [IntToHex(op, 2), pos]);
             AgregaParte(FChunk[1], 'Operacion', 'Byte de operacion no reconocido');
           end;
         end;
         AgregaParte(ChunkRango(2, 4), 'Relleno', 'Bytes en cero (no usados)');
       end;

    7: begin
         reg := FBytes[1];
         case reg of
           $00: begin
                  FTipo := Format('Cmd 7 / reg 00h - LEER PRECIO Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro', '00h = lectura de precio');
                  AgregaParte(FChunk[2], 'Manguera',
                    Format('Manguera fisica - 1 = %d -> manguera %d',
                      [FBytes[2], FBytes[2] + 1]));
                  AgregaParte(ChunkRango(3, 4), 'Relleno', 'Bytes en cero');
                  FNota := 'La respuesta trae el precio BINARIO en D4(LSB) y ' +
                    'D5(MSB): precio = (256*D5 + D4) / 100.';
                end;
           $01: begin
                  FTipo := Format('Cmd 7 / reg 01h - CAMBIAR PRECIO Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro', '01h = escritura de precio');
                  if FBytes[2] >= 16 then
                    AgregaParte(FChunk[2], 'Manguera/nivel',
                      Format('16 + manguera-1 = %d -> manguera fisica %d, ' +
                        'NIVEL 2 (credito)', [FBytes[2], FBytes[2] - 16 + 1]))
                  else
                    AgregaParte(FChunk[2], 'Manguera/nivel',
                      Format('manguera-1 = %d -> manguera fisica %d, ' +
                        'NIVEL 1 (contado)', [FBytes[2], FBytes[2] + 1]));
                  v := 256 * FBytes[4] + FBytes[3];
                  AgregaParte(ChunkRango(3, 4), 'Precio',
                    Format('Binario LSB,MSB = %d centavos = $%s',
                      [v, FormatFloat('#,##0.00', v / 100)]));
                  FNota := 'I-Gas envia el cambio dos veces: nivel 1 (D3=mang-1) ' +
                    'e inmediatamente nivel 2 (D3=16+mang-1).';
                end;
           $21: begin
                  FTipo := Format('Cmd 7 / reg 21h - PRESET por IMPORTE Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro', '21h = preset por importe');
                  digs := BCDDigitos([4, 3, 2]);
                  AgregaParte(ChunkRango(2, 4), 'Importe BCD',
                    Format('BCD LSB-first = %s -> $%s (valor / DivImporte=100)',
                      [digs, FormatFloat('#,##0.00',
                        StrToIntDef(digs, 0) / 100)]));
                end;
           $23: begin
                  FTipo := Format('Cmd 7 / reg 23h - PRESET por LITROS Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro', '23h = preset por volumen');
                  digs := BCDDigitos([4, 3, 2]);
                  AgregaParte(ChunkRango(2, 4), 'Litros BCD',
                    Format('BCD LSB-first = %s -> %s L (valor / DivLitros=100)',
                      [digs, FormatFloat('#,##0.00',
                        StrToIntDef(digs, 0) / 100)]));
                end;
           $2A: begin
                  FTipo := Format('Cmd 7 / reg 2Ah - LEER IMPORTE de venta Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro',
                    '2Ah = lectura del importe de la venta en curso/final');
                  AgregaParte(ChunkRango(2, 4), 'Relleno', 'Bytes en cero');
                  FNota := 'La respuesta trae el importe BCD en D3..D5 ' +
                    '(LSB primero) dividido entre DivImporte (100).';
                end;
           $26: begin
                  FTipo := Format('Cmd 7 / reg 26h - LEER VOLUMEN de venta Pos %d', [pos]);
                  AgregaParte(FChunk[1], 'Registro',
                    '26h = lectura del volumen de la venta en curso/final');
                  AgregaParte(ChunkRango(2, 4), 'Relleno', 'Bytes en cero');
                  FNota := 'La respuesta trae el volumen BCD en D3..D5 ' +
                    '(LSB primero) dividido entre DivLitros (100).';
                end;
           $04, $02, $16: begin
                  case reg of
                    $04: FTipo := Format('Cmd 7 / reg 04h - TOTALIZADOR parte 1 (digitos bajos) Pos %d', [pos]);
                    $02: FTipo := Format('Cmd 7 / reg 02h - TOTALIZADOR parte 2 (digitos medios) Pos %d', [pos]);
                    $16: FTipo := Format('Cmd 7 / reg 16h - TOTALIZADOR parte 3 (digitos altos) Pos %d', [pos]);
                  end;
                  AgregaParte(FChunk[1], 'Registro',
                    'Registro de totalizador (04h/02h/16h = parte 1/2/3)');
                  AgregaParte(FChunk[2], 'Manguera',
                    Format('2Fh + manguera fisica = $%s -> manguera %d',
                      [IntToHex(FBytes[2], 2), FBytes[2] - $2F]));
                  AgregaParte(ChunkRango(3, 4), 'Relleno', 'Bytes en cero');
                  FNota := 'Total litros = (parte1 + parte2*10^4 + ' +
                    'parte3*10^8) / 100. Cada parte llega BCD en D4..D5.';
                end;
         else
           FTipo := Format('Cmd 7 - registro $%s no documentado (Pos %d)',
             [IntToHex(reg, 2), pos]);
           AgregaParte(FChunk[1], 'Registro', 'Registro no reconocido');
           AgregaParte(ChunkRango(2, 4), 'Datos', 'Parametros del registro');
         end;
       end;
  else
    FTipo := Format('Comando %d no documentado en UIGASWAYNE2W (Pos %d)',
      [cmd, pos]);
    AgregaParte(ChunkRango(1, 4), 'Datos', 'Bytes de parametros');
  end;
end;

procedure TAnalizadorWayne2W.InterpretaRX(AContexto: Integer);
var
  v: Integer;
  digs: string;
begin
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  AgregaParte(FChunk[0], 'Byte 1',
    'Eco/encabezado de la respuesta (no interpretado por I-Gas)');

  case AContexto of
    1: begin // Estatus
         FTipo := 'Respuesta a ESTATUS (cmd 1)';
         AgregaParte(ChunkRango(1, 3), 'Bytes 2-4',
           'Datos no interpretados por I-Gas para el estatus');
         DecodificaEstatus(FBytes[4]);
       end;
    2: begin // Precio
         FTipo := 'Respuesta a LEER PRECIO (reg 00h)';
         AgregaParte(ChunkRango(1, 2), 'Bytes 2-3', 'No usados en esta lectura');
         v := 256 * FBytes[4] + FBytes[3];
         AgregaParte(ChunkRango(3, 4), 'Precio',
           Format('BINARIO: 256*D5 + D4 = %d centavos = $%s /L',
             [v, FormatFloat('#,##0.00', v / 100)]));
       end;
    3: begin // Importe
         FTipo := 'Respuesta a LEER IMPORTE (reg 2Ah)';
         AgregaParte(ChunkRango(1, 1), 'Byte 2', 'Eco del registro');
         digs := BCDDigitos([4, 3, 2]);
         AgregaParte(ChunkRango(2, 4), 'Importe BCD',
           Format('D3..D5 BCD LSB-first = %s -> $%s (entre DivImporte=100)',
             [digs, FormatFloat('#,##0.00', StrToIntDef(digs, 0) / 100)]));
       end;
    4: begin // Volumen
         FTipo := 'Respuesta a LEER VOLUMEN (reg 26h)';
         AgregaParte(ChunkRango(1, 1), 'Byte 2', 'Eco del registro');
         digs := BCDDigitos([4, 3, 2]);
         AgregaParte(ChunkRango(2, 4), 'Volumen BCD',
           Format('D3..D5 BCD LSB-first = %s -> %s L (entre DivLitros=100)',
             [digs, FormatFloat('#,##0.00', StrToIntDef(digs, 0) / 100)]));
       end;
    5: begin // Totalizador
         FTipo := 'Respuesta a TOTALIZADOR (parte 1/2/3)';
         AgregaParte(ChunkRango(1, 2), 'Bytes 2-3',
           'Eco de registro y manguera');
         digs := BCDDigitos([4, 3]);
         AgregaParte(ChunkRango(3, 4), 'Parte del total',
           Format('D4..D5 BCD LSB-first = %s (4 digitos de esta parte)',
             [digs]));
         FNota := 'Total litros = (parte1 + parte2*10^4 + parte3*10^8)/100. ' +
           'Se requieren las 3 lecturas para armar el total completo.';
       end;
  end;
end;

procedure TAnalizadorWayne2W.Analiza(const AEntrada: string;
  AContexto: Integer);
var
  b: array[0..63] of Byte;
  n, i, nd: Integer;
  empacada, paresOk: Boolean;
begin
  Limpia;

  if not HexTokensABytes(AEntrada, b, n) then begin
    FTipo := 'Entrada no valida: capture los bytes en HEXADECIMAL ' +
      '(ej. "00 00 1F E0 21 DE 00 FF 00 FF 05 FA FF")';
    Exit;
  end;
  if n = 0 then begin
    FTipo := 'Sin datos. Capture o pegue una trama.';
    Exit;
  end;

  // ---- Detectar trama empacada: 00 00 [pares] FF (5 o 13 bytes)
  empacada := (n in [5, 13]) and (b[0] = 0) and (b[1] = 0) and (b[n - 1] = $FF);

  if empacada then begin
    nd := (n - 3) div 2;
    SetLength(FBytes, nd);
    SetLength(FChunk, nd);
    paresOk := True;
    for i := 0 to nd - 1 do begin
      FBytes[i] := b[2 + i * 2];
      FChunk[i] := IntToHex(b[2 + i * 2], 2) + ' ' +
                   IntToHex(b[3 + i * 2], 2) + ' ';
      if (b[2 + i * 2] + b[3 + i * 2]) <> 255 then
        paresOk := False;
    end;
    FPrefijo := '00 00 ';
    FSufijo  := 'FF';
    if paresOk then
      PonValidacion('Complementos byte+inverso = FFh en los ' +
        IntToStr(nd) + ' pares  -> TRAMA VALIDA', True)
    else
      PonValidacion('Algun par byte+inverso NO suma FFh  -> TRAMA CORRUPTA ' +
        '(I-Gas la descartaria)', False);
  end
  else begin
    // ---- Bytes de datos ya desempacados (1 o 5 bytes)
    if not (n in [1, 5]) then begin
      FTipo := Format('Longitud %d no valida. Se esperan tramas empacadas ' +
        'de 5/13 bytes (00 00 ... FF) o datos crudos de 1/5 bytes.', [n]);
      Exit;
    end;
    SetLength(FBytes, n);
    SetLength(FChunk, n);
    for i := 0 to n - 1 do begin
      FBytes[i] := b[i];
      FChunk[i] := IntToHex(b[i], 2) + ' ';
    end;
    FNota := 'Datos sin empacar. En el cable cada byte viaja seguido de su ' +
      'complemento a 255, con prefijo 00 00 y terminador FF.';
  end;

  // ---- Interpretar segun contexto
  if (AContexto <= 0) or (Length(FBytes) = 1) then
    InterpretaTX
  else begin
    if Length(FBytes) < 5 then begin
      FTipo := 'Una respuesta valida trae 5 bytes de datos (13 en el cable).';
      Exit;
    end;
    InterpretaRX(AContexto);
  end;
end;

procedure TAnalizadorWayne2W.CargaEjemplos(sl: TStrings);
begin
  // TX empacados
  sl.Add('00 00 09 F6 FF');                                        // poll estatus pos1
  sl.Add('00 00 08 F7 8F 70 00 FF 00 FF 00 FF FF');                // autorizar todas pos1
  sl.Add('00 00 08 F7 89 76 00 FF 00 FF 00 FF FF');                // autorizar mang 2 pos1
  sl.Add('00 00 10 EF A7 58 00 FF 00 FF 00 FF FF');                // detener pos2
  sl.Add('00 00 10 EF 97 68 00 FF 00 FF 00 FF FF');                // reanudar pos2
  sl.Add('00 00 1F E0 21 DE 00 FF 00 FF 05 FA FF');                // preset $500 pos3
  sl.Add('00 00 1F E0 23 DC 00 FF 40 BF 00 FF FF');                // preset 40L pos3
  sl.Add('00 00 27 D8 00 FF 00 FF 00 FF 00 FF FF');                // leer precio m1 pos4
  sl.Add('00 00 27 D8 01 FE 01 FE 1E E1 0A F5 FF');                // cambiar precio $25.90 n1
  sl.Add('00 00 27 D8 01 FE 11 EE 1E E1 0A F5 FF');                // cambiar precio $25.90 n2
  sl.Add('00 00 2F D0 2A D5 00 FF 00 FF 00 FF FF');                // leer importe pos5
  sl.Add('00 00 2F D0 26 D9 00 FF 00 FF 00 FF FF');                // leer volumen pos5
  sl.Add('00 00 37 C8 04 FB 30 CF 00 FF 00 FF FF');                // total p1 m1 pos6
  // RX empacados (usar el combo "Interpretar como")
  sl.Add('00 00 09 F6 00 FF 00 FF 00 FF 80 7F FF');                // estatus: despachando m1
  sl.Add('00 00 09 F6 00 FF 00 FF 00 FF 07 F8 FF');                // estatus: inactiva
  sl.Add('00 00 09 F6 00 FF 00 FF 00 FF 08 F7 FF');                // estatus: autorizada
  sl.Add('00 00 27 D8 00 FF 00 FF CA 35 08 F7 FF');                // precio $22.50
  sl.Add('00 00 2F D0 2A D5 67 98 45 BA 03 FC FF');                // importe $345.67
  sl.Add('00 00 2F D0 26 D9 12 ED 20 DF 00 FF FF');                // volumen 20.12L
  sl.Add('00 00 37 C8 04 FB 30 CF 34 CB 12 ED FF');                // total parte1 = 1234
  // Datos crudos (sin empacar)
  sl.Add('1F 21 00 00 05');                                        // preset $500 crudo
  sl.Add('09');                                                    // poll crudo
end;

end.
