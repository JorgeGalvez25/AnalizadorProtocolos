unit UProtoTeam;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO TEAM (basado en UIGASTEAM.pas de I-Gas)
  ----------------------------------------------------------------------------
  Protocolo BINARIO, un byte de OPCODE por transaccion, SIN STX/ETX. La
  sincronizacion de trama la da el propio opcode: su nibble alto siempre es
  $A o $E (pSerialTriggerAvail: "if (ss[1]='A')or(ss[1]='E') then linea:='';"
  -> reinicia el acumulador). Los demas bytes de la trama (posicion, valores,
  checksum) son BCD empacado: CADA BYTE guarda 2 digitos decimales, uno por
  nibble (nibble alto = decena, nibble bajo = unidad), por lo que su nibble
  alto NUNCA es A..F. Esto es lo que permite al driver distinguir "inicio de
  opcode" de "byte de datos" sin necesidad de STX.

  Trama general:  OPCODE  DISP  00  LEN  <campos especificos...>  CHECKSUM

    OPCODE  1 byte, nibble alto $A o $E:
      $A0  BLOQUEAR ($A0.. 06) / DESBLOQUEAR ($A0.. 09)   -- ComandoC/ComandoD
      $A1  LEER DISPLAY (venta en curso)                  -- ComandoA
      $A3  LEER ESTATUS de una posicion (poll)             -- ComandoB
      $A5  PRESET por IMPORTE (subcmd 06) / LITROS (subcmd 09) -- ComandoS/L
      $A6  CAMBIO DE PRECIOS (3 niveles en un solo comando) -- ComandoU
      $A9  TOTALIZADORES                                    -- ComandoN
      $E0  CODIGO DE ACCESO (ComandoW) -- definido en el driver pero NO
           conectado actualmente a ComandoConsola (ver nota en InterpretaE0)

    DISP    1 byte BCD = numero de dispensario fisico.
    '00'    1 byte fijo.
    LEN     1 byte BCD = numero de campos desde "lado/subcmd" (campo 5)
            hasta el CHECKSUM inclusive (NoElemStrSep-4 en el codigo real).
    CHECKSUM 1 byte BCD = (suma decimal de los campos 5..N-1) mod 100
            -- funcion real ValidaChecksumTeam, verificada con el ejemplo de
            codigo fuente "A3 03 00 05 02 00 01 00 03" (suma 02+00+01+00=3).

  VALORES MULTI-BYTE (importe/litros/precio/totales): BCD empacado de 2
  digitos por byte, en orden MSB PRIMERO (a diferencia de Wayne2W/Gilbarco,
  que son LSB primero) -- se arman con inttoclavenum(valor,N) y se cortan en
  pares de izquierda a derecha (copy(ss2,1,2), copy(ss2,3,2), ...).

  IMPORTANTE: UIGASTEAM tambien construye lineas internas de una sola letra
  (formato interno tipo Bennett: "A0501...", "N0501234567890123") para
  reutilizar el mismo motor de estado que otros protocolos I-Gas. ESO NO ES
  la trama del cable: es una traduccion interna posterior a decodificar la
  respuesta real del dispensador. Este analizador trabaja unicamente con la
  trama REAL de puerto serial ($A0/$A1/$A3/$A5/$A6/$A9), que es lo que se
  captura con el espia de puerto.
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorTeam = class(TAnalizadorBase)
  private
    FBytes: array of Byte;
    function  HexTokensABytes(const s: string; var b: array of Byte;
      var n: Integer): Boolean;
    function  Hx(b: Byte): string;
    function  HxRango(a, b: Integer): string;
    function  TokenBCD(b: Byte): Integer;       // nibble alto*10 + nibble bajo
    function  ValorBCD(idxIni, n: Integer): Int64; // n bytes BCD, MSB primero
    function  ChecksumCampos(desde, hasta: Integer): Integer; // 0-based, mod 100
    function  DescLen(idx, esperado: Integer): string;
    procedure ValidaChecksum(desdeCampo5: Integer);
    procedure DescEstatusA3(b: Byte; var estatus: Integer; var desc, modo: string);
    procedure Desconocido(const opHex: string; n: Integer; const esperado: string);
    procedure InterpretaA3TX;
    procedure InterpretaA3RX;
    procedure InterpretaA1TX;
    procedure InterpretaA1RX;
    procedure InterpretaA0;
    procedure InterpretaA5;
    procedure InterpretaA6;
    procedure InterpretaA9TX;
    procedure InterpretaA9RX;
    procedure InterpretaE0;
  public
    function  Nombre: string; override;
    function  EsHexPuro: Boolean; override;
    procedure CargaEjemplos(sl: TStrings); override;
    procedure Analiza(const AEntrada: string; AContexto: Integer); override;
  end;

implementation

const
  opBLOQUEO  = $A0;
  opDISPLAY  = $A1;
  opESTATUS  = $A3;
  opPRESET   = $A5;
  opPRECIOS  = $A6;
  opTOTALES  = $A9;
  opCODIGO   = $E0;

function TAnalizadorTeam.EsHexPuro: Boolean;
begin
  Result := True;   // protocolo binario: todo el texto es hex, sin ambiguedad con ASCII
end;

function TAnalizadorTeam.Nombre: string;
begin
  Result := 'TEAM';
end;

function TAnalizadorTeam.HexTokensABytes(const s: string;
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

function TAnalizadorTeam.Hx(b: Byte): string;
begin
  Result := IntToHex(b, 2) + ' ';
end;

function TAnalizadorTeam.HxRango(a, b: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := a to b do
    if (i >= 0) and (i <= High(FBytes)) then
      Result := Result + Hx(FBytes[i]);
end;

// Cada byte transporta 2 digitos decimales, uno por nibble (BCD empacado).
// Ej.: byte $50 (nibble alto 5, nibble bajo 0) representa el numero 50.
function TAnalizadorTeam.TokenBCD(b: Byte): Integer;
begin
  Result := (b shr 4) * 10 + (b and $0F);
end;

// Concatena n bytes BCD consecutivos, MSB primero, formando un entero.
function TAnalizadorTeam.ValorBCD(idxIni, n: Integer): Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := idxIni to idxIni + n - 1 do begin
    if (i < 0) or (i > High(FBytes)) then Break;
    Result := Result * 100 + TokenBCD(FBytes[i]);
  end;
end;

// Suma decimal (BCD) de los bytes en el rango [desde..hasta], mod 100.
// Replica exactamente ValidaChecksumTeam del driver real.
function TAnalizadorTeam.ChecksumCampos(desde, hasta: Integer): Integer;
var
  i, s: Integer;
begin
  s := 0;
  for i := desde to hasta do
    if (i >= 0) and (i <= High(FBytes)) then
      s := s + TokenBCD(FBytes[i]);
  Result := s mod 100;
end;

function TAnalizadorTeam.DescLen(idx, esperado: Integer): string;
var
  v: Integer;
begin
  v := TokenBCD(FBytes[idx]);
  if v = esperado then
    Result := Format('BCD=%.2d -> coincide con %d campos reales (lado/subcmd..checksum)',
      [v, esperado])
  else
    Result := Format('BCD=%.2d -> NO coincide con los %d campos presentes en esta captura',
      [v, esperado]);
end;

// Checksum = ultimo byte de la trama; se valida contra la suma BCD de los
// campos desde "desdeCampo5" (indice 0-based del primer campo tras LEN)
// hasta el penultimo byte.
procedure TAnalizadorTeam.ValidaChecksum(desdeCampo5: Integer);
var
  calc, recibido: Integer;
begin
  if High(FBytes) < desdeCampo5 then Exit;
  calc := ChecksumCampos(desdeCampo5, High(FBytes) - 1);
  recibido := TokenBCD(FBytes[High(FBytes)]);
  AgregaParte(Hx(FBytes[High(FBytes)]), 'Checksum',
    Format('BCD=%.2d (suma decimal de los campos desde "lado/subcmd" mod 100)',
      [recibido]));
  if calc = recibido then
    PonValidacion(Format('Checksum recibido %.2d = calculado %.2d -> CORRECTO',
      [recibido, calc]), True)
  else
    PonValidacion(Format('Checksum recibido %.2d <> calculado %.2d -> INCORRECTO',
      [recibido, calc]), False);
end;

// Decodifica el byte de estatus de la respuesta $A3 (DameEstatus real).
// El byte solo es valido si sus dos nibbles son 0..9 (BCD); en ese caso su
// representacion binaria normal de 8 bits coincide con la que arma
// HexToBinario+ConvierteBin en el driver (por eso se lee bit a bit tal cual).
procedure TAnalizadorTeam.DescEstatusA3(b: Byte; var estatus: Integer;
  var desc, modo: string);
var
  bit6, bit5, bit1, bit0: Boolean;
begin
  bit6 := (b and $40) <> 0;   // Modo: 0=Normal / 1=Prepago
  bit5 := (b and $20) <> 0;   // Autorizado (solo si no esta despachando)
  bit1 := (b and $02) <> 0;   // Despachando (motor)
  bit0 := (b and $01) <> 0;   // Autorizado (override fuerte -> estatus 9)

  if bit6 then modo := 'Prepago' else modo := 'Normal';

  if bit1 then
    estatus := 5   // Despachando
  else begin
    estatus := 1;  // Inactivo
    if bit5 then
      estatus := 2; // Autorizado
  end;
  if bit0 then
    estatus := 9;   // Autorizado (bit0, tiene prioridad)

  case estatus of
    1: desc := 'Inactivo';
    2: desc := 'Autorizado (bit5)';
    5: desc := 'Despachando';
    9: desc := 'Autorizado (bit0, prioritario)';
  else
    desc := 'Desconocido';
  end;
end;

procedure TAnalizadorTeam.Desconocido(const opHex: string; n: Integer;
  const esperado: string);
begin
  FTipo := Format('Opcode $%s con %d bytes: longitud no reconocida. ' +
    'Se esperaba %s', [opHex, n, esperado]);
  FDireccion := '(desconocida)';
  AgregaParte(HxRango(0, High(FBytes)), 'Datos',
    'Trama con longitud inesperada para este opcode de UIGASTEAM');
end;

// ---------------------------------------------------------------------------
// $A3 -- ESTATUS
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA3TX;
begin
  FTipo      := '$A3 - Solicitar ESTATUS de una posicion (poll) [ComandoB]';
  FDireccion := 'TX: Consola I-Gas -> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode',
    '$A3 = leer estatus. Nibble alto $A = marca de inicio de trama (no hay STX)');
  AgregaParte(Hx(FBytes[1]), 'Dispensador',
    Format('BCD = %.2d (numero de dispensario fisico)', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 2));
  AgregaParte(Hx(FBytes[4]), 'Lado',
    Format('BCD = %.2d (lado/manguera del dispensario a consultar)',
      [TokenBCD(FBytes[4])]));
  ValidaChecksum(4);
  FNota := 'El driver envia este poll ciclicamente por cada posicion; no ' +
    'existe un "B00" de difusion como en Bennett, cada A3 consulta una sola.';
end;

procedure TAnalizadorTeam.InterpretaA3RX;
var
  estatus: Integer;
  desc, modo: string;
  b: Byte;
  manguera: Integer;
begin
  FTipo      := '$A3 - Respuesta: ESTATUS de la posicion';
  FDireccion := 'RX: Dispensario TEAM -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Opcode', 'Eco de $A3 (estatus)');
  AgregaParte(Hx(FBytes[1]), 'Dispensador',
    Format('BCD = %.2d (eco)', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 5));
  AgregaParte(Hx(FBytes[4]), 'Lado',
    Format('BCD = %.2d (eco del lado consultado)', [TokenBCD(FBytes[4])]));

  b := FBytes[5];
  DescEstatusA3(b, estatus, desc, modo);
  AgregaParte(Hx(b), 'Byte de estatus',
    Format('Bits: b6=Modo(%s) b5=Autorizado b1=Despachando b0=Autorizado(prioritario) ' +
      '-> Estatus I-Gas %d (%s)', [modo, estatus, desc]));

  manguera := FBytes[6] and $0F;
  if manguera > 0 then
    AgregaParte(Hx(FBytes[6]), 'Manguera activa',
      Format('Nibble bajo = %d (manguera/grado enganchado)', [manguera]))
  else
    AgregaParte(Hx(FBytes[6]), 'Manguera activa',
      'Nibble bajo = 0: sin manguera reportada, se conserva la anterior');

  AgregaParte(Hx(FBytes[7]), 'Reservado', 'No leido por el driver (siempre $00 en capturas)');

  ValidaChecksum(4);
  FNota := 'b1=1 -> Despachando(5); si b1=0, b5=1 -> Autorizado(2), si no ' +
    'Inactivo(1); b0=1 fuerza Autorizado(9). Los estatus 7/8 los agrega el ' +
    'driver internamente y no viajan en esta trama.';
end;

// ---------------------------------------------------------------------------
// $A1 -- LEER DISPLAY (venta en curso)
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA1TX;
var
  tipo: Integer;
begin
  tipo := TokenBCD(FBytes[5]);
  FTipo      := '$A1 - Leer DISPLAY (venta en curso) [ComandoA]';
  FDireccion := 'TX: Consola I-Gas -> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$A1 = leer display de la venta en curso');
  AgregaParte(Hx(FBytes[1]), 'Dispensador',
    Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 3));
  AgregaParte(Hx(FBytes[4]), 'Lado',
    Format('BCD = %.2d', [TokenBCD(FBytes[4])]));
  if tipo = 0 then
    AgregaParte(Hx(FBytes[5]), 'Tipo', '$00 = solicita VOLUMEN (litros)')
  else if tipo = 1 then
    AgregaParte(Hx(FBytes[5]), 'Tipo', '$01 = solicita IMPORTE (pesos)')
  else
    AgregaParte(Hx(FBytes[5]), 'Tipo', Format('BCD=%.2d (valor no reconocido, se esperaba 00/01)', [tipo]));
  ValidaChecksum(4);
end;

procedure TAnalizadorTeam.InterpretaA1RX;
var
  tipo: Integer;
  valorRaw: Int64;
  esVacio: Boolean;
  sufijoVacio: string;
begin
  tipo := TokenBCD(FBytes[5]);
  FTipo      := '$A1 - Respuesta: lectura de DISPLAY';
  FDireccion := 'RX: Dispensario TEAM -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Opcode', 'Eco de $A1');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d (eco)', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 7));
  AgregaParte(Hx(FBytes[4]), 'Lado', Format('BCD = %.2d (eco)', [TokenBCD(FBytes[4])]));

  valorRaw := ValorBCD(6, 4); // 4 bytes BCD, MSB primero = 8 digitos decimales
  // Centinela real del driver: los 4 bytes crudos son $FF o $88 (equivalen a
  // los textos "FFFFFFFF"/"88888888" que compara UIGASTEAM antes de dividir)
  esVacio := ((FBytes[6] = $FF) and (FBytes[7] = $FF) and (FBytes[8] = $FF) and (FBytes[9] = $FF))
          or ((FBytes[6] = $88) and (FBytes[7] = $88) and (FBytes[8] = $88) and (FBytes[9] = $88));
  if esVacio then
    sufijoVacio := ' -- valor centinela (FFFFFFFF/88888888) = SIN LECTURA -> el driver lo trata como 0'
  else
    sufijoVacio := '';

  if tipo = 0 then begin
    AgregaParte(Hx(FBytes[5]), 'Tipo', '$00 = VOLUMEN (eco)');
    AgregaParte(HxRango(6, 9), 'Volumen',
      Format('4 bytes BCD (8 digitos, MSB primero) = %d / 100 = %s L%s',
        [valorRaw, FormatFloat('#,##0.00', valorRaw / 100), sufijoVacio]));
    FNota := 'Con tipo=00 el driver solo actualiza "volumen" (2 decimales, /100); ' +
      'el preset por litros (ComandoL) usa en cambio 3 decimales (/1000).';
  end
  else if tipo = 1 then begin
    AgregaParte(Hx(FBytes[5]), 'Tipo', '$01 = IMPORTE (eco)');
    AgregaParte(HxRango(6, 9), 'Importe',
      Format('4 bytes BCD (8 digitos, MSB primero) = %d / 100 = $%s%s',
        [valorRaw, FormatFloat('#,##0.00', valorRaw / 100), sufijoVacio]));
    FNota := 'Con tipo=01 la trama solo trae el importe; el driver calcula el ' +
      'volumen dividiendo importe/precio vigente (el precio no viaja aqui).';
  end
  else
    AgregaParte(HxRango(6, 9), 'Datos', 'Tipo no reconocido; no se interpreta el valor');

  ValidaChecksum(4);
end;

// ---------------------------------------------------------------------------
// $A0 -- BLOQUEAR / DESBLOQUEAR
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA0;
var
  sub: Integer;
begin
  sub := TokenBCD(FBytes[4]);
  FDireccion := 'TX o RX (eco de confirmacion): Consola I-Gas <-> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$A0 = bloquear/desbloquear dispensario');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 2));
  if sub = 6 then begin
    FTipo := '$A0 (subcmd 06) - BLOQUEAR/DETENER dispensario [ComandoC]';
    AgregaParte(Hx(FBytes[4]), 'Subcomando', '$06 = bloquea (detiene) el dispensario completo');
  end
  else if sub = 9 then begin
    FTipo := '$A0 (subcmd 09) - DESBLOQUEAR/REANUDAR dispensario [ComandoD]';
    AgregaParte(Hx(FBytes[4]), 'Subcomando', '$09 = desbloquea (reanuda) el dispensario completo');
  end
  else begin
    FTipo := '$A0 - Subcomando no reconocido';
    AgregaParte(Hx(FBytes[4]), 'Subcomando', Format('BCD=%.2d (se esperaba 06 o 09)', [sub]));
  end;
  ValidaChecksum(4);
  FNota := 'El bloqueo/desbloqueo aplica a TODO el dispensario (no por lado). ' +
    'La respuesta tiene la misma estructura de 6 bytes que el TX, validada solo por checksum.';
end;

// ---------------------------------------------------------------------------
// $A5 -- PRESET (importe / litros)
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA5;
var
  sub: Integer;
  valorRaw: Int64;
begin
  sub := TokenBCD(FBytes[5]);
  FDireccion := 'TX o RX (eco de confirmacion): Consola I-Gas <-> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$A5 = preset (importe o litros)');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 7));
  AgregaParte(Hx(FBytes[4]), 'Lado', Format('BCD = %.2d', [TokenBCD(FBytes[4])]));

  valorRaw := ValorBCD(6, 4); // 4 bytes BCD MSB primero

  if sub = 6 then begin
    FTipo := '$A5 (subcmd 06) - PRESET por IMPORTE [ComandoS]';
    AgregaParte(Hx(FBytes[5]), 'Subcomando', '$06 = preset por importe (pesos)');
    AgregaParte(HxRango(6, 9), 'Importe',
      Format('4 bytes BCD (8 digitos, MSB primero) = %d / 100 = $%s',
        [valorRaw, FormatFloat('#,##0.00', valorRaw / 100)]));
  end
  else if sub = 9 then begin
    FTipo := '$A5 (subcmd 09) - PRESET por LITROS [ComandoL]';
    AgregaParte(Hx(FBytes[5]), 'Subcomando', '$09 = preset por volumen (litros)');
    AgregaParte(HxRango(6, 9), 'Litros',
      Format('4 bytes BCD (8 digitos, MSB primero) = %d / 1000 = %s L',
        [valorRaw, FormatFloat('#,##0.000', valorRaw / 1000)]));
  end
  else begin
    FTipo := '$A5 - Subcomando no reconocido';
    AgregaParte(Hx(FBytes[5]), 'Subcomando', Format('BCD=%.2d (se esperaba 06 o 09)', [sub]));
    AgregaParte(HxRango(6, 9), 'Valor', Format('%d (sin interpretar)', [valorRaw]));
  end;

  ValidaChecksum(4);
  FNota := 'A diferencia de Bennett, TEAM no tiene un valor "tope" especial ' +
    'para cancelar el preset; la respuesta es solo un eco de confirmacion.';
end;

// ---------------------------------------------------------------------------
// $A6 -- CAMBIO DE PRECIOS
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA6;
var
  p1, p2, p3: Int64;
begin
  FTipo      := '$A6 - CAMBIO DE PRECIOS (3 niveles) [ComandoU]';
  FDireccion := 'TX o RX (eco de confirmacion): Consola I-Gas <-> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$A6 = cambio de precios');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 8));
  AgregaParte(Hx(FBytes[4]), 'Subcomando', 'Siempre $06 (fijo en ComandoU)');

  p1 := ValorBCD(5, 2);
  p2 := ValorBCD(7, 2);
  p3 := ValorBCD(9, 2);

  AgregaParte(HxRango(5, 6), 'Precio 1',
    Format('2 bytes BCD (4 digitos, MSB primero) = %d / 100 = $%s',
      [p1, FormatFloat('#,##0.00', p1 / 100)]));
  AgregaParte(HxRango(7, 8), 'Precio 2',
    Format('2 bytes BCD (4 digitos, MSB primero) = %d / 100 = $%s',
      [p2, FormatFloat('#,##0.00', p2 / 100)]));
  AgregaParte(HxRango(9, 10), 'Precio 3',
    Format('2 bytes BCD (4 digitos, MSB primero) = %d / 100 = $%s',
      [p3, FormatFloat('#,##0.00', p3 / 100)]));

  ValidaChecksum(4);
  FNota := 'Cambia los 3 niveles de precio de un dispensario en un solo ' +
    'comando (a diferencia de Bennett); aplica a todo el dispensario, sin campo de lado.';
end;

// ---------------------------------------------------------------------------
// $A9 -- TOTALIZADORES
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaA9TX;
begin
  FTipo      := '$A9 - Solicitar TOTALIZADOR de un producto [ComandoN]';
  FDireccion := 'TX: Consola I-Gas -> Dispensario TEAM';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$A9 = leer totalizador');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 3));
  AgregaParte(Hx(FBytes[4]), 'Lado', Format('BCD = %.2d', [TokenBCD(FBytes[4])]));
  AgregaParte(Hx(FBytes[5]), 'Producto',
    Format('BCD = %.2d (numero de producto/grado del que se piden totales)',
      [TokenBCD(FBytes[5])]));
  ValidaChecksum(4);
  FNota := 'I-Gas guarda localmente el producto solicitado (AuxCmndN) para ' +
    'interpretar la respuesta, ya que esta no vuelve a traer el numero de producto.';
end;

procedure TAnalizadorTeam.InterpretaA9RX;
var
  totalRaw: Int64;
begin
  FTipo      := '$A9 - Respuesta: TOTALIZADOR acumulado';
  FDireccion := 'RX: Dispensario TEAM -> Consola I-Gas';
  AgregaParte(Hx(FBytes[0]), 'Opcode', 'Eco de $A9');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d (eco)', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 8));
  AgregaParte(Hx(FBytes[4]), 'Lado',
    Format('BCD = %.2d (no leido por el driver: usa localmente el producto pedido)',
      [TokenBCD(FBytes[4])]));

  totalRaw := ValorBCD(5, 6); // 6 bytes BCD, MSB primero = 12 digitos

  AgregaParte(HxRango(5, 10), 'Total acumulado',
    Format('6 bytes BCD (12 digitos, MSB primero) = %d. Con TresDecimTotTeam=Si: ' +
      '/1000 = %s L; en caso contrario (default): /100 = %s',
      [totalRaw, FormatFloat('#,##0.000', totalRaw / 1000),
       FormatFloat('#,##0.00', totalRaw / 100)]));

  ValidaChecksum(4);
  FNota := 'El layout exacto de los 6 bytes del total se infirio del codigo ' +
    'fuente (no hay un ejemplo literal como el del A3); pendiente de confirmar en campo.';
end;

// ---------------------------------------------------------------------------
// $E0 -- CODIGO DE ACCESO (ComandoW) -- reservado, no conectado actualmente
// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.InterpretaE0;
begin
  FTipo      := '$E0 - CODIGO DE ACCESO [ComandoW] (reservado, no conectado)';
  FDireccion := 'TX: Consola I-Gas -> Dispensario TEAM (funcion no usada actualmente)';
  AgregaParte(Hx(FBytes[0]), 'Opcode', '$E0 = comando con codigo de acceso (CodigoTeam)');
  AgregaParte(Hx(FBytes[1]), 'Dispensador', Format('BCD = %.2d', [TokenBCD(FBytes[1])]));
  AgregaParte(Hx(FBytes[2]), 'Fijo', 'Siempre $00');
  AgregaParte(Hx(FBytes[3]), 'Longitud', DescLen(3, 6));
  AgregaParte(Hx(FBytes[4]), 'Valor', Format('BCD = %.2d', [TokenBCD(FBytes[4])]));
  AgregaParte(Hx(FBytes[5]), 'Lado', Format('BCD = %.2d', [TokenBCD(FBytes[5])]));
  AgregaParte(HxRango(6, 8), 'Codigo TEAM',
    Format('3 bytes BCD (6 digitos, MSB primero) = %.6d (variable CodigoTeam del INITIALIZE)',
      [ValorBCD(6, 3)]));
  ValidaChecksum(4);
  FNota := 'ComandoW esta definido pero ninguna rama del driver lo invoca ' +
    '(codigo muerto/reservado). Ademas espera 6 campos en la deteccion de fin ' +
    'de trama y arma una de 10 bytes: posible inconsistencia no confirmada en campo.';
end;

// ---------------------------------------------------------------------------

procedure TAnalizadorTeam.Analiza(const AEntrada: string; AContexto: Integer);
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
      '(ej. "A3 05 00 02 01 01")';
    Exit;
  end;
  if n = 0 then begin
    FTipo := 'Sin datos. Capture o pegue una trama.';
    Exit;
  end;

  SetLength(FBytes, n);
  for i := 0 to n - 1 do
    FBytes[i] := b[i];

  if ((FBytes[0] shr 4) <> $A) and ((FBytes[0] shr 4) <> $E) then begin
    FTipo := 'Trama no reconocida: el primer byte debe tener nibble alto ' +
      '$A o $E (marcador de inicio de trama TEAM; ningun byte de datos BCD ' +
      'lo tiene, ya que sus nibbles son siempre 0..9)';
    FDireccion := '(desconocida)';
    AgregaParte(HxRango(0, n - 1), 'Datos', 'No inicia con un opcode valido');
    Exit;
  end;

  case FBytes[0] of
    opESTATUS:
      if n = 6 then InterpretaA3TX
      else if n = 9 then InterpretaA3RX
      else Desconocido('A3', n, '6 bytes (TX) u 9 bytes (RX)');
    opDISPLAY:
      if n = 7 then InterpretaA1TX
      else if n = 11 then InterpretaA1RX
      else Desconocido('A1', n, '7 bytes (TX) u 11 bytes (RX)');
    opBLOQUEO:
      if n = 6 then InterpretaA0
      else Desconocido('A0', n, '6 bytes');
    opPRESET:
      if n = 11 then InterpretaA5
      else Desconocido('A5', n, '11 bytes');
    opPRECIOS:
      if n = 12 then InterpretaA6
      else Desconocido('A6', n, '12 bytes');
    opTOTALES:
      if n = 7 then InterpretaA9TX
      else if n = 12 then InterpretaA9RX
      else Desconocido('A9', n, '7 bytes (TX) u 12 bytes (RX)');
    opCODIGO:
      if n = 10 then InterpretaE0
      else Desconocido('E0', n, '10 bytes');
  else
    FTipo := Format('Opcode $%s no reconocido (se esperaba A0/A1/A3/A5/A6/A9/E0)',
      [IntToHex(FBytes[0], 2)]);
    FDireccion := '(desconocida)';
    AgregaParte(HxRango(0, n - 1), 'Datos', 'No corresponde a ningun comando de UIGASTEAM');
  end;
end;

procedure TAnalizadorTeam.CargaEjemplos(sl: TStrings);
begin
  // TX: comandos sencillos (checksum calculado con el algoritmo real,
  // ValidaChecksumTeam: suma BCD de campos 5..N-1 mod 100)
  sl.Add('A3 05 00 02 01 01');                        // poll estatus disp 5 lado 1
  sl.Add('A1 05 00 03 01 00 01');                      // leer display, litros
  sl.Add('A1 05 00 03 01 01 02');                      // leer display, pesos
  sl.Add('A0 05 00 02 06 06');                         // bloquear (detener)
  sl.Add('A0 05 00 02 09 09');                         // desbloquear (reanudar)
  sl.Add('A5 03 00 07 02 06 00 02 50 00 60');          // preset importe $250.00
  sl.Add('A5 03 00 07 02 09 00 04 00 00 15');          // preset 40.000 L
  sl.Add('A6 04 00 08 06 20 50 20 50 18 90 54');       // cambio 3 precios ($20.50/$20.50/$18.90)
  sl.Add('A9 06 00 03 01 02 03');                      // solicita totales, producto 2

  // RX: respuestas (el A3 de abajo es un ejemplo LITERAL tomado del comentario
  // real del codigo fuente: "// A3 03 00 05 02 00 01 00 03")
  sl.Add('A3 03 00 05 02 00 01 00 03');                // estatus real: inactivo, manguera 1
  sl.Add('A3 07 00 05 01 02 01 00 04');                // estatus: despachando (bit1)
  sl.Add('A3 07 00 05 01 20 00 00 21');                // estatus: autorizado (bit5)
  sl.Add('A3 07 00 05 01 40 00 00 41');                // estatus: modo prepago, inactivo
  sl.Add('A3 07 00 05 01 01 03 00 05');                // estatus: autorizado bit0, manguera 3
  sl.Add('A1 05 00 07 01 00 00 01 25 50 77');           // display litros: 125.50 L
  sl.Add('A1 05 00 07 01 01 00 17 82 50 51');           // display pesos: $1,782.50
  sl.Add('A5 03 00 07 02 06 00 02 50 00 60');           // eco preset importe $250.00
  sl.Add('A6 04 00 08 06 20 50 20 50 18 90 54');        // eco cambio de precios
  sl.Add('A9 06 00 08 01 00 00 12 34 56 78 81');        // totales: 12,345.678 (o 123,456.78)

  // Comando reservado / no conectado (ver nota en InterpretaE0)
  sl.Add('E0 05 00 06 01 01 00 12 34 48');              // codigo de acceso (ComandoW)

  // Checksum incorrecto a proposito (basado en el ejemplo real; el correcto es 03)
  sl.Add('A3 03 00 05 02 00 01 00 04');

  // Trama no reconocida (nibble alto del primer byte no es A ni E)
  sl.Add('12 34 56');
end;

end.
