unit FormSimhConsoleU;
{
  MDI window showing the emulated PDP-11's own console (SimH's "console
  telnet" channel), used only by the "SimH direct" connection method - see
  SerialIoHubU.Physical_InitForSimhProcess. This is a plain byte
  pass-through: raw data in, raw keystrokes out. It has no relation to the
  sim> command/response protocol that SerialIoHubU/ConsolePDP11SimHU
  implement over a separate ("remote") channel - that protocol's parser
  was built and tested only against a clean administrative channel, so
  this window intentionally stays out of its way by owning its own,
  independent TTnCnx connection instead of going through TSerialIoHub.
  It is inert (no connection, keystrokes discarded) until ConnectTo() is
  called, which only happens for the "SimH direct" connection type.
}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, LCLType,
  FormChildU, OverbyteIcsTnCnx ;

type
  TFormSimhConsole = class(TFormChild)
      ConsoleMemo: TMemo;
      procedure FormCreate(Sender: TObject);
      procedure FormDestroy(Sender: TObject);
      procedure ConsoleMemoKeyPress(Sender: TObject; var Key: char);
      procedure ConsoleMemoKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    private
      ConsoleTelnet: TTnCnx ;
      fConnected: boolean ;
      procedure TnDataAvailable(Sender: TTnCnx; Buffer: Pointer; Len: integer) ;
      procedure TnDisplay(Sender: TTnCnx; Str: string) ;
      procedure TnSessionConnected(Sender: TTnCnx; Error: word) ;
      procedure AppendRaw(s: string) ;
    public
      // Connects (with retry, since the just-spawned SimH process needs a
      // moment to start listening) and starts showing/forwarding traffic.
      // Logs failure into the console memo rather than raising, so a
      // failed console channel doesn't take down an otherwise-successful
      // "SimH direct" connection.
      procedure ConnectTo(aHost: string ; aPort: integer ; aliveCheck: TTnCnxAliveCheck = nil) ;
      // Safe to call even when never connected.
      procedure Disconnect ;
    end{ "TYPE TFormSimhConsole = class(TFormChild)" } ;

var
  FormSimhConsole: TFormSimhConsole ;

implementation

{$R *.dfm}

const
  SIMH_CONSOLE_CONNECT_TIMEOUT_MS = 5000 ;

procedure TFormSimhConsole.FormCreate(Sender: TObject);
  begin
    ConsoleTelnet := TTnCnx.Create(nil) ;
    ConsoleTelnet.Name := 'SimhConsoleTnCnx' ;
    ConsoleTelnet.TermType := 'dumb' ;
    fConnected := false ;
  end;

procedure TFormSimhConsole.FormDestroy(Sender: TObject);
  begin
    ConsoleTelnet.Free ;
  end;

procedure TFormSimhConsole.ConnectTo(aHost: string ; aPort: integer ; aliveCheck: TTnCnxAliveCheck = nil) ;
  begin
    Disconnect ;
    ConsoleMemo.Clear ;
    ConsoleTelnet.OnDataAvailable := TnDataAvailable ;
    ConsoleTelnet.OnSessionConnected := TnSessionConnected ;
    ConsoleTelnet.OnDisplay := TnDisplay ;
    fConnected := TnCnxConnectWithRetry(ConsoleTelnet, aHost, aPort,
            SIMH_CONSOLE_CONNECT_TIMEOUT_MS, aliveCheck) ;
    if not fConnected then
      AppendRaw(Format('*** Could not connect to SimH console at %s:%d ***'#13#10,
              [aHost, aPort])) ;
  end{ "procedure TFormSimhConsole.ConnectTo" } ;

procedure TFormSimhConsole.Disconnect ;
  begin
    fConnected := false ;
    try
      ConsoleTelnet.Close ;
    except
      on E: Exception do ;
    end;
  end;

procedure TFormSimhConsole.TnDataAvailable(Sender: TTnCnx; Buffer: Pointer; Len: integer) ;
  var i: integer ;
    pCharBuffer: PAnsiChar ;
    s: string ;
  begin
    pCharBuffer := PAnsiChar(Buffer) ;
    s := '' ;
    for i := 0 to Len - 1 do
      s := s + pCharBuffer[i] ;
    AppendRaw(s) ;
  end;

procedure TFormSimhConsole.TnDisplay(Sender: TTnCnx; Str: string) ;
  begin
    AppendRaw(Str) ;
  end;

procedure TFormSimhConsole.TnSessionConnected(Sender: TTnCnx; Error: word) ;
  begin
    // nothing extra needed here - ConnectTo already reports failure via
    // its own return value.
  end;

// Dumb append - no CR/LF/backspace interpretation table, unlike
// FormTerminalU.AppendText: this window is a raw pass-through, not a
// terminal emulation.
procedure TFormSimhConsole.AppendRaw(s: string) ;
  begin
    ConsoleMemo.SelStart := MaxInt ;
    ConsoleMemo.SelText := s ;
    ConsoleMemo.SelStart := MaxInt ;
  end;

// Same "swallow control keys, only let KeyPress forward them" pattern as
// FormTerminalU.RichEdit1KeyDown - Delete produces no KeyPress char event
// in the LCL, so it must be translated and forwarded here instead.
procedure TFormSimhConsole.ConsoleMemoKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  begin
    if (Key = VK_DELETE) and fConnected then
      ConsoleTelnet.SendStr(#$7f) ;
    if (ssCtrl in Shift) and (Key in [ord('A') .. ord('Z')]) then
      Key := 0 ;
    Key := 0 ;
  end{ "procedure TFormSimhConsole.ConsoleMemoKeyDown" } ;

procedure TFormSimhConsole.ConsoleMemoKeyPress(Sender: TObject; var Key: char);
  begin
    if fConnected then
      ConsoleTelnet.SendStr(Key) ;
    Key := #0 ; // mark as processed: do not let the memo insert it locally
  end;

end{ "unit FormSimhConsoleU" } .
