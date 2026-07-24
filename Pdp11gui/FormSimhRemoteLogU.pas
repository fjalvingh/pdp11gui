unit FormSimhRemoteLogU;
{
  MDI window showing a live, timestamped transcript of everything sent to
  and recognized from SimH's *remote console* (the "sim>" admin-protocol
  channel ConsolePDP11SimHU.pas actually parses) - distinct from
  FormSimhConsoleU, which shows the emulated PDP-11's own terminal on the
  separate console-telnet port. Read-only, passive: it has no connection of
  its own, it is only ever fed via AppendLine() calls from
  ConsolePDP11SimHU.pas. Always capturing in the background (like the
  existing Log window), shown/hidden independently via the "Connection"
  menu, same pattern as FormSimhConsoleU/FormTerminal.
}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls,
  FormChildU ;

type
  TFormSimhRemoteLog = class(TFormChild)
      LogMemo: TMemo;
    public
      procedure AppendLine(s: string) ;
    end{ "TYPE TFormSimhRemoteLog = class(TFormChild)" } ;

var
  FormSimhRemoteLog: TFormSimhRemoteLog ;

implementation

{$R *.dfm}

const
  MAX_LOG_LINES = 2000 ; // keep this a live debugging aid, not an ever-growing memory/redraw cost

// Timestamped append. Unlike FormSimhConsoleU.AppendRaw's SelStart/SelText
// "scroll to end" pattern (fine for that window's much lower traffic),
// this hook fires on every single parsed phrase from the remote-console
// scanner - on a long session that's thousands of calls, and repeatedly
// re-selecting-then-inserting into an ever-growing TMemo gets visibly
// slower as it grows (confirmed live: multi-second stalls on the scanner's
// hot path after ~40 minutes of testing). Lines.Add is the standard,
// far cheaper way to append a line to a TMemo. Also cap total line count
// so a long-running session doesn't grow this unbounded either.
procedure TFormSimhRemoteLog.AppendLine(s: string) ;
  var ts: string ;
  begin
    DateTimeToString(ts, 'hh:nn:ss.zzz', Now) ;
    LogMemo.Lines.BeginUpdate ;
    try
      while LogMemo.Lines.Count >= MAX_LOG_LINES do
        LogMemo.Lines.Delete(0) ;
      LogMemo.Lines.Add('[' + ts + '] ' + s) ;
    finally
      LogMemo.Lines.EndUpdate ;
    end;
  end;

end{ "unit FormSimhRemoteLogU" } .
