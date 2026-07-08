unit UProtoBennett;

{ ============================================================================
  ANALIZADOR DEL PROTOCOLO BENNETT (basado en UIGASBENNETT.pas de I-Gas)
  ----------------------------------------------------------------------------
  Trama:  <STX> payload <ETX> BCC
          STX=#2  ETX=#3   BCC = char(256 - (suma(payload+ETX) mod 256))
  Protocolo ASCII. Comandos TX: B,A,1,N,U,K,L,E,S,P,5,F,J
  Respuestas RX: B..., A..., 1..., N..., ACK(#6), NAK(#21)
  ============================================================================ }

interface

uses
  SysUtils, Classes, UAnalizadorBase;

type
  TAnalizadorBennett = class(TAnalizadorBase)
  private
    function CalculaBCC(const ss: string): Char;
    function DescEstatus(const c: Char): string;
    function DigitosAImporte(const s: string; ADecimales: Integer): string;
    function NormalizaEntrada(const s: string): string;
    procedure InterpretaPayload(const lin: string);
    procedure InterpretaB(const lin: string);
    procedure InterpretaA1(const lin: string);
    procedure InterpretaN(const lin: string);
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

function TAnalizadorBennett.Nombre: string;
begin
  Result := 'Bennett';
end;

function TAnalizadorBennett.CalculaBCC(const ss: string): Char;
var
  i, n, m: Integer;
begin
  n := 0;
  for i := 1 to Length(ss) do
    n := n + Ord(ss[i]);
  m := n mod 256;
  Result := Char(256 - m);
end;

function TAnalizadorBennett.DescEstatus(const c: Char): string;
begin
  case c of
    '0': Result := 'Sin comunicacion';
    '1': Result := 'Inactivo (Idle)';
    '2': Result := 'Autorizado';
    '3': Result := 'Pistola levantada';
    '4': Result := 'Listo para despachar';
    '5': Result := 'Despachando';
    '6': Result := 'Detenido';
    '7': Result := 'Fin de venta';
    '8': Result := 'Venta pendiente';
    '9': Result := 'Error';
  else
    Result := 'Desconocido';
  end;
end;

function TAnalizadorBennett.DigitosAImporte(const s: string;
  ADecimales: Integer): string;
var
  ent, dec: string;
  v: Double;
begin
  Result := s;
  if (s = '') or (Length(s) <= ADecimales) then Exit;
  ent := Copy(s, 1, Length(s) - ADecimales);
  dec := Copy(s, Length(s) - ADecimales + 1, ADecimales);
  try
    v := StrToFloat(ent + DecimalSeparator + dec);
    Result := FormatFloat('#,##0.' + StringOfChar('0', ADecimales), v);
  except
    Result := s;
  end;
end;

function TAnalizadorBennett.NormalizaEntrada(const s: string): string;

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
  r := StringReplace(r, '<SOH>', #1,    [rfReplaceAll, rfIgnoreCase]);
  r := StringReplace(r, '<ETB>', #23,   [rfReplaceAll, rfIgnoreCase]);
  if EsHexDump(r, hx) then
    r := hx;
  Result := r;
end;

procedure TAnalizadorBennett.InterpretaB(const lin: string);
var
  sslin: string;
  xpos, npos: Integer;
  m, e: Char;
begin
  if Length(lin) <= 3 then begin
    FTipo      := 'B - Sondeo de estatus de TODAS las bombas (poll)';
    FDireccion := 'TX: Consola I-Gas -> Dispensarios';
    AgregaParte(lin[1], 'Comando', 'Letra "B": solicita el estatus global');
    if Length(lin) >= 3 then
      AgregaParte(Copy(lin, 2, 2), 'Direccion',
        '"00" = difusion (broadcast, todas las posiciones)');
    Exit;
  end;

  FTipo      := 'B - Respuesta: estatus de todas las bombas';
  FDireccion := 'RX: Dispensarios -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "B" (estatus global)');
  AgregaParte(Copy(lin, 2, 2), 'Direccion', 'Eco de "00" (broadcast)');

  sslin := Copy(lin, 4, Length(lin) - 3);
  npos  := Length(sslin) div 2;
  FNota := Format('La respuesta reporta %d posiciones de carga ' +
    '(2 caracteres por posicion: manguera activa + estatus).', [npos]);

  for xpos := 1 to npos do begin
    m := sslin[xpos * 2 - 1];
    e := sslin[xpos * 2];
    AgregaParte(m + e,
      Format('Posicion %.2d', [xpos]),
      Format('Manguera/grado activo=%s, Estatus=%s (%s)',
        [m, e, DescEstatus(e)]));
  end;
end;

procedure TAnalizadorBennett.InterpretaA1(const lin: string);
var
  esOcho: Boolean;
  vol, imp, pre: string;
begin
  esOcho := (lin[1] = '1');

  if Length(lin) <= 3 then begin
    if esOcho then
      FTipo := '1 - Solicita venta en curso de UNA bomba (8 digitos)'
    else
      FTipo := 'A - Solicita venta en curso de UNA bomba (6 digitos)';
    FDireccion := 'TX: Consola I-Gas -> Dispensario';
    AgregaParte(lin[1], 'Comando',
      'Solicita volumen, importe y precio de la venta en curso');
    AgregaParte(Copy(lin, 2, 2), 'Posicion',
      'Numero de posicion de carga (bomba), 2 digitos');
    Exit;
  end;

  if esOcho then begin
    FTipo := '1 - Respuesta: venta en curso (formato 8 digitos, Bennett8Digitos=Si)';
    vol := Copy(lin,  5, 8);
    imp := Copy(lin, 13, 8);
    pre := Copy(lin, 21, 5);
  end
  else begin
    FTipo := 'A - Respuesta: venta en curso (formato 6 digitos)';
    vol := Copy(lin,  5, 6);
    imp := Copy(lin, 11, 6);
    pre := Copy(lin, 17, 4);
  end;
  FDireccion := 'RX: Dispensario -> Consola I-Gas';

  AgregaParte(lin[1], 'Comando', 'Eco del comando de lectura de venta');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');
  AgregaParte(Copy(lin, 4, 1), 'Manguera/grado',
    'Manguera o grado activo (I-Gas no usa este caracter)');
  AgregaParte(vol, 'Volumen',
    'Litros x100 (implicito 2 dec.) = ' + DigitosAImporte(vol, 2) + ' L');
  AgregaParte(imp, 'Importe',
    'Pesos x100 (implicito 2 dec.) = $' + DigitosAImporte(imp, 2));
  AgregaParte(pre, 'Precio',
    'Precio unitario x100 = $' + DigitosAImporte(pre, 2) + ' /L');
end;

procedure TAnalizadorBennett.InterpretaN(const lin: string);
var
  i: Integer;
  t: string;
begin
  if Length(lin) <= 3 then begin
    FTipo      := 'N - Solicita TOTALIZADORES (totales) de una bomba';
    FDireccion := 'TX: Consola I-Gas -> Dispensario';
    AgregaParte(lin[1], 'Comando', 'Solicita los totalizadores por manguera');
    AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
    Exit;
  end;

  FTipo      := 'N - Respuesta: totalizadores por manguera';
  FDireccion := 'RX: Dispensario -> Consola I-Gas';
  AgregaParte(lin[1], 'Comando', 'Eco de "N" (totales)');
  AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga que responde');
  for i := 1 to 4 do begin
    t := Copy(lin, 4 + (i - 1) * 10, 10);
    if t = '' then Break;
    AgregaParte(t, Format('Total manguera %d', [i]),
      'Litros x1000 (3 dec. implicitos) = ' + DigitosAImporte(t, 3) + ' L');
  end;
end;

procedure TAnalizadorBennett.InterpretaPayload(const lin: string);
var
  resto: string;
begin
  if lin = '' then begin
    FTipo := 'Trama vacia';
    Exit;
  end;

  if lin = idACK then begin
    FTipo      := 'ACK (06h) - Confirmacion';
    FDireccion := 'RX: Dispensario -> Consola I-Gas';
    AgregaParte('<ACK>', 'Control',
      'El dispensario ACEPTO el comando anterior');
    Exit;
  end;
  if lin = idNAK then begin
    FTipo      := 'NAK (15h) - Rechazo';
    FDireccion := 'RX: Dispensario -> Consola I-Gas';
    AgregaParte('<NAK>', 'Control',
      'El dispensario RECHAZO el comando anterior (error o no valido)');
    Exit;
  end;

  case lin[1] of
    'B':      InterpretaB(lin);
    'A', '1': InterpretaA1(lin);
    'N':      InterpretaN(lin);

    'U': begin
           FTipo      := 'U - Cambio de PRECIO';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('U', 'Comando', 'Actualiza el precio de un producto');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '1' then
               AgregaParte(lin[4], 'Nivel de precio', '"1" = precio CONTADO')
             else if lin[4] = '2' then
               AgregaParte(lin[4], 'Nivel de precio', '"2" = precio CREDITO')
             else
               AgregaParte(lin[4], 'Nivel de precio', 'Nivel de precio desconocido');
           end;
           if Length(lin) >= 5 then
             AgregaParte(lin[5], 'Grado/posicion producto',
               'Numero de grado o manguera a la que aplica el precio (1..4)');
           resto := Copy(lin, 6, MaxInt);
           if resto <> '' then
             AgregaParte(resto, 'Precio',
               'Digitos del precio, 2 decimales implicitos = $' +
               DigitosAImporte(resto, 2));
         end;

    'K': begin
           FTipo      := 'K - MODO DE OPERACION';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('K', 'Comando', 'Configura el modo de pago de la posicion');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '1' then
               AgregaParte(lin[4], 'Modo', '"1" = POSTPAGO (despacha y luego cobra)')
             else if lin[4] = '2' then
               AgregaParte(lin[4], 'Modo', '"2" = PREPAGO (requiere preset previo)')
             else
               AgregaParte(lin[4], 'Modo', 'Modo desconocido');
           end;
         end;

    'L': begin
           FTipo      := 'L - NIVEL DE PRECIOS activo';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('L', 'Comando', 'Selecciona el nivel de precios a usar');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             if lin[4] = '1' then
               AgregaParte(lin[4], 'Nivel', '"1" = CONTADO')
             else if lin[4] = '2' then
               AgregaParte(lin[4], 'Nivel', '"2" = CREDITO')
             else
               AgregaParte(lin[4], 'Nivel', 'Nivel desconocido');
           end;
         end;

    'E': begin
           FTipo      := 'E - DESAUTORIZAR bomba';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('E', 'Comando',
             'Quita la autorizacion (la bomba deja de poder despachar)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;

    'S': begin
           FTipo      := 'S - AUTORIZAR bomba';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('S', 'Comando',
             'Autoriza el despacho en la posicion de carga');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           if Length(lin) >= 4 then begin
             case lin[4] of
               '!': AgregaParte(lin[4], 'Seleccion de producto',
                      '21h = restringe al GRADO 1');
               '"': AgregaParte(lin[4], 'Seleccion de producto',
                      '22h = restringe al GRADO 2');
               '(': AgregaParte(lin[4], 'Seleccion de producto',
                      '28h = restringe al GRADO 3');
               '$': AgregaParte(lin[4], 'Seleccion de producto',
                      '24h = restringe al GRADO 4');
             else
               AgregaParte(lin[4], 'Seleccion de producto',
                 'Caracter de seleccion de grado no reconocido');
             end;
             FNota := 'La seleccion de producto solo se envia cuando ' +
               'SoportaSeleccionProducto=Si; sin ese caracter se autorizan ' +
               'todos los grados.';
           end;
         end;

    'P': begin
           FTipo      := 'P - PRESET por IMPORTE (6 digitos)';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('P', 'Comando',
             'Fija el monto maximo a despachar (modo 6 digitos)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           resto := Copy(lin, 4, MaxInt);
           if resto = '999900' then
             AgregaParte(resto, 'Importe',
               '$9,999.00 = valor tope; I-Gas lo usa para "abrir"/cancelar el preset')
           else
             AgregaParte(resto, 'Importe',
               '6 digitos, 2 decimales implicitos = $' + DigitosAImporte(resto, 2));
         end;

    '5': begin
           FTipo      := '5 - PRESET por IMPORTE (8 digitos, Bennett8Digitos=Si)';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('5', 'Comando',
             'Fija el monto maximo a despachar (modo 8 digitos)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           resto := Copy(lin, 4, MaxInt);
           if resto = '99999900' then
             AgregaParte(resto, 'Importe',
               '$999,999.00 = valor tope; usado para "abrir"/cancelar el preset')
           else
             AgregaParte(resto, 'Importe',
               '8 digitos, 2 decimales implicitos = $' + DigitosAImporte(resto, 2));
         end;

    'F': begin
           FTipo      := 'F - PRESET por VOLUMEN (litros)';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('F', 'Comando',
             'Fija el volumen maximo a despachar, en litros enteros');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
           resto := Copy(lin, 4, MaxInt);
           if resto = '9999' then
             AgregaParte(resto, 'Litros',
               '9999 = valor tope; I-Gas lo envia al terminar para limpiar el limite')
           else
             AgregaParte(resto, 'Litros', '4 digitos enteros = ' + resto + ' L');
         end;

    'J': begin
           FTipo      := 'J - FIN DE VENTA (cierra la transaccion)';
           FDireccion := 'TX: Consola I-Gas -> Dispensario';
           AgregaParte('J', 'Comando',
             'Cierra/libera la venta actual (equivale a pagar la transaccion)');
           AgregaParte(Copy(lin, 2, 2), 'Posicion', 'Posicion de carga, 2 digitos');
         end;
  else
    FTipo      := 'Comando NO RECONOCIDO por esta interfaz';
    FDireccion := '(desconocida)';
    AgregaParte(lin, 'Datos', 'No corresponde a ningun comando de UIGASBENNETT');
  end;
end;

procedure TAnalizadorBennett.Analiza(const AEntrada: string;
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
        PonValidacion(Format('BCC recibido $%s = calculado $%s  -> CORRECTO',
          [IntToHex(Ord(bcc[1]), 2), IntToHex(Ord(bccCalc), 2)]), True)
      else
        PonValidacion(Format('BCC recibido $%s <> calculado $%s  -> INCORRECTO',
          [IntToHex(Ord(bcc[1]), 2), IntToHex(Ord(bccCalc), 2)]), False);
    end
    else
      PonValidacion('BCC no incluido en la captura. Calculado: $' +
        IntToHex(Ord(bccCalc), 2), True);
  end;
end;

procedure TAnalizadorBennett.CargaEjemplos(sl: TStrings);
begin
  sl.Add('P01005000');                              // preset $50.00
  sl.Add('B00');                                    // poll de estatus
  sl.Add('<STX>B001115120500<ETX>');                // respuesta estatus
  sl.Add('A01');                                    // solicita venta (6 dig)
  sl.Add('<STX>A0100125501782501420<ETX>');         // respuesta venta 6 dig
  sl.Add('101');                                    // solicita venta (8 dig)
  sl.Add('<STX>1020000887500012500014200<ETX>');    // respuesta venta 8 dig
  sl.Add('N01');                                    // solicita totales
  sl.Add('<STX>N030001234560000087654000000000000000000000<ETX>');
  sl.Add('P04999900');                              // preset tope (cancela)
  sl.Add('50501234500');                            // preset 8 dig $12,345.00
  sl.Add('F060150');                                // preset 150 litros
  sl.Add('F069999');                                // limpia preset litros
  sl.Add('S07');                                    // autorizar
  sl.Add('S08"');                                   // autorizar solo grado 2
  sl.Add('E10');                                    // desautorizar
  sl.Add('K112');                                   // modo prepago
  sl.Add('K121');                                   // modo postpago
  sl.Add('L132');                                   // nivel precio credito
  sl.Add('U142301630');                             // cambio de precio
  sl.Add('J15');                                    // fin de venta
  sl.Add('<ACK>');
  sl.Add('<NAK>');
end;

end.
