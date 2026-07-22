unit OverbyteIcsTnCnx;
{
  Linux/Lazarus port stopgap.

  The original code used the "Overbyte ICS" (Internet Component Suite)
  third-party Telnet client component (TTnCnx), which is not installed in
  this Lazarus setup. This unit provides a minimal drop-in replacement
  that satisfies the small subset of the TTnCnx API that SerialIoHubU.pas
  actually uses (Create, Name, TermType, host, port, OnDataAvailable,
  OnSessionConnected, OnDisplay, Connect, Close, SendStr, Free), so the
  project compiles.

  It does NOT implement real Telnet networking yet - Connect() raises an
  exception. See LINUX_PORT_TODO.md ("Telnet connectivity (SimH) not yet
  ported") for what a real implementation needs.
}

interface

uses
  Classes, SysUtils;

type
  TTnCnx = class;

  TTnCnxDataAvailable = procedure(Sender: TTnCnx; Buffer: Pointer; Len: integer) of object;
  TTnCnxSessionConnected = procedure(Sender: TTnCnx; Error: word) of object;
  TTnCnxDisplay = procedure(Sender: TTnCnx; Str: string) of object;

  TTnCnx = class(TComponent)
    private
      fTermType: string;
      fHost: string;
      fPort: string;
      fOnDataAvailable: TTnCnxDataAvailable;
      fOnSessionConnected: TTnCnxSessionConnected;
      fOnDisplay: TTnCnxDisplay;
    public
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

implementation

procedure TTnCnx.Connect;
  begin
    raise Exception.Create('Telnet connectivity is not yet ported to Linux/Lazarus (see LINUX_PORT_TODO.md); use a serial/COM connection instead.');
  end;

procedure TTnCnx.Close;
  begin
    // nothing to do: Connect() never succeeds, so there is never a live session to close
  end;

procedure TTnCnx.SendStr(const s: string);
  begin
    raise Exception.Create('Telnet connectivity is not yet ported to Linux/Lazarus (see LINUX_PORT_TODO.md).');
  end;

end.
