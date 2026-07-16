unit UPrincipal;

{ ============================================================================
  ANALIZADOR DE COMANDOS SERIALES - PROTOCOLOS I-GAS (Delphi 7)
  ----------------------------------------------------------------------------
  Formulario principal: un TPageControl con una pestana por marca/protocolo.
  Las pestanas y sus controles se crean en tiempo de ejecucion a partir de
  la lista de analizadores registrados en FormCreate.

  PARA AGREGAR UNA MARCA NUEVA:
    1. Crear UProtoXxx.pas heredando de TAnalizadorBase (ver UAnalizadorBase).
    2. Agregar la unidad al uses de abajo.
    3. Agregar una linea RegistraAnalizador(TAnalizadorXxx.Create); en
       FormCreate. Nada mas: la pestana, combos y RichEdit se generan solos.
  ============================================================================ }

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ComCtrls, ExtCtrls,
  UAnalizadorBase, UProtoBennett, UProtoWayne2W, UProtoPam, UProtoWayneCns,
  UProtoGilbarco, UProtoTeam, UProtoHongYang;

type
  { TComboComando: combo del comando capturado. Si el protocolo de la
    pestana es binario/hex puro (EsHexPuro=True), al PEGAR texto se
    autoinserta un espacio cada 2 caracteres cuando lo pegado es hex
    continuo sin separadores (p.ej. "0106010F0000E9" -> "01 06 01 0F 00 00
    E9"), para que la trama quede correctamente delimitada en bytes. En
    protocolos ASCII/mixtos (Bennett/PAM/Wayne Consola) no se toca nada,
    porque un texto "todo hex" ahi puede ser en realidad un comando ASCII
    valido (ver FormateaHexContinuo). }
  TComboComando = class(TComboBox)
  public
    EsHexPuro: Boolean;
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TTabProtocolo = record
    Analizador: TAnalizadorBase;
    cboComando: TComboComando;
    cboContexto: TComboBox;   // nil si el protocolo no define contextos
    reSalida  : TRichEdit;
  end;

  TfrmPrincipal = class(TForm)
    PageControl1: TPageControl;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FTabs: array of TTabProtocolo;
    procedure RegistraAnalizador(a: TAnalizadorBase);
    procedure btnAnalizarClick(Sender: TObject);
    procedure cboComandoKeyPress(Sender: TObject; var Key: Char);
    procedure Analizar(idx: Integer);
  public
  end;

// Si `s` es una cadena hexadecimal continua (solo digitos 0-9/A-F/a-f, sin
// espacios ni comas, longitud par y > 2), regresa la misma cadena con un
// espacio cada 2 caracteres para delimitar los bytes. Si `s` ya trae
// separadores, tiene longitud impar, o contiene algun caracter no-hex
// (como pasa con los comandos ASCII de Bennett/PAM/Wayne Consola, p.ej.
// "a101020500" o "D06222"), la regresa sin tocar.
function FormateaHexContinuo(const s: string): string;

var
  frmPrincipal: TfrmPrincipal;

implementation

{$R *.dfm}

function FormateaHexContinuo(const s: string): string;
var
  aux, tok: string;
  i: Integer;
begin
  Result := s;
  aux := Trim(s);
  if (Length(aux) <= 2) or (Length(aux) mod 2 <> 0) then Exit;
  if Pos(' ', aux) > 0 then Exit;
  for i := 1 to Length(aux) do
    if not (aux[i] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;

  tok := '';
  for i := 1 to Length(aux) do begin
    tok := tok + aux[i];
    if (i mod 2 = 0) and (i < Length(aux)) then
      tok := tok + ' ';
  end;
  Result := tok;
end;

{ TComboComando }

procedure TComboComando.WndProc(var Message: TMessage);
begin
  inherited WndProc(Message);
  if EsHexPuro and (Message.Msg = WM_PASTE) then
    Text := FormateaHexContinuo(Text);
end;

procedure TfrmPrincipal.RegistraAnalizador(a: TAnalizadorBase);
var
  idx: Integer;
  tab: TTabSheet;
  pnl: TPanel;
  lbl, lblCtx: TLabel;
  cbo: TComboComando;
  cboCtx: TComboBox;
  btn: TButton;
  re: TRichEdit;
  ctx: TStringList;
begin
  idx := Length(FTabs);
  SetLength(FTabs, idx + 1);
  FTabs[idx].Analizador := a;

  tab := TTabSheet.Create(PageControl1);
  tab.PageControl := PageControl1;
  tab.Caption := a.Nombre;            // <-- nombre de la marca en la pestana

  pnl := TPanel.Create(tab);
  pnl.Parent := tab;
  pnl.Align := alTop;
  pnl.Height := 92;
  pnl.BevelOuter := bvNone;

  lbl := TLabel.Create(pnl);
  lbl.Parent := pnl;
  lbl.Left := 12; lbl.Top := 8;
  lbl.Caption := 'Comando capturado con el espia de puerto:';

  cbo := TComboComando.Create(pnl);
  cbo.Parent := pnl;
  cbo.Left := 12; cbo.Top := 26;
  cbo.Width := 660;
  cbo.Font.Name := 'Courier New';
  cbo.Font.Size := 9;
  cbo.Anchors := [akLeft, akTop, akRight];
  cbo.Tag := idx;
  cbo.EsHexPuro := a.EsHexPuro;
  cbo.OnKeyPress := cboComandoKeyPress;
//  a.CargaEjemplos(cbo.Items);
  if cbo.Items.Count > 0 then
    cbo.Text := cbo.Items[0];
  FTabs[idx].cboComando := cbo;

  btn := TButton.Create(pnl);
  btn.Parent := pnl;
  btn.Left := 750; btn.Top := 24;
  btn.Width := 100; btn.Height := 25;
  btn.Caption := '&Analizar';
  btn.Anchors := [akTop, akRight];
  btn.Tag := idx;
  btn.OnClick := btnAnalizarClick;

  // combo de contexto solo si el protocolo define interpretaciones alternas
  cboCtx := nil;
  ctx := TStringList.Create;
  try
    a.CargaContextos(ctx);
    if ctx.Count > 0 then begin
      lblCtx := TLabel.Create(pnl);
      lblCtx.Parent := pnl;
      lblCtx.Left := 12; lblCtx.Top := 54;
      lblCtx.Caption := 'Interpretar como:';

      cboCtx := TComboBox.Create(pnl);
      cboCtx.Parent := pnl;
      cboCtx.Left := 110; cboCtx.Top := 50;
      cboCtx.Width := 400;
      cboCtx.Style := csDropDownList;
      cboCtx.Items.Assign(ctx);
      cboCtx.ItemIndex := 0;
    end
    else
      pnl.Height := 60;
  finally
    ctx.Free;
  end;
  FTabs[idx].cboContexto := cboCtx;

  re := TRichEdit.Create(tab);
  re.Parent := tab;
  re.Align := alClient;
  re.ReadOnly := True;
  re.ScrollBars := ssBoth;
  re.WordWrap := False;
  re.Font.Name := 'Courier New';
  re.Font.Size := 10;
  FTabs[idx].reSalida := re;
end;

procedure TfrmPrincipal.Analizar(idx: Integer);
var
  ctx: Integer;
begin
  with FTabs[idx] do begin
    if Assigned(cboContexto) then
      ctx := cboContexto.ItemIndex
    else
      ctx := 0;
    // Respaldo del auto-espaciado de WM_PASTE: cubre texto que llego al
    // combo sin pasar por pegar (arrastrado, autocompletado, etc.)
    if Analizador.EsHexPuro then
      cboComando.Text := FormateaHexContinuo(cboComando.Text);
    Analizador.Analiza(cboComando.Text, ctx);
    Analizador.Render(reSalida);
    if (Trim(cboComando.Text) <> '') and
       (cboComando.Items.IndexOf(cboComando.Text) < 0) then
      cboComando.Items.Insert(0, cboComando.Text);
  end;
end;

procedure TfrmPrincipal.btnAnalizarClick(Sender: TObject);
begin
  Analizar((Sender as TComponent).Tag);
end;

procedure TfrmPrincipal.cboComandoKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then begin
    Key := #0;
    Analizar((Sender as TComponent).Tag);
  end;
end;

procedure TfrmPrincipal.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  // ============ REGISTRO DE MARCAS / PROTOCOLOS ============
  RegistraAnalizador(TAnalizadorWayneCns.Create);
  RegistraAnalizador(TAnalizadorBennett.Create);
  RegistraAnalizador(TAnalizadorTeam.Create);
  RegistraAnalizador(TAnalizadorPam.Create);
  RegistraAnalizador(TAnalizadorHongYang.Create);
  RegistraAnalizador(TAnalizadorGilbarco.Create);
  RegistraAnalizador(TAnalizadorWayne2W.Create);
  // =========================================================

  PageControl1.ActivePageIndex := 0;
  for i := 0 to High(FTabs) do
    Analizar(i);   // analisis inicial con el primer ejemplo de cada marca
end;

procedure TfrmPrincipal.FormDestroy(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FTabs) do
    FTabs[i].Analizador.Free;
end;

end.
