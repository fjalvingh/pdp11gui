unit OverbyteIcsTnCnx;
{
  Linux/Lazarus port replacement for the "Overbyte ICS" (Internet Component
  Suite) TTnCnx Telnet client component, which is not available for Lazarus.

  This provides the small subset of the TTnCnx API that SerialIoHubU.pas
  actually uses (Create, Name, TermType, host, port, OnDataAvailable,
  OnSessionConnected, OnDisplay, Connect, Close, SendStr, Free), backed by a
  real (if minimal) Telnet client over FPC's cross-platform Sockets unit.

  Not a full RFC 854 implementation: it negotiates nothing itself, just
  refuses every option the peer proposes (IAC WILL -> IAC DONT, IAC DO ->
  IAC WONT), which keeps the session in plain NVT passthrough mode, and
  strips all IAC sequences out of what's delivered via OnDataAvailable.
  Verified against Open SimH's remote console ("SET REMOTE TELNET=<port>"
  plus "SET REMOTE MASTER"), which is the intended use case (see
  LINUX_PORT_TODO.md) - that's a plain character-mode session once its
  initial option offers are refused.

  Reads are non-blocking, polled from a TTimer - SerialIoHubU.Physical_
  ReadByte's connectionTelnet branch already calls Application.
  ProcessMessages before checking for buffered data, exactly to pump timers
  like this one (the same pattern as TSerialIoHub's own Physical_PollTimer).
}

interface

uses
  Classes, SysUtils, ExtCtrls, ctypes, Forms;

type
  TTnCnx = class;

  TTnCnxDataAvailable = procedure(Sender: TTnCnx; Buffer: Pointer; Len: integer) of object;
  TTnCnxSessionConnected = procedure(Sender: TTnCnx; Error: word) of object;
  TTnCnxDisplay = procedure(Sender: TTnCnx; Str: string) of object;

  TTelnetParseState = (tpsData, tpsIac, tpsCmd, tpsSub, tpsSubIac);

  TTnCnx = class(TComponent)
    private
      fTermType: string;
      fHost: string;
      fPort: string;
      fOnDataAvailable: TTnCnxDataAvailable;
      fOnSessionConnected: TTnCnxSessionConnected;
      fOnDisplay: TTnCnxDisplay;

      fSocket: cint;
      fConnected: boolean;
      fPollTimer: TTimer;
      fParseState: TTelnetParseState;
      fParseCmd: byte; // pending WILL/WONT/DO/DONT, waiting for its option byte

      procedure PollTimerTick(Sender: TObject);
      procedure ProcessIncoming(const raw: string);
      procedure SendIacReply(cmd, opt: byte);
    public
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
      procedure Connect;
      procedure Close;
      procedure SendStr(const s: string);
      property TermType: string read fTermType write fTermType;
      property host: string read fHost write fHost;
      property port: string read fPort write fPort;
      property OnDataAvailable: TTnCnxDataAvailable read fOnDataAvailable write fOnDataAvailable;
      property OnSessionConnected: TTnCnxSessionConnected read fOnSessionConnected write fOnSessionConnected;
      property OnDisplay: TTnCnxDisplay read fOnDisplay write fOnDisplay;
    end;

  // used by TnCnxConnectWithRetry to bail out early if a spawned process
  // (e.g. SimH) has already died, instead of waiting out the full timeout
  TTnCnxAliveCheck = function: boolean of object;

// (Re)points cnx at aHost:aPort and retries cnx.Connect until it succeeds,
// timeout_ms elapses, or aliveCheck (if given) reports the peer process is
// no longer alive. Pumps Application.ProcessMessages between attempts so
// timers (this unit's own fPollTimer, and any others) keep running. Used
// to wait for a just-spawned child process's listening socket to come up -
// an inherently racy startup, since Connect fails immediately if nothing
// is listening yet.
function TnCnxConnectWithRetry(cnx: TTnCnx; const aHost: string; aPort: integer;
        timeout_ms: dword; aliveCheck: TTnCnxAliveCheck = nil): boolean;

implementation

uses
  Sockets, NetDB, BaseUnix;

const
  TN_IAC  = 255;
  TN_DONT = 254;
  TN_DO   = 253;
  TN_WONT = 252;
  TN_WILL = 251;
  TN_SB   = 250;
  TN_SE   = 240;

constructor TTnCnx.Create(AOwner: TComponent);
  begin
    inherited Create(AOwner);
    fSocket := -1;
    fConnected := false;
    fParseState := tpsData;
    fPollTimer := TTimer.Create(nil);
    fPollTimer.Interval := 20;
    fPollTimer.Enabled := false;
    fPollTimer.OnTimer := PollTimerTick;
  end;

destructor TTnCnx.Destroy;
  begin
    Close;
    fPollTimer.Free;
    inherited Destroy;
  end;

procedure TTnCnx.Connect;
  var
    hostEntry: THostEntry;
    addr: TInetSockAddr;
    portNum: integer;
    flags: cint;
  begin
    Close;

    portNum := StrToIntDef(fPort, 0);
    if (portNum <= 0) or (portNum > 65535) then
      raise Exception.CreateFmt('TTnCnx.Connect: invalid port "%s"', [fPort]);

    if not ResolveHostByName(fHost, hostEntry) then
      raise Exception.CreateFmt('TTnCnx.Connect: could not resolve host "%s"', [fHost]);

    fSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
    if fSocket < 0 then
      raise Exception.Create('TTnCnx.Connect: could not create socket');

    FillChar(addr, SizeOf(addr), 0);
    addr.sin_family := AF_INET;
    addr.sin_port := htons(portNum);
    addr.sin_addr := hostEntry.Addr;

    if fpConnect(fSocket, @addr, SizeOf(addr)) <> 0 then begin
      CloseSocket(fSocket);
      fSocket := -1;
      raise Exception.CreateFmt('TTnCnx.Connect: could not connect to %s:%d', [fHost, portNum]);
    end;

    // switch to non-blocking: PollTimerTick drains it periodically
    flags := fpFcntl(fSocket, F_GETFL, 0);
    fpFcntl(fSocket, F_SETFL, flags or O_NONBLOCK);

    fParseState := tpsData;
    fConnected := true;
    fPollTimer.Enabled := true;

    if Assigned(fOnSessionConnected) then
      fOnSessionConnected(Self, 0);
  end;

procedure TTnCnx.Close;
  begin
    fPollTimer.Enabled := false;
    if fSocket >= 0 then begin
      CloseSocket(fSocket);
      fSocket := -1;
    end;
    fConnected := false;
  end;

// refuse every option offered: keeps the session in plain NVT passthrough mode
procedure TTnCnx.SendIacReply(cmd, opt: byte);
  var reply: array[0..2] of byte;
  begin
    if (fSocket < 0) or not ((cmd = TN_WILL) or (cmd = TN_DO)) then Exit;
    reply[0] := TN_IAC;
    if cmd = TN_WILL then reply[1] := TN_DONT else reply[1] := TN_WONT;
    reply[2] := opt;
    fpSend(fSocket, @reply[0], 3, 0);
  end;

// strips IAC negotiation/subnegotiation sequences out of raw, replies to
// option offers, and forwards the remaining plain data via OnDataAvailable
procedure TTnCnx.ProcessIncoming(const raw: string);
  var
    i: integer;
    b: byte;
    filtered: string;
  begin
    filtered := '';
    for i := 1 to length(raw) do begin
      b := byte(raw[i]);
      case fParseState of
        tpsData:
          if b = TN_IAC then fParseState := tpsIac
          else filtered := filtered + char(b);
        tpsIac:
          case b of
            TN_IAC: begin filtered := filtered + char(TN_IAC); fParseState := tpsData; end;
            TN_WILL, TN_WONT, TN_DO, TN_DONT: begin fParseCmd := b; fParseState := tpsCmd; end;
            TN_SB: fParseState := tpsSub;
            else fParseState := tpsData ; // other 2-byte commands (NOP, AYT, IP, ...): ignore
          end;
        tpsCmd: begin
          SendIacReply(fParseCmd, b);
          fParseState := tpsData;
        end;
        tpsSub:
          if b = TN_IAC then fParseState := tpsSubIac;
          // else: discard subnegotiation payload byte
        tpsSubIac:
          if b = TN_SE then fParseState := tpsData
          else fParseState := tpsSub;
      end{ "case fParseState" } ;
    end{ "for i" } ;

    if (filtered <> '') and Assigned(fOnDataAvailable) then
      fOnDataAvailable(Self, @filtered[1], length(filtered));
  end{ "procedure TTnCnx.ProcessIncoming" } ;

procedure TTnCnx.PollTimerTick(Sender: TObject);
  var
    buf: array[0..4095] of byte;
    n: cint;
    raw: string;
  begin
    if not fConnected then Exit;

    raw := '';
    repeat
      n := fpRecv(fSocket, @buf[0], SizeOf(buf), 0);
      if n > 0 then begin
        SetLength(raw, length(raw) + n);
        Move(buf[0], raw[length(raw) - n + 1], n);
      end;
    until n <= 0;

    if raw <> '' then
      ProcessIncoming(raw);

    if n = 0 then begin // orderly shutdown by peer
      Close;
      if Assigned(fOnDisplay) then
        fOnDisplay(Self, #13#10 + '*** Telnet connection closed by peer ***' + #13#10);
    end;
  end{ "procedure TTnCnx.PollTimerTick" } ;

procedure TTnCnx.SendStr(const s: string);
  var
    i: integer;
    escaped: string;
  begin
    if not fConnected then
      raise Exception.Create('TTnCnx.SendStr: not connected');
    escaped := '';
    for i := 1 to length(s) do begin
      escaped := escaped + s[i];
      if byte(s[i]) = TN_IAC then
        escaped := escaped + char(TN_IAC) ; // escape literal 0xFF data byte
    end;
    if escaped <> '' then
      fpSend(fSocket, @escaped[1], length(escaped), 0);
  end;

function TnCnxConnectWithRetry(cnx: TTnCnx; const aHost: string; aPort: integer;
        timeout_ms: dword; aliveCheck: TTnCnxAliveCheck = nil): boolean;
  var starttime: dword;
  begin
    cnx.host := aHost;
    cnx.port := IntToStr(aPort);
    starttime := GetTickCount64;
    result := false;
    repeat
      try
        cnx.Connect;
        result := true;
      except
        on E: Exception do begin
          Application.ProcessMessages;
          Sleep(100);
        end;
      end;
    until result
       or (GetTickCount64 - starttime > timeout_ms)
       or (Assigned(aliveCheck) and not aliveCheck());
  end{ "function TnCnxConnectWithRetry" };

end.
