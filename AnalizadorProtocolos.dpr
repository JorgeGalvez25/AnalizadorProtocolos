program AnalizadorProtocolos;

uses
  Forms,
  UAnalizadorBase in 'UAnalizadorBase.pas',
  UProtoBennett in 'UProtoBennett.pas',
  UProtoWayne2W in 'UProtoWayne2W.pas',
  UPrincipal in 'UPrincipal.pas' {frmPrincipal};

{$R *.res}

begin
  Application.Initialize;
  Application.Title := 'Analizador de Protocolos I-Gas';
  Application.CreateForm(TfrmPrincipal, frmPrincipal);
  Application.Run;
end.
