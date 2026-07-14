unit UProtoWayneCns;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO WAYNE CONSOLA (basado en UIGASWAYNE.pas de I-Gas)
  ----------------------------------------------------------------------------
  NO confundir con Wayne 2W (binario byte+complemento): este es el protocolo
  ASCII de la consola Wayne / Wayne Fusion.

  Trama:  <STX> payload <ETX> BCC
          STX=#2  ETX=#3   BCC = XOR de todos los bytes de (payload + ETX)
          (mismo empaque y BCC-XOR que PAM). Si el BCC recibido no coincide,
          el driver convierte la trama en NAK y la descarta.

  Comandos TX (Consola I-Gas -> Wayne):
    B00                      poll de estatus de todas las posiciones
    A + pos(2) + 00          solicita lectura de venta de una posicion
    C + pos(2) + prod + 0    solicita totalizador de un producto
    N + maxpos(2) + modo     inicializacion: num. de posiciones + ModoPrecioWayne
    l1                       enlace/handshake (la respuesta l1 arranca el Timer)
    h + pos(2) + 00          desenllave (paso 1) al refrescar posiciones
    k + pos(2) + 00          desenllave (paso 2)
    g + pos(2) + mapa        mapeo de productos por posicion (relleno con 0 a 10)
    a + prod + tier + nivel + 0 + precio(4) [+ 0]   cambio de precio
    S + pos(2) + 00          autorizar sin limite (preset abierto)
    P + pos(2) + tipo + nivel + valor(8) + grado    preset importe/litros
    E + pos(2)               STOP / desautorizar
    G + pos(2)               reanudar (tras varios reintentos usa R)
    R + pos(2) [+ 0]         venta completa / fin de venta

  Respuestas RX (Wayne -> Consola I-Gas):
    l1                       confirma el enlace
    B00 + digitos            un digito de estatus por posicion
    A + pos(2) + ...         lectura de venta (vol/importe/precio, todo /1000)
    C + pos(2) + prod + ...  totalizador (9 digitos / 100)
    ACK / NAK

  Estatus: 0=SinCom, 1=Inactivo, 2=Cargando, 3=FinDeCarga, 5=Llamando,
  8=Detenido, 9=Autorizado (7=Deshabilitado, interno de I-Gas).
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorWayneCns = class(TAnalizadorBase)
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

function TAnalizadorWayneCns.Nombre: string;
begin
  Result := 'Wayne';
end;

function TAnalizadorWayneCns.CalculaBCC(const ss: string): Char;
var
  i: Integer;
  x: Byte;
begin
  x := 0;
  for i := 1 to Length(ss) do
    x := x xor Ord(ss[i]);
  Result := Char(x);
end;

function TAnalizadorWayneCns.DescEstatus(const c: Char): string;
begin
  case c of
    '0': Result := 'Sin comunicacion';
    '1': Result := 'Inactivo (Idle)';
    '2': Result := 'Cargando (In Use)';
    '3': Result := 'Fin de carga (Used)';
    '5': Result := 'Llamando (Calling) - pistola levantada';
    '8': Result := 'Detenido (Stopped) - I-Gas reintenta con G.. y luego R..';
    '9': Result := 'Autorizado';
  else
    Result := 'Desconocido';
  end;
end;

function TAnalizadorWayneCns.DigitosAValor(const s: string; ADiv: Integer;
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

function TAnalizadorWayneCns.NormalizaEntrada(const s: string): string;

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

procedure TAnalizadorWayneCns.InterpretaB(const lin: string);
var
  ss: string;
  xpos: Integer;
begin
  if Length(lin) <= 3 then begin
    FTipo      := 'B - Sondeo de estatus de TODAS las posiciones (poll)';
    FDireccion := 'TX: Consola I-Gas -> Wayne';
    AgregaParte(lin[1], 'Comando', 'Letra "B": solicita el estatus global');
    if Length(lin) >= 3 then
      AgregaParte(Copy(lin, 2, 2), 'Direccion',
        '"00" = difusion. Enviado cada ciclo del Timer1');
    Exit;
  end;

  FTipo      := 'B - Respuesta: estatus de todas las posiciones';
  FDireccion := 'RX: Wayne -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "B" (estatus global)');
  AgregaParte(Copy(lin, 2, 2), 'Direccion', 'Eco de "00"');

  ss := Copy(lin, 4, Length(lin) - 3);
  FNota := Format('La respuesta reporta %d posiciones de carga (UN digito ' +
    'de estatus por posicion). Con estatus 3 y carga en curso, I-Gas sigue ' +
    'reportando 2 al Bridge hasta obtener la lectura final.', [Length(ss)]);
  for xpos := 1 to Length(ss) do
    AgregaParte(ss[xpos], Format('Posicion %.2d', [xpos]),
      Format('Estatus %s: %s', [ss[xpos], DescEstatus(ss[xpos])]));
end;

procedure TAnalizadorWayneCns.InterpretaA(const lin: string);
var
  vol, imp, pre: string;
begin
  if Length(lin) <= 5 then begin
    FTipo      := 'A - Solicita LECTURA de venta de una posicion';
    FDireccion := 'TX: Consola I-Gas -> Wayne';
    AgregaParte(lin[1], 'Comando',
      'Solicita volumen, importe y precio de la venta en curso/final');
    AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    if Length(lin) >= 4 then
      AgregaParte(Copy(lin, 4, 2), 'Fijo', '"00" = terminador del comando');
    Exit;
  end;

  FTipo      := 'A - Respuesta: lectura de venta';
  FDireccion := 'RX: Wayne -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "A" (lectura de venta)');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');
  AgregaParte(Copy(lin, 4, 1), 'Grado activo',
    'Posicion del producto que despacha (1..4); 0 conserva el anterior');
  if Length(lin) >= 5 then
    AgregaParte(lin[5], 'No leido', 'Caracter [5] no interpretado por I-Gas');
  vol := Copy(lin, 6, 8);
  AgregaParte(vol, 'Volumen',
    'Digitos [6..13] / 1000 = ' + DigitosAValor(vol, 1000, 3) + ' L');
  imp := Copy(lin, 14, 8);
  AgregaParte(imp, 'Importe',
    'Digitos [14..21] / 1000 = $' + DigitosAValor(imp, 1000, 2) +
    ' (con DigitosImporteA>0 el offset se corre)');
  pre := Copy(lin, 22, 5);
  AgregaParte(pre, 'Precio',
    'Digitos [22..26] / 1000 = $' + DigitosAValor(pre, 1000, 2) + ' /L');
  FNota := 'Offsets con la variable DigitosImporteA=0 (por defecto): ' +
    'importe en [14+n..] y precio en [22+n..26] rellenado con ceros. ' +
    'El driver corrige el importe: si 2*vol*precio<importe lo divide entre ' +
    '10; si importe<vol*precio*0.9 recalcula importe=vol*precio; si no, ' +
    'reconcilia el volumen = importe/precio. AjusteWayne/2/3 y ' +
    'WayneAjusteImporte modifican esta logica.';
end;

procedure TAnalizadorWayneCns.InterpretaC(const lin: string);
var
  tot: string;
begin
  if Length(lin) <= 5 then begin
    FTipo      := 'C - Solicita TOTALIZADOR de un producto';
    FDireccion := 'TX: Consola I-Gas -> Wayne';
    AgregaParte(lin[1], 'Comando', 'Solicita el total de un producto');
    AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    if Length(lin) >= 4 then
      AgregaParte(lin[4], 'Producto',
        'Posicion del producto (grado) a consultar');
    if Length(lin) >= 5 then
      AgregaParte(lin[5], 'Fijo', '"0" = terminador del comando');
    Exit;
  end;

  FTipo      := 'C - Respuesta: totalizador de un producto';
  FDireccion := 'RX: Wayne -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "C" (total)');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');
  AgregaParte(lin[4], 'Producto', 'Posicion del producto (grado)');
  if Length(lin) >= 5 then
    AgregaParte(lin[5], 'No leido', 'Caracter [5] no interpretado');
  tot := Copy(lin, 6, 9);
  AgregaParte(tot, 'Total litros',
    'Digitos [6..14] / 100 = ' + DigitosAValor(tot, 100, 2) +
    ' L (con WayneFusion=Si y DigVol=1 se divide entre 10)');
end;

procedure TAnalizadorWayneCns.InterpretaPayload(const lin: string);
var
  resto: string;
begin
  if lin = '' then begin
    FTipo := 'Trama vacia';
    Exit;
  end;

  if lin = idACK then begin
    FTipo      := 'ACK (06h) - Confirmacion';
    FDireccion := 'RX: Wayne -> Consola I-Gas';
    AgregaParte('<ACK>', 'Control', 'La consola Wayne ACEPTO el comando anterior');
    Exit;
  end;
  if lin = idNAK then begin
    FTipo      := 'NAK (15h) - Rechazo';
    FDireccion := 'RX: Wayne -> Consola I-Gas';
    AgregaParte('<NAK>', 'Control',
      'Rechazo del comando anterior. OJO: I-Gas tambien convierte en NAK ' +
      'las tramas recibidas con BCC invalido');
    Exit;
  end;

  case lin[1] of
    'B': InterpretaB(lin);
    'A': InterpretaA(lin);
    'C': InterpretaC(lin);

    'l': begin
           FTipo := 'l - ENLACE (handshake) con la consola';
           if Length(lin) >= 2 then begin
             if lin[2] = '1' then begin
               FDireccion := 'TX/RX (mismo formato en ambos sentidos)';
               AgregaParte(lin, 'Enlace',
                 '"l1": I-Gas lo envia al iniciar; la respuesta "l1" ' +
                 'habilita el Timer del ciclo. Otro valor = error de ' +
                 'comunicacion con la consola');
             end
             else begin
               FDireccion := 'RX: Wayne -> Consola I-Gas';
               AgregaParte(lin, 'Enlace',
                 'Valor distinto de "l1": el driver lanza "Error en ' +
                 'comunicacion con CONSOLA"');
             end;
           end;
         end;

    'N': begin
           FTipo      := 'N - INICIALIZACION (posiciones + modo de precio)';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('N', 'Comando',
             'Configura la consola al iniciar, tras perdida de comunicacion ' +
             'o cuando todas las posiciones quedan detenidas');
           AgregaParte(Copy(lin, 2, 2), 'Posiciones',
             'Numero maximo de posiciones de carga (MaxPosCarga)');
           if Length(lin) >= 4 then
             AgregaParte(lin[4], 'Modo de precio',
               'Variable ModoPrecioWayne (def. "1")');
           FNota := 'Solo se envia con WayneFusion=No o MapeoFusion=Si.';
         end;

    'h': begin
           FTipo      := 'h - DESENLLAVE de posicion (paso 1)';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('h', 'Comando',
             'Primer paso del refresco de enllavados de una posicion inactiva');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           AgregaParte(Copy(lin, 4, 2), 'Fijo', '"00"');
           FNota := 'Va seguido de k..00 y del mapeo g.. de la posicion.';
         end;

    'k': begin
           FTipo      := 'k - DESENLLAVE de posicion (paso 2)';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('k', 'Comando', 'Segundo paso del refresco de enllavados');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           AgregaParte(Copy(lin, 4, 2), 'Fijo', '"00"');
         end;

    'g': begin
           FTipo      := 'g - MAPEO de productos de la posicion';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('g', 'Comando',
             'Asigna el numero de combustible a cada grado de la posicion');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           resto := Copy(lin, 4, MaxInt);
           if resto <> '' then
             AgregaParte(resto, 'Mapa',
               'Un digito de combustible por grado, rellenado con "0" hasta ' +
               'completar 10 caracteres del comando');
         end;

    'a': begin
           FTipo      := 'a - CAMBIO DE PRECIO';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('a', 'Comando', 'Actualiza el precio de un producto');
           if Length(lin) >= 2 then
             AgregaParte(lin[2], 'Producto', 'Numero de producto (grado) 1..4');
           if Length(lin) >= 3 then
             AgregaParte(lin[3], 'Tier',
               'Variable TierLavelWayne (def. "0")');
           if Length(lin) >= 4 then begin
             if lin[4] = '1' then
               AgregaParte(lin[4], 'Nivel', '"1" = CONTADO')
             else if lin[4] = '0' then
               AgregaParte(lin[4], 'Nivel', '"0" = CREDITO')
             else
               AgregaParte(lin[4], 'Nivel', 'Nivel desconocido');
           end;
           if Length(lin) >= 5 then
             AgregaParte(lin[5], 'Fijo', '"0"');
           resto := Copy(lin, 6, 4);
           if resto <> '' then
             AgregaParte(resto, 'Precio',
               '4 digitos en centavos = $' + DigitosAValor(resto, 100, 2));
           if Length(lin) >= 10 then
             AgregaParte(lin[10], 'Sufijo Fusion',
               '"0" adicional cuando WayneFusion=Si');
           FNota := 'I-Gas envia contado (nivel 1) y de inmediato credito ' +
             '(nivel 0) con el mismo precio, con 250 ms de separacion.';
         end;

    'S': begin
           FTipo      := 'S - AUTORIZAR sin limite (preset abierto)';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('S', 'Comando',
             'Autoriza la posicion sin monto tope (preset con importe 0)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           AgregaParte(Copy(lin, 4, 2), 'Fijo', '"00"');
         end;

    'P': begin
           FTipo      := 'P - PRESET';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('P', 'Comando', 'Fija el tope de la venta');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '0' then
               AgregaParte(lin[4], 'Tipo', '"0" = preset por IMPORTE')
             else if lin[4] = '1' then
               AgregaParte(lin[4], 'Tipo', '"1" = preset por LITROS')
             else
               AgregaParte(lin[4], 'Tipo', 'Tipo desconocido');
           end;
           if Length(lin) >= 5 then
             AgregaParte(lin[5], 'Nivel de precio',
               '"0" (el driver siempre envia 0)');
           resto := Copy(lin, 6, 8);
           if resto <> '' then begin
             if (Length(lin) >= 4) and (lin[4] = '1') then
               AgregaParte(resto, 'Litros',
                 '8 digitos; decimales segun DecimalesPresetWayneLitros ' +
                 '(def. 3: FormatFloat 00000.000) = ' +
                 DigitosAValor(resto, 1000, 3) + ' L')
             else
               AgregaParte(resto, 'Importe',
                 '8 digitos; decimales segun DecimalesPresetWayne ' +
                 '(def. -1: FormatFloat 000000.00) = $' +
                 DigitosAValor(resto, 100, 2));
           end;
           if Length(lin) >= 14 then begin
             if lin[14] = '0' then
               AgregaParte(lin[14], 'Grado', '"0" = todos los productos')
             else
               AgregaParte(lin[14], 'Grado',
                 'Posicion del producto a autorizar (1..4); requiere ' +
                 'SoportaSeleccionProducto=Si');
           end;
         end;

    'E': begin
           FTipo      := 'E - STOP / DESAUTORIZAR';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('E', 'Comando',
             'Detiene el despacho / quita autorizacion. Tambien lo envia ' +
             'I-Gas al pasar de Cargando a Autorizada inesperadamente');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'G': begin
           FTipo      := 'G - REANUDAR despacho';
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           AgregaParte('G', 'Comando',
             'Reanuda una posicion detenida (estatus 8). Tras varios ' +
             'reintentos I-Gas cambia a R..');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'R': begin
           FDireccion := 'TX: Consola I-Gas -> Wayne';
           if Length(lin) >= 4 then begin
             FTipo := 'R - VENTA COMPLETA (fin de venta)';
             AgregaParte('R', 'Comando',
               'Cierra/paga la transaccion (comando FINV con estatus 3)');
             AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
             AgregaParte(lin[4], 'Fijo', '"0"');
           end
           else begin
             FTipo := 'R - Liberar posicion detenida (alternativa a G)';
             AgregaParte('R', 'Comando',
               'Enviado cuando G.. no logra reanudar la posicion detenida');
             AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           end;
         end;
  else
    FTipo      := 'Comando NO RECONOCIDO por esta interfaz';
    FDireccion := '(desconocida)';
    AgregaParte(lin, 'Datos', 'No corresponde a ningun comando de UIGASWAYNE');
  end;
end;

procedure TAnalizadorWayneCns.Analiza(const AEntrada: string;
  AContexto: Integer);
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
          'INCORRECTO (el driver convierte la trama en NAK y la descarta)',
          [IntToHex(Ord(bcc[1]), 2), IntToHex(Ord(bccCalc), 2)]), False);
    end
    else
      PonValidacion('BCC no incluido en la captura. Calculado (XOR): $' +
        IntToHex(Ord(bccCalc), 2), True);
  end;
end;

procedure TAnalizadorWayneCns.CargaEjemplos(sl: TStrings);
begin
  sl.Add('B00');                                    // poll de estatus
  sl.Add('<STX>B0012305980<ETX>');                  // respuesta estatus 8 pos
  sl.Add('A0100');                                  // solicita lectura
  sl.Add('<STX>A012000025500005482502150<ETX>');    // lectura 25.5L $548.25 @21.50
  sl.Add('C0110');                                  // solicita totalizador
  sl.Add('<STX>C0110000123456<ETX>');               // total 1,234.56 L
  sl.Add('l1');                                     // enlace
  sl.Add('N161');                                   // init 16 posiciones modo 1
  sl.Add('h0100');                                  // desenllave paso 1
  sl.Add('k0100');                                  // desenllave paso 2
  sl.Add('g0112000000');                            // mapeo grados 1,2
  sl.Add('a10102050');                              // precio contado $20.50
  sl.Add('a10002050');                              // precio credito $20.50
  sl.Add('a101020500');                             // precio contado (Fusion)
  sl.Add('S0100');                                  // autorizar sin limite
  sl.Add('P0500002500000');                         // preset importe $250.00
  sl.Add('P0610000400002');                         // preset 40.000 L grado 2
  sl.Add('E07');                                    // stop / desautorizar
  sl.Add('G08');                                    // reanudar
  sl.Add('R090');                                   // venta completa
  sl.Add('R10');                                    // liberar detenida
  sl.Add('<ACK>');
  sl.Add('<NAK>');
  // BCC incorrecto a proposito (real $43)
  sl.Add('<STX>A0100<ETX>' + Char($44));
end;

end.
