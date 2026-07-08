unit UProtoPam;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO PAM 1000 (basado en UIGASPAM.pas de I-Gas)
  ----------------------------------------------------------------------------
  Trama:  <STX> payload <ETX> BCC
          STX=#2  ETX=#3   BCC = XOR de todos los bytes de (payload + ETX)
          (OJO: a diferencia de Bennett, que usa suma+complemento, PAM usa XOR)
  Protocolo ASCII. ACK=#6 / NAK=#21 como respuestas de un byte.

  Comandos TX (Consola I-Gas -> PAM):
    B00                 poll de estatus de todas las posiciones
    A + pos(2)          solicita lectura de venta de una posicion
    T + pos(2) + nivel  nivel de precios activo (1=cash) - responde ACK
    D0 + setup          setup PAM1000 (p.ej. D06222 en version 3)
    L + pos(2)          OPEN PUMP (abre una posicion cerrada, estatus 6)
    G + pos(2)          RESTART (reanuda una posicion detenida)
    E + pos(2)          STOP / desautoriza  (E00 = PARO TOTAL)
    S + pos(2)          autoriza sin limite (preset "abierto")
    R + pos(2)          VENTA COMPLETA (cierra la transaccion, tras FINV)
    X + 00 + comb + nivel + 00 + precio(4)      cambio de precio (centavos)
    P + pos(2) + tipo + nivel + relleno + valor(5) + grado   preset v1
    @02 + 0 + pos(2) + tipo + nivel + valor(6) + prodauto(6) preset v3
    @10 + 0 + pos(2)    solicita totalizadores (version 3)
    C + pos(2) + comb + 1   solicita total de una pistola (versiones <> 3)

  Respuestas RX (PAM -> Consola I-Gas):
    B00 + digitos       un digito de estatus por posicion
    A + pos(2) + ...    lectura de venta (cargando / concluida / no mapeada)
    C + pos(2) + ...    total de una pistola
    @10 ...             totales de la posicion (version 3, hasta 4 productos)
    ACK / NAK

  Divisores por defecto (variables INITIALIZE): DigitosVolumen=2 (vol/1000),
  DigitosPrecio=1 (precio/100), DigitosImporte=2 (importe/1000).
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorPam = class(TAnalizadorBase)
  private
    function CalculaBCC(const ss: string): Char;   // XOR, algoritmo real
    function DescEstatus(const c: Char): string;
    function DigitosAValor(const s: string; ADiv: Integer;
      ADecimales: Integer): string;
    function NormalizaEntrada(const s: string): string;
    procedure InterpretaPayload(const lin: string);
    procedure InterpretaB(const lin: string);
    procedure InterpretaA(const lin: string);
    procedure InterpretaC(const lin: string);
    procedure InterpretaArroba(const lin: string);
  public
    function  Nombre: string; override;
    procedure CargaEjemplos(sl: TStrings); override;
    procedure Analiza(const AEntrada: string; AContexto: Integer); override;
  end;

implementation

const
  idSTX = #2;
  idETX = #3;
  idACK = #6;
  idNAK = #21;

function TAnalizadorPam.Nombre: string;
begin
  Result := 'PAM 1000';
end;

// BCC real de UIGASPAM: XOR encadenado de todos los caracteres
function TAnalizadorPam.CalculaBCC(const ss: string): Char;
var
  i: Integer;
  x: Byte;
begin
  x := 0;
  for i := 1 to Length(ss) do
    x := x xor Ord(ss[i]);
  Result := Char(x);
end;

function TAnalizadorPam.DescEstatus(const c: Char): string;
begin
  case c of
    '0': Result := 'Sin comunicacion (OFFLINE)';
    '1': Result := 'Inactivo (IDLE)';
    '2': Result := 'Despachando (BUSY)';
    '3': Result := 'Fin de venta (EOT)';
    '5': Result := 'Pistola levantada (CALL)';
    '6': Result := 'Cerrada (CLOSED) - I-Gas envia L.. para abrirla';
    '8': Result := 'Detenida (STOP)';
    '9': Result := 'Autorizada (AUTHORIZED)';
  else
    Result := 'Desconocido';
  end;
end;

// Convierte digitos ASCII a valor con divisor (10^n) y n decimales visibles
function TAnalizadorPam.DigitosAValor(const s: string; ADiv: Integer;
  ADecimales: Integer): string;
var
  v: Double;
begin
  Result := s;
  try
    v := StrToFloat(s) / ADiv;
    Result := FormatFloat('#,##0.' + StringOfChar('0', ADecimales), v);
  except
    Result := s;
  end;
end;

function TAnalizadorPam.NormalizaEntrada(const s: string): string;

  function EsHexDump(const x: string; var salida: string): Boolean;
  var
    lst: TStringList;
    i, b: Integer;
    tok, aux: string;
    tieneCtrl: Boolean;
  begin
    Result := False;
    salida := '';
    aux := StringReplace(x, ',', ' ', [rfReplaceAll]);
    aux := StringReplace(aux, #9, ' ', [rfReplaceAll]);
    lst := TStringList.Create;
    try
      lst.Delimiter := ' ';
      lst.DelimitedText := Trim(aux);
      if lst.Count < 2 then Exit;
      tieneCtrl := False;
      for i := 0 to lst.Count - 1 do begin
        tok := lst[i];
        if Length(tok) <> 2 then Exit;
        if not (tok[1] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
        if not (tok[2] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
        b := StrToInt('$' + tok);
        if b in [2, 3, 6, 21] then
          tieneCtrl := True;
        salida := salida + Char(b);
      end;
      Result := tieneCtrl;
      if not Result then
        salida := '';
    finally
      lst.Free;
    end;
  end;

var
  r, hx: string;
begin
  r := Trim(s);
  r := StringReplace(r, '<STX>', idSTX, [rfReplaceAll, rfIgnoreCase]);
  r := StringReplace(r, '<ETX>', idETX, [rfReplaceAll, rfIgnoreCase]);
  r := StringReplace(r, '<ACK>', idACK, [rfReplaceAll, rfIgnoreCase]);
  r := StringReplace(r, '<NAK>', idNAK, [rfReplaceAll, rfIgnoreCase]);
  if EsHexDump(r, hx) then
    r := hx;
  Result := r;
end;

procedure TAnalizadorPam.InterpretaB(const lin: string);
var
  ss: string;
  xpos: Integer;
begin
  if Length(lin) <= 3 then begin
    FTipo      := 'B - Sondeo de estatus de TODAS las posiciones (poll)';
    FDireccion := 'TX: Consola I-Gas -> PAM';
    AgregaParte(lin[1], 'Comando', 'Letra "B": solicita el estatus global');
    if Length(lin) >= 3 then
      AgregaParte(Copy(lin, 2, 2), 'Direccion',
        '"00" = difusion (todas las posiciones). Enviado cada ciclo del Timer1');
    Exit;
  end;

  FTipo      := 'B - Respuesta: estatus de todas las posiciones';
  FDireccion := 'RX: PAM -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "B" (estatus global)');
  AgregaParte(Copy(lin, 2, 2), 'Direccion', 'Eco de "00"');

  ss := Copy(lin, 4, Length(lin) - 3);
  FNota := Format('La respuesta reporta %d posiciones de carga ' +
    '(UN digito de estatus por posicion, a diferencia de Bennett que usa 2).',
    [Length(ss)]);
  for xpos := 1 to Length(ss) do
    AgregaParte(ss[xpos], Format('Posicion %.2d', [xpos]),
      Format('Estatus %s: %s', [ss[xpos], DescEstatus(ss[xpos])]));
end;

procedure TAnalizadorPam.InterpretaA(const lin: string);
var
  vol, imp, pre, relleno: string;
begin
  if Length(lin) <= 3 then begin
    FTipo      := 'A - Solicita LECTURA de venta de una posicion';
    FDireccion := 'TX: Consola I-Gas -> PAM';
    AgregaParte(lin[1], 'Comando',
      'Solicita volumen, importe y precio de la venta en curso/concluida');
    AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    Exit;
  end;

  FDireccion := 'RX: PAM -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "A" (lectura de venta)');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');

  if lin[4] = '0' then begin
    FTipo := 'A - Respuesta: posicion CARGANDO (despachando)';
    AgregaParte(lin[4], 'Indicador',
      '"0" = la posicion esta cargando; solo se lee el importe parcial');
    relleno := Copy(lin, 5, 9);
    if relleno <> '' then
      AgregaParte(relleno, 'No leido',
        'Caracteres [5..13] no interpretados por I-Gas durante la carga');
    imp := Copy(lin, 14, 8);
    if imp <> '' then
      AgregaParte(imp, 'Importe parcial',
        'Digitos [14..21] / 1000 (DigitosImporte=2 def.) = $' +
        DigitosAValor(imp, 1000, 2));
  end
  else if lin[4] = '\' then begin
    FTipo := 'A - Respuesta: posicion NO MAPEADA';
    AgregaParte(lin[4], 'Indicador',
      '"\" = la posicion perdio el mapeo de productos; I-Gas reenvia el mapa');
  end
  else begin
    FTipo := 'A - Respuesta: VENTA CONCLUIDA (lectura final)';
    AgregaParte(lin[4], 'Grado/producto',
      'Numero de producto (grado) que despacho; I-Gas lo mapea a ' +
      'combustible/manguera con TComb/TPosx');
    if Length(lin) >= 5 then
      AgregaParte(lin[5], 'No leido', 'Caracter [5] no interpretado');
    vol := Copy(lin, 6, 8);
    AgregaParte(vol, 'Volumen',
      'Digitos [6..13] / 1000 (DigitosVolumen=2 def.) = ' +
      DigitosAValor(vol, 1000, 3) + ' L');
    imp := Copy(lin, 14, 8);
    AgregaParte(imp, 'Importe',
      'Digitos [14..21] / 1000 (DigitosImporte=2 def.) = $' +
      DigitosAValor(imp, 1000, 2));
    pre := Copy(lin, 22, 5);
    AgregaParte(pre, 'Precio',
      'Digitos [22..26] / 100 (DigitosPrecio=1 def.) = $' +
      DigitosAValor(pre, 100, 2) + ' /L');
    FNota := 'El driver corrige errores de digitos: si 2*vol*precio<importe ' +
      'divide el importe entre 10; si 2*importe<vol*precio lo multiplica ' +
      'por 10; con AjustePAM=Si recalcula importe=vol*precio si difieren ' +
      '>= $0.015.';
  end;
end;

procedure TAnalizadorPam.InterpretaC(const lin: string);
var
  tot: string;
begin
  if Length(lin) <= 5 then begin
    FTipo      := 'C - Solicita TOTALIZADOR de una pistola (versiones <> 3)';
    FDireccion := 'TX: Consola I-Gas -> PAM';
    AgregaParte(lin[1], 'Comando', 'Solicita el total de un producto');
    AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    if Length(lin) >= 4 then
      AgregaParte(lin[4], 'Producto', 'Numero de producto (grado) a consultar');
    if Length(lin) >= 5 then
      AgregaParte(lin[5], 'Fijo', '"1" = terminador del comando');
    Exit;
  end;

  FTipo      := 'C - Respuesta: totalizador de una pistola';
  FDireccion := 'RX: PAM -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "C" (total)');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');
  AgregaParte(lin[4], 'Producto', 'Numero de producto (grado)');
  if Length(lin) >= 5 then
    AgregaParte(lin[5], 'No leido', 'Caracter [5] no interpretado');
  tot := Copy(lin, 6, 10);
  AgregaParte(tot, 'Total litros',
    'Digitos [6..15] / 100 = ' + DigitosAValor(tot, 100, 2) + ' L');
end;

procedure TAnalizadorPam.InterpretaArroba(const lin: string);
var
  tipo, resto, tot: string;
  base, i, xoff: Integer;
begin
  tipo := Copy(lin, 1, 3);

  if tipo = '@02' then begin
    FTipo      := '@02 - PRESET (version PAM1000 = 3)';
    FDireccion := 'TX: Consola I-Gas -> PAM';
    AgregaParte('@02', 'Comando', 'Preset con seleccion de productos (v3)');
    AgregaParte(Copy(lin, 4, 1), 'Fijo', '"0"');
    AgregaParte(Copy(lin, 5, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    if Length(lin) >= 7 then begin
      if lin[7] = '0' then
        AgregaParte(lin[7], 'Tipo', '"0" = preset por IMPORTE')
      else if lin[7] = '1' then
        AgregaParte(lin[7], 'Tipo', '"1" = preset por LITROS')
      else
        AgregaParte(lin[7], 'Tipo', 'Tipo de preset desconocido');
    end;
    if Length(lin) >= 8 then
      AgregaParte(lin[8], 'Nivel de precio', '"1" = contado (nivel usado por I-Gas)');
    resto := Copy(lin, 9, 6);
    if Length(lin) >= 9 then begin
      if (Length(lin) >= 7) and (lin[7] = '1') then
        AgregaParte(resto, 'Litros',
          '6 digitos, 2 dec. implicitos (FormatFloat 0000.00) = ' +
          DigitosAValor(resto, 100, 2) + ' L')
      else
        AgregaParte(resto, 'Importe',
          '6 digitos, 2 dec. implicitos (FormatFloat 0000.00) = $' +
          DigitosAValor(resto, 100, 2));
    end;
    resto := Copy(lin, 15, 6);
    if resto <> '' then
      AgregaParte(resto, 'Productos autorizados',
        '6 banderas (una por posicion de producto): "1" = autorizado. ' +
        '"000000" con 1s solo en los grados permitidos');
    Exit;
  end;

  if (tipo = '@10') and (Length(lin) <= 7) then begin
    FTipo      := '@10 - Solicita TOTALIZADORES de la posicion (v3)';
    FDireccion := 'TX: Consola I-Gas -> PAM';
    AgregaParte('@10', 'Comando', 'Solicita totales de todos los productos');
    AgregaParte(Copy(lin, 4, 1), 'Fijo', '"0"');
    AgregaParte(Copy(lin, 5, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    Exit;
  end;

  // Respuesta de totales v3
  FTipo      := '@ - Respuesta: TOTALIZADORES de la posicion (v3)';
  FDireccion := 'RX: PAM -> Consola I-Gas';
  AgregaParte(Copy(lin, 1, 4), 'Encabezado', 'Eco del comando @10');
  AgregaParte(Copy(lin, 5, 2), 'Posicion', 'Posicion de carga que responde');
  FNota := 'I-Gas lee hasta 4 productos: grado en [8] y total en [9..18]; ' +
    'los siguientes en [37]/[38..47], [66]/[67..76] y [95]/[96..105] ' +
    '(cada total: 10 digitos / 100 = litros).';
  if Length(lin) >= 7 then
    AgregaParte(lin[7], 'No leido', 'Caracter [7] no interpretado');

  base := 8;
  for i := 1 to 4 do begin
    case i of
      1: xoff := 8;
      2: xoff := 37;
      3: xoff := 66;
    else
      xoff := 95;
    end;
    if Length(lin) < xoff then Break;
    if (i > 1) and (xoff - base - 11 > 0) then
      AgregaParte(Copy(lin, base + 11, xoff - base - 11), 'No leido',
        'Caracteres no interpretados por I-Gas');
    AgregaParte(lin[xoff], Format('Grado %d', [i]),
      'Numero de producto (grado)');
    tot := Copy(lin, xoff + 1, 10);
    AgregaParte(tot, Format('Total grado %d', [i]),
      '10 digitos / 100 = ' + DigitosAValor(tot, 100, 2) + ' L');
    base := xoff;
  end;
end;

procedure TAnalizadorPam.InterpretaPayload(const lin: string);
var
  resto: string;
begin
  if lin = '' then begin
    FTipo := 'Trama vacia';
    Exit;
  end;

  if lin = idACK then begin
    FTipo      := 'ACK (06h) - Confirmacion';
    FDireccion := 'RX: PAM -> Consola I-Gas';
    AgregaParte('<ACK>', 'Control',
      'La consola PAM ACEPTO el comando anterior (p.ej. el "T.." de nivel ' +
      'de precios)');
    Exit;
  end;
  if lin = idNAK then begin
    FTipo      := 'NAK (15h) - Rechazo';
    FDireccion := 'RX: PAM -> Consola I-Gas';
    AgregaParte('<NAK>', 'Control',
      'La consola PAM RECHAZO el comando anterior (error en cambio de ' +
      'precios o preset)');
    Exit;
  end;

  case lin[1] of
    'B': InterpretaB(lin);
    'A': InterpretaA(lin);
    'C': InterpretaC(lin);
    '@': InterpretaArroba(lin);

    'T': begin
           FTipo      := 'T - NIVEL DE PRECIOS activo';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('T', 'Comando', 'Selecciona el nivel de precios');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '1' then
               AgregaParte(lin[4], 'Nivel', '"1" = CASH/contado (unico usado por I-Gas)')
             else
               AgregaParte(lin[4], 'Nivel', 'Nivel de precio');
           end;
           FNota := 'El PAM responde ACK; I-Gas marca swnivelprec=true al recibirlo.';
         end;

    'D': begin
           FTipo      := 'D - SETUP de la consola PAM1000';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('D', 'Comando', 'Configura parametros de la consola');
           if Length(lin) >= 2 then
             AgregaParte(lin[2], 'Fijo', '"0"');
           resto := Copy(lin, 3, MaxInt);
           if resto <> '' then
             AgregaParte(resto, 'Setup',
               'Cadena de configuracion (variable SetUpPAM1000; con ' +
               'VersionPam1000=3 el valor por defecto es "6222")');
         end;

    'L': begin
           FTipo      := 'L - OPEN PUMP (abrir posicion)';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('L', 'Comando',
             'Abre una posicion en estatus 6 (Cerrada)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'G': begin
           FTipo      := 'G - RESTART (reanudar despacho)';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('G', 'Comando',
             'Reanuda una posicion detenida (estatus 8) o en despacho');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'E': begin
           FTipo      := 'E - STOP / DESAUTORIZAR';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('E', 'Comando', 'Detiene el despacho / quita autorizacion');
           if Copy(lin, 2, 2) = '00' then begin
             AgregaParte(Copy(lin, 2, 2), 'Posicion',
               '"00" = PARO TOTAL (todas las posiciones)');
             FTipo := 'E00 - PARO TOTAL de la estacion';
           end
           else
             AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'S': begin
           FTipo      := 'S - AUTORIZAR sin limite (preset abierto)';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('S', 'Comando',
             'Autoriza la posicion sin monto tope (I-Gas registra $999 ' +
             'como preset simbolico)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'R': begin
           FTipo      := 'R - VENTA COMPLETA (fin de venta)';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('R', 'Comando',
             'Cierra/paga la transaccion (enviado por el comando FINV con ' +
             'la posicion en estatus 3/EOT)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'X': begin
           FTipo      := 'X - CAMBIO DE PRECIO';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('X', 'Comando', 'Actualiza el precio de un producto');
           AgregaParte(Copy(lin, 2, 2), 'Fijo', '"00"');
           if Length(lin) >= 4 then
             AgregaParte(lin[4], 'Producto', 'Numero de producto (grado) 1..4');
           if Length(lin) >= 5 then begin
             if lin[5] = '1' then
               AgregaParte(lin[5], 'Nivel', '"1" = CONTADO')
             else if lin[5] = '2' then
               AgregaParte(lin[5], 'Nivel', '"2" = CREDITO')
             else
               AgregaParte(lin[5], 'Nivel', 'Nivel desconocido');
           end;
           AgregaParte(Copy(lin, 6, 2), 'Fijo', '"00"');
           resto := Copy(lin, 8, 4);
           if resto <> '' then
             AgregaParte(resto, 'Precio',
               '4 digitos en centavos = $' + DigitosAValor(resto, 100, 2));
           FNota := 'I-Gas envia el cambio dos veces: nivel 1 (contado) e ' +
             'inmediatamente nivel 2 (credito) con el mismo precio.';
         end;

    'P': begin
           FTipo      := 'P - PRESET (version PAM1000 <> 3)';
           FDireccion := 'TX: Consola I-Gas -> PAM';
           AgregaParte('P', 'Comando', 'Fija el tope de la venta');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '0' then begin
               AgregaParte(lin[4], 'Tipo', '"0" = preset por IMPORTE');
               if Length(lin) >= 5 then
                 AgregaParte(lin[5], 'Nivel de precio', '"1" = contado');
               AgregaParte(Copy(lin, 6, 3), 'Relleno', '"000"');
               resto := Copy(lin, 9, 5);
               AgregaParte(resto, 'Importe',
                 '5 digitos, 2 dec. implicitos (FormatFloat 000.00) = $' +
                 DigitosAValor(resto, 100, 2));
               if Length(lin) >= 14 then
                 AgregaParte(lin[14], 'Terminador', '"0"');
             end
             else if lin[4] = '1' then begin
               AgregaParte(lin[4], 'Tipo', '"1" = preset por LITROS');
               if Length(lin) >= 5 then
                 AgregaParte(lin[5], 'Nivel de precio', '"1" = contado');
               AgregaParte(Copy(lin, 6, 2), 'Relleno', '"00"');
               resto := Copy(lin, 8, 5);
               AgregaParte(resto, 'Litros',
                 '5 digitos, 2 dec. implicitos (FormatFloat 000.00) = ' +
                 DigitosAValor(resto, 100, 2) + ' L');
               if Length(lin) >= 13 then
                 AgregaParte(lin[13], 'Terminador', '"0"');
               if Length(lin) >= 14 then
                 AgregaParte(lin[14], 'Grado',
                   'Posicion del producto (1..4) a autorizar');
             end
             else
               AgregaParte(Copy(lin, 4, MaxInt), 'Datos',
                 'Tipo de preset no reconocido');
           end;
         end;
  else
    FTipo      := 'Comando NO RECONOCIDO por esta interfaz';
    FDireccion := '(desconocida)';
    AgregaParte(lin, 'Datos', 'No corresponde a ningun comando de UIGASPAM');
  end;
end;

procedure TAnalizadorPam.Analiza(const AEntrada: string; AContexto: Integer);
var
  raw, payload, bcc: string;
  p, e: Integer;
  tieneSTX, tieneETX: Boolean;
  bccCalc: Char;
begin
  Limpia;
  raw := NormalizaEntrada(AEntrada);
  if raw = '' then begin
    FTipo := 'Sin datos. Capture o pegue un comando.';
    Exit;
  end;

  tieneSTX := False;
  tieneETX := False;
  bcc      := '';
  payload  := raw;

  p := Pos(idSTX, payload);
  if p > 0 then begin
    tieneSTX := True;
    Delete(payload, 1, p);
  end;

  e := Pos(idETX, payload);
  if e > 0 then begin
    tieneETX := True;
    if e < Length(payload) then
      bcc := payload[e + 1];
    payload := Copy(payload, 1, e - 1);
  end;

  InterpretaPayload(payload);

  if tieneSTX then
    FPrefijo := '<STX>';
  if tieneETX then begin
    FSufijo := '<ETX>';
    bccCalc := CalculaBCC(payload + idETX);
    if bcc <> '' then begin
      FSufijo := FSufijo + '<BCC=$' + IntToHex(Ord(bcc[1]), 2) + '>';
      if bcc[1] = bccCalc then
        PonValidacion(Format('BCC (XOR) recibido $%s = calculado $%s  -> CORRECTO',
          [IntToHex(Ord(bcc[1]), 2), IntToHex(Ord(bccCalc), 2)]), True)
      else
        PonValidacion(Format('BCC (XOR) recibido $%s <> calculado $%s  -> ' +
          'INCORRECTO (I-Gas convierte la trama en NAK)',
          [IntToHex(Ord(bcc[1]), 2), IntToHex(Ord(bccCalc), 2)]), False);
    end
    else
      PonValidacion('BCC no incluido en la captura. Calculado (XOR): $' +
        IntToHex(Ord(bccCalc), 2), True);
  end;
end;

procedure TAnalizadorPam.CargaEjemplos(sl: TStrings);
begin
  // TX
  sl.Add('B00');                                    // poll de estatus
  sl.Add('<STX>B0011253980<ETX>');                  // respuesta estatus 8 pos
  sl.Add('A01');                                    // solicita lectura
  sl.Add('<STX>A0220000255000054825002150<ETX>');   // venta concluida
  sl.Add('<STX>A010000000000000125500<ETX>');       // cargando (importe parcial)
  sl.Add('<STX>A03\<ETX>');                         // posicion no mapeada
  sl.Add('T011');                                   // nivel de precios cash
  sl.Add('D06222');                                 // setup PAM1000 v3
  sl.Add('P0901000250750');                         // preset importe $250.75
  sl.Add('P1011000500002');                         // preset 50.00 L grado 2
  sl.Add('@0201101040000100000');                   // preset v3 $400.00 prod 1
  sl.Add('S07');                                    // autorizar sin limite
  sl.Add('E06');                                    // stop / desautorizar
  sl.Add('E00');                                    // paro total
  sl.Add('G05');                                    // restart
  sl.Add('L04');                                    // open pump
  sl.Add('R08');                                    // venta completa
  sl.Add('X0011002050');                            // precio contado $20.50
  sl.Add('X0012002050');                            // precio credito $20.50
  sl.Add('@100120');                                // solicita totales v3
  sl.Add('<STX>@1001201000123456700000000000000000020000876543<ETX>'); // totales v3
  sl.Add('C1221');                                  // solicita total pistola
  sl.Add('<STX>C12200001234567<ETX>');              // total pistola 12,345.67 L
  sl.Add('<ACK>');
  sl.Add('<NAK>');
  // BCC incorrecto a proposito (real $6E)
  sl.Add('<STX>P0901000250750<ETX>' + Char($6F));
end;

end.
