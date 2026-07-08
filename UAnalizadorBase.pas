unit UAnalizadorBase;

{ ============================================================================
  CLASE BASE PARA ANALIZADORES DE PROTOCOLO (Delphi 7)
  ----------------------------------------------------------------------------
  Cada marca/protocolo se implementa en su propia unidad heredando de
  TAnalizadorBase e implementando:
    - Nombre       : titulo de la pestana
    - CargaEjemplos: comandos de ejemplo para el combo
    - CargaContextos (opcional): interpretaciones alternas (p.ej. "Respuesta a
      Estatus" en protocolos binarios donde la trama no se auto-describe)
    - Analiza      : llena FTipo, FDireccion, FPartes, etc.

  El render (trama coloreada + desglose + validacion + nota) es comun.
  Para agregar una marca nueva: crear UProtoXxx.pas y registrarla en
  UPrincipal.FormCreate con RegistraAnalizador(TAnalizadorXxx.Create).
  ============================================================================ }

interface

uses
  Windows, SysUtils, Classes, Graphics, ComCtrls;

type
  TParte = record
    Texto      : string;   // fragmento crudo de la trama
    Nombre     : string;   // nombre corto de la parte
    Descripcion: string;   // indicacion breve
  end;

  TAnalizadorBase = class
  protected
    FPartes    : array of TParte;
    FTipo      : string;   // nombre/tipo del comando detectado
    FDireccion : string;   // TX consola->bomba / RX bomba->consola
    FNota      : string;   // observaciones
    FPrefijo   : string;   // texto gris antes de las partes (p.ej. <STX> / 00 00)
    FSufijo    : string;   // texto gris despues (p.ej. <ETX><BCC> / FF)
    FValidacion: string;   // resultado de BCC / complementos
    FValidaOk  : Boolean;
    FTieneVal  : Boolean;

    procedure Limpia;
    procedure AgregaParte(const ATexto, ANombre, ADescripcion: string);
    procedure PonValidacion(const ATexto: string; AOk: Boolean);
  public
    function  Nombre: string; virtual; abstract;
    procedure CargaEjemplos(sl: TStrings); virtual; abstract;
    procedure CargaContextos(sl: TStrings); virtual;   // vacio = sin combo
    procedure Analiza(const AEntrada: string; AContexto: Integer);
      virtual; abstract;
    procedure Render(re: TRichEdit);
  end;

const
  clGris    = TColor($00808080);
  clNaranja = TColor($000066CC);

  // Paleta para las partes del comando (se recicla con mod)
  ColoresParte: array[0..7] of TColor = (
    clBlue, clRed, clGreen, TColor($00800080),
    TColor($000066CC), clTeal, clMaroon, clNavy);

implementation

procedure TAnalizadorBase.Limpia;
begin
  SetLength(FPartes, 0);
  FTipo       := '';
  FDireccion  := '';
  FNota       := '';
  FPrefijo    := '';
  FSufijo     := '';
  FValidacion := '';
  FValidaOk   := False;
  FTieneVal   := False;
end;

procedure TAnalizadorBase.AgregaParte(const ATexto, ANombre,
  ADescripcion: string);
var
  n: Integer;
begin
  n := Length(FPartes);
  SetLength(FPartes, n + 1);
  FPartes[n].Texto       := ATexto;
  FPartes[n].Nombre      := ANombre;
  FPartes[n].Descripcion := ADescripcion;
end;

procedure TAnalizadorBase.PonValidacion(const ATexto: string; AOk: Boolean);
begin
  FValidacion := ATexto;
  FValidaOk   := AOk;
  FTieneVal   := True;
end;

procedure TAnalizadorBase.CargaContextos(sl: TStrings);
begin
  // por defecto sin contextos (el combo se oculta)
end;

procedure TAnalizadorBase.Render(re: TRichEdit);

  procedure Escribe(const s: string; AColor: TColor;
    AEstilos: TFontStyles; ATam: Integer);
  begin
    re.SelStart := re.GetTextLen;
    re.SelLength := 0;
    re.SelAttributes.Name  := 'Courier New';
    re.SelAttributes.Color := AColor;
    re.SelAttributes.Style := AEstilos;
    re.SelAttributes.Size  := ATam;
    re.SelText := s;
  end;

  procedure EscribeLn(const s: string; AColor: TColor;
    AEstilos: TFontStyles; ATam: Integer);
  begin
    Escribe(s + #13#10, AColor, AEstilos, ATam);
  end;

var
  i: Integer;
begin
  re.Lines.BeginUpdate;
  try
    re.Clear;

    // ---- Encabezado
    EscribeLn('TIPO:      ' + FTipo, clBlack, [fsBold], 10);
    EscribeLn('DIRECCION: ' + FDireccion, clGris, [], 10);
    EscribeLn('', clBlack, [], 10);

    // ---- La trama coloreada
    Escribe('  ', clBlack, [], 14);
    if FPrefijo <> '' then
      Escribe(FPrefijo, clGris, [], 14);
    for i := 0 to High(FPartes) do
      Escribe(FPartes[i].Texto, ColoresParte[i mod 8], [fsBold], 14);
    if FSufijo <> '' then
      Escribe(FSufijo, clGris, [], 14);
    EscribeLn('', clBlack, [], 14);
    EscribeLn('', clBlack, [], 10);

    // ---- Desglose parte por parte
    EscribeLn('DESGLOSE:', clBlack, [fsBold], 10);
    for i := 0 to High(FPartes) do begin
      Escribe('  # ', ColoresParte[i mod 8], [fsBold], 10);
      Escribe(Format('%-14s', [FPartes[i].Texto]),
        ColoresParte[i mod 8], [fsBold], 10);
      Escribe(' ' + FPartes[i].Nombre + ': ',
        ColoresParte[i mod 8], [fsBold], 10);
      EscribeLn(FPartes[i].Descripcion, ColoresParte[i mod 8], [], 10);
    end;

    // ---- Validacion (BCC / complementos)
    if FTieneVal then begin
      EscribeLn('', clBlack, [], 10);
      if FValidaOk then
        EscribeLn(FValidacion, clGreen, [fsBold], 10)
      else
        EscribeLn(FValidacion, clRed, [fsBold], 10);
    end;

    // ---- Nota
    if FNota <> '' then begin
      EscribeLn('', clBlack, [], 10);
      EscribeLn('NOTA: ' + FNota, clNaranja, [fsItalic], 10);
    end;
  finally
    re.Lines.EndUpdate;
  end;
end;

end.
