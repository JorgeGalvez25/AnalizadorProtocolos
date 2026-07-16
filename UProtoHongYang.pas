unit UProtoHongYang;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO HONG YANG (basado en UIGASHONGYANG.pas de I-Gas)
  ----------------------------------------------------------------------------
  Protocolo BINARIO sobre bus RS485 multidrop de 9 bits: el driver transmite
  el primer byte (direccion) con paridad MARK y el resto de la trama con
  paridad SPACE (ver Togcvdispensarios_hongyang.ComandoConsola: cambia
  pSerial.Parity entre pMark y pSpace antes/despues del primer byte). Ese
  noveno bit de direccion NO viaja en un hexdump normal de 8 bits; este
  analizador trabaja sobre los 8 bits de datos tal como los entrega un
  espia de puerto serial comun.

  TRAMA TX (Consola I-Gas -> Dispensario):
     ADDR  LEN  LADO  CMND  [DATA...]  BCC
     ADDR = direccion fisica del dispensario (byte binario simple, 1..255)
     LEN  = longitud de "ADDR..DATA" (NO incluye el BCC). Siempre 6 o 7.
     LADO = numero de manguera/lado (byte binario simple)
     CMND = codigo de comando (ver tabla abajo)
     BCC  = char(256 - (suma de bytes ADDR..DATA) mod 256) -- CalculaBCC,
            identico algoritmo a Bennett/TEAM pero aplicado al VALOR real
            del byte (no a su lectura decimal como en TEAM).

     CMND  Letra  LEN  DATA                          Funcion
     $0F   A      6    00 00                         Leer venta/display
     $15   C      6    00 00                         Enllava (activa candado/prepago)
     $14   D      6    00 00                         DesEnllava
     $0E   N      6    00 00                         Leer totalizador
     $0C   V      6    00 00                         Leer precio vigente
     $00   U      6    precio (2 bytes BCD)           Cambio de precio
     $09   S      7    importe (3 bytes BCD)          Preset por IMPORTE
     $0B   L      7    litros (3 bytes BCD)           Preset por LITROS

  TRAMA RX (Dispensario -> Consola):
     LEN  STATUS  [DATA...]  BCC
     LEN  = longitud de LA TRAMA COMPLETA, incluyendose a si mismo y al BCC
            (a diferencia del LEN de TX, que NO cuenta el BCC). Verificado en
            pSerialTriggerAvail: "xlong:=ord(LineaProc[1]); if
            length(LineaProc)=xlong then FinLinea:=true".
     STATUS = byte de estatus, ver DameEstatus mas abajo.
     BCC  = mismo algoritmo, sobre LEN..DATA (todo menos el propio BCC).

     Respuesta a  LEN  DATA                                    
     C/D/U/S/L    3    (sin datos extra: solo confirma con STATUS)
     V            7    00 00 + precio (2 bytes BCD)
     A            12   importe(3B BCD) + precio(3B BCD, NO leido) + volumen(3B BCD)
     N            21   reservado(6B) + litros(6B BCD) + importe(6B BCD, NO leido)

  IMPORTANTE - la respuesta de 3 bytes (a C/D/U/S/L) es IDENTICA sin importar
  cual de esos 5 comandos se contesta: el driver real solo sabe a cual
  corresponde porque recuerda CharCmnd (el ultimo comando que envio). Este
  analizador, al trabajar con tramas sueltas, la muestra como "confirmacion
  generica" sin poder precisar el comando de origen.

  AMBIGUEDAD REAL DE 7 BYTES: un TX de A/C/D/N/V/U y un RX de V miden AMBOS
  7 bytes. Se distinguen porque en TX el 2do byte (LEN) vale fijo $06,
  mientras que en RX-V el 1er byte (LEN) vale fijo $07; pero un status $06
  legitimo en una respuesta V produciria la misma coincidencia en sentido
  opuesto. Por eso este analizador ofrece un combo "Interpretar como" para
  las tramas de 7 bytes (igual que Gilbarco con sus respuestas largas).

  BCD EMPACADO, ORDEN LSB PRIMERO (a diferencia de TEAM que es MSB primero):
  cada byte guarda 2 digitos decimales (nibble alto=decenas, nibble
  bajo=unidades), pero el PRIMER byte transmitido de un valor es el par de
  digitos MENOS significativo (ConvierteBCD arma los pares recorriendo el
  numero de derecha a izquierda; ExtraeBCD los relee de derecha a izquierda
  para reconstruir el valor). Verificado con los comentarios reales del
  codigo fuente: ComandoU precio $10.55 -> "55 10"; ComandoS importe $10.00
  -> "00 10 00"; respuesta V precio $11.23 -> "23 11"; respuesta N con
  litros 803.07 -> "07 03 08 00 00 00".

  HALLAZGOS AL ANALIZAR EL CODIGO FUENTE (documentados con evidencia):
  - Los comentarios de ComandoC y ComandoD muestran ambos el mismo BCC "E9"
    que ComandoA; recalculando con el algoritmo real (CalculaBCC) el BCC de
    ComandoC es en realidad $E3 y el de ComandoD es $E4. Es un error de
    copiar/pegar en el comentario del codigo fuente (no del protocolo real);
    este analizador usa los valores recalculados, no los del comentario.
  - En DameEstatus, la rama final "else if (xst[4]='1') then ee:=9" (estatus
    9=Enllavado) es CODIGO INALCANZABLE: las 5 ramas anteriores ya cubren
    exhaustivamente las 8 combinaciones posibles de los bits 3/6/1 evaluados,
    por lo que esa rama nunca se ejecuta y el estatus 9 jamas es producido
    por esta funcion en la practica (aunque otras partes del driver, como
    ProcesoComandoA, sí reconocen estatus=9 como "Enllavado").
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorHongYang = class(TAnalizadorBase)
  private
    FBytes: array of Byte;
    function  HexTokensABytes(const s: string; var b: array of Byte;
      var n: Integer): Boolean;
    function  Hx(b: Byte): string;
    function  HxRango(a, b: Integer): string;
    function  TokenBCD(b: Byte): Integer;
    function  ValorBCDLSB(idxIni, n: Integer): Int64; // n bytes, LSB primero
    function  Checksum(desde, hasta: Integer): Integer; // suma bytes reales mod 256, complemento
    function  IfSufijo(cond: Boolean; const texto: string): string;
    procedure ValidaChecksum;
    procedure DecodeEstatus(b: Byte; var estatus: Integer; var desc: string;
      var swerror, swlocked, sw47: Boolean);
    procedure Desconocido(n: Integer);
    procedure InterpretaTX_Fijo;   // A/C/D/N/V/U, 7 bytes
    procedure InterpretaTX_SL;     // S/L, 8 bytes
    procedure InterpretaRX_Ack;    // 3 bytes
    procedure InterpretaRX_V;      // 7 bytes
    procedure InterpretaRX_A;      // 12 bytes
    procedure InterpretaRX_N;      // 21 bytes
  public
    function  Nombre: string; override;
    function  EsHexPuro: Boolean; override;
    procedure CargaEjemplos(sl: TStrings); override;
    procedure CargaContextos(sl: TStrings); override;
    procedure Analiza(const AEntrada: string; AContexto: Integer); override;
  end;

implementation

const
  cmndA = $0F;  // Leer venta/display
  cmndC = $15;  // Enllava
  cmndD = $14;  // DesEnllava
  cmndN = $0E;  // Leer totalizador
  cmndV = $0C;  // Leer precio
  cmndU = $00;  // Cambio de precio
  cmndS = $09;  // Preset importe
  cmndL = $0B;  // Preset litros

function TAnalizadorHongYang.EsHexPuro: Boolean;
begin
  Result := True;   // protocolo binario: todo el texto es hex, sin ambiguedad con ASCII
end;

function TAnalizadorHongYang.Nombre: string;
begin
  Result := 'Hong Yang';
end;

procedure TAnalizadorHongYang.CargaContextos(sl: TStrings);
begin
  sl.Add('Auto (TX si el 2do byte es $06; si no, RX respuesta a V)');
  sl.Add('Forzar: TX comando (A/C/D/N/V/U)');
  sl.Add('Forzar: RX respuesta a V (leer precio)');
end;

function TAnalizadorHongYang.HexTokensABytes(const s: string;
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

function TAnalizadorHongYang.Hx(b: Byte): string;
begin
  Result := IntToHex(b, 2) + ' ';
end;

function TAnalizadorHongYang.HxRango(a, b: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := a to b do
    if (i >= 0) and (i <= High(FBytes)) then
      Result := Result + Hx(FBytes[i]);
end;

// Cada byte transporta 2 digitos decimales BCD, uno por nibble.
function TAnalizadorHongYang.TokenBCD(b: Byte): Integer;
begin
  Result := (b shr 4) * 10 + (b and $0F);
end;

// n bytes BCD consecutivos desde idxIni, LSB PRIMERO: el byte en idxIni es
// el par de digitos MENOS significativo (peso 100^0), el siguiente pesa
// 100^1, etc. Replica ExtraeBCD (que relee los tokens de mayor a menor
// indice para reconstruir el numero en el orden correcto).
function TAnalizadorHongYang.ValorBCDLSB(idxIni, n: Integer): Int64;
var
  i: Integer;
  peso: Int64;
begin
  Result := 0;
  peso := 1;
  for i := idxIni to idxIni + n - 1 do begin
    if (i < 0) or (i > High(FBytes)) then Break;
    Result := Result + TokenBCD(FBytes[i]) * peso;
    peso := peso * 100;
  end;
end;

// CalculaBCC real: suma de los VALORES de byte (no BCD) en [desde..hasta],
// mod 256, complemento a 256.
function TAnalizadorHongYang.Checksum(desde, hasta: Integer): Integer;
var
  i, s: Integer;
begin
  s := 0;
  for i := desde to hasta do
    if (i >= 0) and (i <= High(FBytes)) then
      s := s + FBytes[i];
  s := s mod 256;
  Result := (256 - s) mod 256;
end;

function TAnalizadorHongYang.IfSufijo(cond: Boolean; const texto: string): string;
begin
  if cond then
    Result := texto
  else
    Result := '';
end;

// El BCC siempre es el ULTIMO byte de la trama, y cubre TODOS los bytes
// anteriores (desde el primero de la trama, sin excepcion de campos).
procedure TAnalizadorHongYang.ValidaChecksum;
var
  calc, recibido: Integer;
begin
  if High(FBytes) < 1 then Exit;
  calc := Checksum(0, High(FBytes) - 1);
  recibido := FBytes[High(FBytes)];
  AgregaParte(Hx(FBytes[High(FBytes)]), 'BCC',
    Format('$%.2x (complemento a 256 de la suma de todos los bytes anteriores)',
      [recibido]));
  if calc = recibido then
    PonValidacion(Format('BCC recibido $%.2x = calculado $%.2x -> CORRECTO',
      [recibido, calc]), True)
  else
    PonValidacion(Format('BCC recibido $%.2x <> calculado $%.2x -> INCORRECTO',
      [recibido, calc]), False);
end;

// Replica DameEstatus: cascada de bits (bit3=xst[5], bit6=xst[2], bit1=xst[7],
// bit4=xst[4]) seguida de overrides por VALOR HEXADECIMAL exacto del byte.
procedure TAnalizadorHongYang.DecodeEstatus(b: Byte; var estatus: Integer;
  var desc: string; var swerror, swlocked, sw47: Boolean);
var
  bit6, bit5, bit4, bit3, bit1: Boolean;
  ss: string;
begin
  bit6 := (b and $40) <> 0;
  bit5 := (b and $20) <> 0;
  bit4 := (b and $10) <> 0;
  bit3 := (b and $08) <> 0;
  bit1 := (b and $02) <> 0;

  estatus := 0;
  if (not bit3) and (not bit6) then estatus := 1        // Inactivo
  else if bit3 and bit1 then estatus := 5                // Despachando
  else if bit3 and bit6 then estatus := 5                // Despachando
  else if (not bit3) and bit6 then estatus := 1           // "Pistola levantada" en el comentario, pero el codigo real deja 1
  else if bit3 and (not bit6) then estatus := 2           // Autorizado
  else if bit4 then estatus := 9;                         // Enllavado -- INALCANZABLE (ver nota de cabecera)

  swerror := bit5;

  ss := IntToHex(b, 2); // 2 caracteres, mayusculas (igual que StrToHexSep+comparaciones del driver)
  sw47 := False;
  if (ss = '06') or (ss = '03') or (ss = '16') or (ss = '46') or (ss[2] = '7') then begin
    estatus := 1;
    if ss[2] = '7' then sw47 := True;
  end
  else if (ss = '12') or (ss = '02') then
    estatus := 1
  else if (ss = '4A') or (ss = '4B') or (ss = '0A') or (ss = '0E') or (ss = '1A') then
    estatus := 5;

  swlocked := (ss = '12') or (ss = '16') or (ss = '1A') or (ss = '52');

  case estatus of
    1: desc := 'Inactivo';
    2: desc := 'Autorizado';
    5: desc := 'Despachando';
    9: desc := 'Enllavado (bit4; en la practica inalcanzable, ver nota)';
  else
    desc := 'Sin clasificar';
  end;
end;

procedure TAnalizadorHongYang.Desconocido(n: Integer);
begin
  FTipo := Format('Trama de %d bytes: longitud no reconocida. Se esperaba ' +
    '7 u 8 (TX), o 3/7/12/21 (RX)', [n]);
  FDireccion := '(desconocida)';
  AgregaParte(HxRango(0, High(FBytes)), 'Datos',
    'Longitud de trama que no corresponde a ningun comando/respuesta de UIGASHONGYANG');
end;

// ---------------------------------------------------------------------------
// TX: A / C / D / N / V / U (7 bytes: ADDR LEN=6 LADO CMND D1 D2 BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaTX_Fijo;
var
  cmnd: Byte;
  precioRaw: Int64;
begin
  FDireccion := 'TX: Consola I-Gas -> Dispensario Hong Yang';
  AgregaParte(Hx(FBytes[0]), 'Direccion',
    Format('%d (direccion/CPU del dispensario)', [FBytes[0]]));
  AgregaParte(Hx(FBytes[1]), 'Longitud',
    Format('%d (bytes de ADDR..DATA, NO incluye el BCC)', [FBytes[1]]));
  AgregaParte(Hx(FBytes[2]), 'Lado', Format('%d (manguera/lado)', [FBytes[2]]));

  cmnd := FBytes[3];
  case cmnd of
    cmndA: begin
      FTipo := '$0F (A) - Leer VENTA/DISPLAY [ComandoA]';
      AgregaParte(Hx(cmnd), 'Comando', '$0F = solicita venta en curso / display');
      AgregaParte(HxRango(4, 5), 'Reservado', 'Siempre $00 $00 en este comando');
    end;
    cmndC: begin
      FTipo := '$15 (C) - ENLLAVA (activa candado/modo prepago) [ComandoC]';
      AgregaParte(Hx(cmnd), 'Comando', '$15 = enllava la manguera (usado por ActivaModoPrepago)');
      AgregaParte(HxRango(4, 5), 'Reservado', 'Siempre $00 $00 en este comando');
    end;
    cmndD: begin
      FTipo := '$14 (D) - DESENLLAVA (libera candado/modo prepago) [ComandoD]';
      AgregaParte(Hx(cmnd), 'Comando', '$14 = desenllava la manguera (usado por DesactivaModoPrepago)');
      AgregaParte(HxRango(4, 5), 'Reservado', 'Siempre $00 $00 en este comando');
    end;
    cmndN: begin
      FTipo := '$0E (N) - Leer TOTALIZADOR [ComandoN]';
      AgregaParte(Hx(cmnd), 'Comando', '$0E = solicita totalizador acumulado');
      AgregaParte(HxRango(4, 5), 'Reservado', 'Siempre $00 $00 en este comando');
    end;
    cmndV: begin
      FTipo := '$0C (V) - Leer PRECIO vigente [ComandoV]';
      AgregaParte(Hx(cmnd), 'Comando', '$0C = solicita el precio programado en el dispensario');
      AgregaParte(HxRango(4, 5), 'Reservado', 'Siempre $00 $00 en este comando');
    end;
    cmndU: begin
      FTipo := '$00 (U) - CAMBIO DE PRECIO [ComandoU]';
      AgregaParte(Hx(cmnd), 'Comando', '$00 = cambia el precio de la manguera');
      precioRaw := ValorBCDLSB(4, 2);
      AgregaParte(HxRango(4, 5), 'Precio',
        Format('2 bytes BCD (4 digitos, LSB primero) = %d / 100 = $%s',
          [precioRaw, FormatFloat('#,##0.00', precioRaw / 100)]));
    end;
  else
    FTipo := Format('Comando $%s no reconocido', [IntToHex(cmnd, 2)]);
    AgregaParte(Hx(cmnd), 'Comando', 'No corresponde a A/C/D/N/V/U de UIGASHONGYANG');
  end;

  ValidaChecksum;
end;

// ---------------------------------------------------------------------------
// TX: S / L (8 bytes: ADDR LEN=7 LADO CMND D1 D2 D3 BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaTX_SL;
var
  cmnd: Byte;
  valorRaw: Int64;
begin
  FDireccion := 'TX: Consola I-Gas -> Dispensario Hong Yang';
  AgregaParte(Hx(FBytes[0]), 'Direccion', Format('%d (direccion/CPU del dispensario)', [FBytes[0]]));
  AgregaParte(Hx(FBytes[1]), 'Longitud',
    Format('%d (bytes de ADDR..DATA, NO incluye el BCC)', [FBytes[1]]));
  AgregaParte(Hx(FBytes[2]), 'Lado', Format('%d (manguera/lado)', [FBytes[2]]));

  cmnd := FBytes[3];
  valorRaw := ValorBCDLSB(4, 3);

  if cmnd = cmndS then begin
    FTipo := '$09 (S) - PRESET por IMPORTE [ComandoS]';
    AgregaParte(Hx(cmnd), 'Comando', '$09 = prefija la venta por importe (pesos)');
    AgregaParte(HxRango(4, 6), 'Importe',
      Format('3 bytes BCD (6 digitos, LSB primero) = %d / 100 = $%s',
        [valorRaw, FormatFloat('#,##0.00', valorRaw / 100)]));
  end
  else if cmnd = cmndL then begin
    FTipo := '$0B (L) - PRESET por LITROS [ComandoL]';
    AgregaParte(Hx(cmnd), 'Comando', '$0B = prefija la venta por volumen (litros)');
    AgregaParte(HxRango(4, 6), 'Litros',
      Format('3 bytes BCD (6 digitos, LSB primero) = %d / 100 = %s L',
        [valorRaw, FormatFloat('#,##0.00', valorRaw / 100)]));
  end
  else begin
    FTipo := Format('Comando $%s no reconocido (se esperaba $09 o $0B)', [IntToHex(cmnd, 2)]);
    AgregaParte(Hx(cmnd), 'Comando', 'No corresponde a S/L de UIGASHONGYANG');
    AgregaParte(HxRango(4, 6), 'Valor', Format('%d (sin interpretar)', [valorRaw]));
  end;

  ValidaChecksum;
end;

// ---------------------------------------------------------------------------
// RX: confirmacion generica de C/D/U/S/L (3 bytes: LEN=3 STATUS BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaRX_Ack;
var
  estatus: Integer;
  desc: string;
  swerror, swlocked, sw47: Boolean;
begin
  FTipo      := 'Confirmacion generica (respuesta a C, D, U, S o L)';
  FDireccion := 'RX: Dispensario Hong Yang -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Longitud', '3 (LEN incluye LEN+STATUS+BCC en la trama RX)');

  DecodeEstatus(FBytes[1], estatus, desc, swerror, swlocked, sw47);
  AgregaParte(Hx(FBytes[1]), 'Estatus',
    Format('Estatus I-Gas %d (%s)%s%s', [estatus, desc,
      IfSufijo(swerror, ', ERROR'), IfSufijo(swlocked, ', ENLLAVADO/LOCKED')]));

  ValidaChecksum;
  FNota := 'Esta respuesta de 3 bytes es identica sin importar si confirma ' +
    'C, D, U, S o L; el driver real sabe cual fue por el ultimo comando enviado.';
end;

// ---------------------------------------------------------------------------
// RX: respuesta a V (7 bytes: LEN=7 STATUS 00 00 D1 D2 BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaRX_V;
var
  estatus: Integer;
  desc: string;
  swerror, swlocked, sw47: Boolean;
  precioRaw: Int64;
begin
  FTipo      := 'Respuesta a $0C (V) - PRECIO vigente';
  FDireccion := 'RX: Dispensario Hong Yang -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Longitud', '7 (incluye LEN..BCC)');

  DecodeEstatus(FBytes[1], estatus, desc, swerror, swlocked, sw47);
  AgregaParte(Hx(FBytes[1]), 'Estatus', Format('Estatus I-Gas %d (%s)', [estatus, desc]));

  AgregaParte(HxRango(2, 3), 'Reservado', 'Siempre $00 $00 en esta respuesta');

  precioRaw := ValorBCDLSB(4, 2);
  AgregaParte(HxRango(4, 5), 'Precio',
    Format('2 bytes BCD (4 digitos, LSB primero) = %d / 100 = $%s',
      [precioRaw, FormatFloat('#,##0.00', precioRaw / 100)]));

  ValidaChecksum;
end;

// ---------------------------------------------------------------------------
// RX: respuesta a A (12 bytes: LEN=12 STATUS IMP(3) PRE(3,no leido) VOL(3) BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaRX_A;
var
  estatus: Integer;
  desc: string;
  swerror, swlocked, sw47: Boolean;
  importeRaw, precioRaw, volumenRaw: Int64;
begin
  FTipo      := 'Respuesta a $0F (A) - VENTA/DISPLAY';
  FDireccion := 'RX: Dispensario Hong Yang -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Longitud', '12 (incluye LEN..BCC)');

  DecodeEstatus(FBytes[1], estatus, desc, swerror, swlocked, sw47);
  AgregaParte(Hx(FBytes[1]), 'Estatus',
    Format('Estatus I-Gas %d (%s)%s%s', [estatus, desc,
      IfSufijo(swerror, ', ERROR'), IfSufijo(swlocked, ', ENLLAVADO/LOCKED')]));

  importeRaw := ValorBCDLSB(2, 3);
  AgregaParte(HxRango(2, 4), 'Importe',
    Format('3 bytes BCD (6 digitos, LSB primero) = %d / 100 = $%s',
      [importeRaw, FormatFloat('#,##0.00', importeRaw / 100)]));

  precioRaw := ValorBCDLSB(5, 3);
  AgregaParte(HxRango(5, 7), 'Precio (no leido por el driver)',
    Format('3 bytes BCD (6 digitos, LSB primero) = %d / 100 = $%s ' +
      '(el driver usa el precio ya cacheado, no este campo)',
      [precioRaw, FormatFloat('#,##0.00', precioRaw / 100)]));

  volumenRaw := ValorBCDLSB(8, 3);
  AgregaParte(HxRango(8, 10), 'Volumen',
    Format('3 bytes BCD (6 digitos, LSB primero) = %d / 100 = %s L',
      [volumenRaw, FormatFloat('#,##0.00', volumenRaw / 100)]));

  ValidaChecksum;
end;

// ---------------------------------------------------------------------------
// RX: respuesta a N (21 bytes: LEN=21 STATUS RES(6) LIT(6) IMP(6,no leido) BCC)
// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.InterpretaRX_N;
var
  estatus: Integer;
  desc: string;
  swerror, swlocked, sw47: Boolean;
  litrosRaw, importeRaw: Int64;
begin
  FTipo      := 'Respuesta a $0E (N) - TOTALIZADOR';
  FDireccion := 'RX: Dispensario Hong Yang -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Longitud', '21 (incluye LEN..BCC)');

  DecodeEstatus(FBytes[1], estatus, desc, swerror, swlocked, sw47);
  AgregaParte(Hx(FBytes[1]), 'Estatus', Format('Estatus I-Gas %d (%s)', [estatus, desc]));

  AgregaParte(HxRango(2, 7), 'Reservado', 'No leido por el driver (siempre $00 en el ejemplo real)');

  litrosRaw := ValorBCDLSB(8, 6);
  AgregaParte(HxRango(8, 13), 'Total litros',
    Format('6 bytes BCD (12 digitos, LSB primero) = %d / 100 = %s L',
      [litrosRaw, FormatFloat('#,##0.00', litrosRaw / 100)]));

  importeRaw := ValorBCDLSB(14, 6);
  AgregaParte(HxRango(14, 19), 'Total importe (no leido por el driver)',
    Format('6 bytes BCD (12 digitos, LSB primero) = %d / 100 = $%s ' +
      '(el driver solo extrae los litros)',
      [importeRaw, FormatFloat('#,##0.00', importeRaw / 100)]));

  ValidaChecksum;
end;

// ---------------------------------------------------------------------------

procedure TAnalizadorHongYang.Analiza(const AEntrada: string; AContexto: Integer);
var
  b: array[0..255] of Byte;
  n, i: Integer;
begin
  Limpia;

  if Trim(AEntrada) = '' then begin
    FTipo := 'Sin datos. Capture o pegue una trama.';
    Exit;
  end;

  if not HexTokensABytes(AEntrada, b, n) then begin
    FTipo := 'Entrada no valida: capture los bytes en HEXADECIMAL ' +
      '(ej. "01 06 01 0F 00 00 E9")';
    Exit;
  end;
  if n = 0 then begin
    FTipo := 'Sin datos. Capture o pegue una trama.';
    Exit;
  end;

  SetLength(FBytes, n);
  for i := 0 to n - 1 do
    FBytes[i] := b[i];

  case n of
    3:  InterpretaRX_Ack;
    7:  case AContexto of
          1: InterpretaTX_Fijo;
          2: InterpretaRX_V;
        else
          if FBytes[1] = 6 then InterpretaTX_Fijo
          else InterpretaRX_V;
        end;
    8:  InterpretaTX_SL;
    12: InterpretaRX_A;
    21: InterpretaRX_N;
  else
    Desconocido(n);
  end;
end;

procedure TAnalizadorHongYang.CargaEjemplos(sl: TStrings);
begin
  // TX de 7 bytes: A/C/D/N/V (checksum recalculado con CalculaBCC real; los
  // de C y D CORRIGEN un error de copiar/pegar en el comentario original,
  // que mostraba $E9 para ambos igual que A -- ver nota de cabecera)
  sl.Add('01 06 01 0F 00 00 E9');                    // A: leer venta/display
  sl.Add('01 06 01 15 00 00 E3');                    // C: enllava
  sl.Add('01 06 01 14 00 00 E4');                    // D: desenllava
  sl.Add('01 06 01 0E 00 00 EA');                    // N: leer totalizador
  sl.Add('01 06 01 0C 00 00 EC');                    // V: leer precio
  sl.Add('01 06 02 00 55 10 92');                    // U: cambio de precio $10.55

  // TX de 8 bytes: S/L
  sl.Add('01 07 02 09 00 10 00 DD');                 // S: preset importe $10.00
  sl.Add('01 07 02 0B 00 02 00 E9');                 // L: preset 2.00 L

  // RX de 3 bytes: confirmacion generica, distintos status (DameEstatus)
  sl.Add('03 07 F6');                                // status $07: fin de venta (ss[2]='7')
  sl.Add('03 00 FD');                                // status $00: inactivo
  sl.Add('03 88 75');                                // status $88: autorizado
  sl.Add('03 4A B3');                                // status $4A: despachando
  sl.Add('03 12 EB');                                // status $12: inactivo + enllavado
  sl.Add('03 20 DD');                                // status $20: inactivo + error
  sl.Add('03 52 AB');                                // status $52: inactivo + enllavado + error

  // RX de 7 bytes: respuesta a V (ejemplo verificado con el comentario real)
  sl.Add('07 02 00 00 23 11 C3');                    // precio $11.23

  // RX de 12 bytes: respuesta a A (venta en curso)
  sl.Add('0C 4A 50 82 17 20 14 00 50 25 01 17');     // importe $1,782.50 precio $14.20 volumen 125.50 L

  // RX de 21 bytes: respuesta a N (ejemplo LITERAL del comentario del codigo fuente)
  sl.Add('15 03 00 00 00 00 00 00 07 03 08 00 00 00 14 84 10 00 00 00 2E'); // litros 803.07

  // Checksum incorrecto a proposito (basado en el ejemplo real de N; el correcto es 2E)
  sl.Add('15 03 00 00 00 00 00 00 07 03 08 00 00 00 14 84 10 00 00 00 2F');

  // Trama no reconocida (longitud que no corresponde a ningun comando/respuesta)
  sl.Add('AA BB CC DD');
end;

end.
