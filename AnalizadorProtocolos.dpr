program AnalizadorProtocolos;

uses
  Forms,
  UAnalizadorBase in 'UAnalizadorBase.pas',
  UProtoBennett in 'UProtoBennett.pas',
  UProtoWayne2W in 'UProtoWayne2W.pas',
  UProtoPam in 'UProtoPam.pas',
  UProtoWayneCns in 'UProtoWayneCns.pas',
  UProtoGilbarco in 'UProtoGilbarco.pas',
  UPrincipal in 'UPrincipal.pas' {frmPrincipal},
  UProtoTeam in 'UProtoTeam.pas',
  UProtoHongYang in 'UProtoHongYang.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.Title := 'Analizador de Protocolos I-Gas';
  Application.CreateForm(TfrmPrincipal, frmPrincipal);
  Application.Run;
end.
