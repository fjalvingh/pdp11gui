unit ConsolePDP11SimHU;
{
   Copyright (c) 2016, Joerg Hoppe
   j_hoppe@t-online.de, www.retrocmp.com

   Permission is hereby granted, free of charge, to any person obtaining a
   copy of this software and associated documentation files (the "Software"),
   to deal in the Software without restriction, including without limitation
   the rights to use, copy, modify, merge, publish, distribute, sublicense,
   and/or sell copies of the Software, and to permit persons to whom the
   Software is furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
   JOERG HOPPE BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
}

{
  Steuert über Telnet den Emulatir SimH an
  Die Anwendung ruft nur Deposit(), Examine()

    Der Zugriff auf die CPU-R0..R7 wird in die besonderen Examines
   "E R0..R7" umgesetzt. Deposit genauso.
   SimH sagt sonst "illegal address space", es mapt die Register
   NICHt in den Adressraum

   SimH hat immer 22 Bit physical addresses, auch wenn er kleine PDP-11 emuliert!

}


interface

uses
  Classes, SysUtils,
  ExtCtrls,
  ConsoleGenericU,
  FormSettingsU,
  FormTerminalU,
  SerialIoHubU,
  AddressU,
  MemoryCellU,
  Pdp11MmuU,
  FormBusyU
  ;


const
  CHAR_SIMH_CR = #$d ;
  CHAR_SIMH_LF = #$a ;
  CHAR_SIMH_HALT = #5 ; // ^E
  // A bulk deposit/examine issues one command per memory cell and waits
  // for its own reply before sending the next - hundreds of round trips
  // for a loaded program. 1000ms was fine for a single interactive
  // command; give repeated ones more headroom against a slow individual
  // reply before this pops the "No console prompt" dialog.
  //
  // Confirmed cause of one specific case: WaitForAnswer() depends on
  // Application.ProcessMessages to service the network poll timer, so it
  // competes with any other pending UI work. The very first Deposit click
  // on a freshly opened Macro11 Listing window lands right after that
  // window's one-time (and, per FormMacro11ListingU's own comment, known
  // to be slow/quirky) editor layout and syntax-highlight pass for the
  // just-loaded source - that backlog was enough to starve the poll timer
  // past 3000ms. Later clicks on the same window, with nothing left to
  // render, don't hit this. 3000ms wasn't quite enough margin; give it more.
  SIMH_CMD_TIMEOUT = 8000 ; // telnet verbindung ist lahm: warte lange!
  // HaltCpu() waits for this after sending ^E - but doHalt() (FormExecuteU)
  // calls HaltCpu() unconditionally, even when the CPU is already stopped
  // (its own comment calls this "improvising"), in which case ^E gets no
  // reply at all, ever. Waiting the full SIMH_CMD_TIMEOUT for that common,
  // expected case would freeze the UI for 8s before the "already halted"
  // message below even appears - keep this one short.
  SIMH_HALT_TIMEOUT = 1000 ;
  SIMH_PROMPT = 'sim> ' ;

type

  // Scanner, umn den Output der PDP zu analysieren
  // macht noch nix, nur CurInputLine wird von eigener Chaos-Logik hier benutzt
  TConsoleSimHScanner = class(TConsoleScanner)
    public
      constructor Create ; override;
      function NxtSym(raiseIncompleteOnEof: boolean = true): string ; override ;
    end;

  // Explicit CPU run-state, derived only from confirmed events seen on the
  // remote console (see the transition rules in DecodeNextAnswerPhrase) -
  // not assumed from whatever a button click was supposed to cause. Local
  // to this unit: SimH is the only console type where the remote protocol
  // itself can tell us this.
  TSimhCpuState = (scsUnknown, scsHalted, scsRunning) ;

  TConsolePDP11SimH = class(TConsoleGeneric)
    private

      examine_lastaddr: TMemoryAddress ; //
      deposit_lastaddr: TMemoryAddress ; //

      CpuState: TSimhCpuState ;
      // Set by DecodeNextAnswerPhrase when it confirms the CPU stopped
      // without an explicit halt message (see the comment there).
      // Consumed and cleared by SilentHaltTimerTimer.
      SilentHaltPending: boolean ;
      // Resolves SilentHaltPending asynchronously, entirely outside of
      // whatever command triggered the run (ResetMachineAndStartCpu is
      // fire-and-forget and must stay that way - blocking it on a
      // synchronous wait here previously froze the UI for however long
      // confirmation took, sometimes several seconds). Own timer, not a
      // hook into the base class's private, non-virtual MonitorTimer.
      SilentHaltTimer: TTimer ;
      procedure SilentHaltTimerTimer(Sender: TObject) ;

      // Like CheckPrompt(), but also detects commands SimH's remote console
      // silently rejects (see comment on the implementation below).
      procedure CheckPromptNoOutput(errinfo, sentcmd: string) ;

    public
      constructor Create(memorycellgroups: TMemoryCellGroups) ;// die MMU legt eigene mmeorycells an
      destructor Destroy ; override ;

      procedure Init(aConnection: TSerialIoHub) ; override ;

      procedure ClearState ; override ;
      procedure Resync ; override ;

      function getName: string ; override ;
      function getTerminalSettings: TTerminalSettings ; override ;

      function getFeatures: TConsoleFeatureSet ; override ;
      function getPhysicalMemoryAddressType: TMemoryAddressType ; override ;

      procedure Deposit(addr: TMemoryAddress ; val: dword) ; overload ; override ;
      function Examine(addr: TMemoryAddress): dword ; overload ;override ;
      procedure Examine(mcg: TMemoryCellGroup ; unknown_only: boolean; abortable:boolean) ;overload ;override ;

      // Not "override" - the base TConsoleGeneric.WriteToPDP is a plain
      // (non-virtual) method. This same-named declaration hides it for all
      // of THIS class's own (always unqualified) calls to WriteToPDP(...),
      // logging to Connection.SimhRemoteLog (if assigned) before calling
      // "inherited" to actually send. No other console type declares this,
      // so nothing else is affected.
      procedure WriteToPDP(buff: string) ;

      function DecodeNextAnswerPhrase: boolean ; override ;
      procedure ResetMachine(newpc_v: TMemoryAddress) ; override ; // Maschine reset
      procedure ResetMachineAndStartCpu(newpc_v: TMemoryAddress) ; override ; // CPU starten.
//      function IsRunning: boolean ; virtual ; abstract ; // läuft die CPU (noch?)
      procedure ContinueCpu ;  override ; // CPU anhalten
      procedure HaltCpu(var newpc_v: TMemoryAddress) ;  override ; // CPU anhalten
      procedure SingleStep ;  override ; // einen Zyklus ausführen


    end{ "TYPE TConsolePDP11SimH = class(TConsoleGeneric)" } ;


implementation


uses
  Forms,
  JH_Utilities,
  OctalConst,
  AuxU,
  FormMainU ;


constructor TConsoleSimHScanner.Create ;
  begin
    inherited ;
  end;

function TConsoleSimHScanner.NxtSym(raiseIncompleteOnEof: boolean = true): string ;
  begin
    raise Exception.Create('not implemented') ;
    result := '' ;
  end;




// ermittelt den symbolischen SimH-Registernamen zu einer 22bit-UNIBUS-Adresse
// '', wenn keiner gefunden
// Problem: die CPU-Register addressiert SimH nicht über UNIBUS-Adressen!

// diese Liste hier ist Model-abhängig .. eigentlich sollte sie aus
// der .ini-Datei mit geladen werden!
//function addr2regname(physicaladdrval:dword): string ;
function addr2regname(addr: TMemoryAddress; use_tmpval: boolean = false): string ;
  var val: dword ;
  begin
    if use_tmpval then
      val := addr.tmpval
    else val := addr.val ;
    result := '' ;
    case addr.mat of
      matPhysical22:
        case val of
          _17777700: result := 'R0' ; // 17777700
          _17777701: result := 'R1' ;
          _17777702: result := 'R2' ;
          _17777703: result := 'R3' ;
          _17777704: result := 'R4' ;
          _17777705: result := 'R5' ;
          _17777706: result := 'SP' ;
          _17777707: result := 'PC' ;

          _17777710.._17777717: result := '?' ; // marker: das nicht abfragen, ist SimH unbekannt!


          _17777766: result := 'CPUERR' ;
          _17777772: result := 'PIRQ' ;
          _17777776: result := 'PSW' ;
//        $7fffc0 + 6: result := 'KSP' ; // kernel stack pointer
//        $7fffc0 + 6: result := 'SSP' ; // supervisor stack pointer
//        $7fffc0 + 6: result := 'USP' ; // user stack pointer
        end { "case val" } ;
      matVirtual: ;
      matSpecialRegister:
        case val of
          // auf 'e -d dr' wird mit 'DR: xxxx' geantwortet
          MEMORYCELL_SPECIALADDR_DISPLAYREG:
            result := 'DR' ;
          MEMORYCELL_SPECIALADDR_SWITCHREG:
            result := 'SR' ;
        end ;
    end{ "case addr.mat" } ;
  end{ "function addr2regname" } ;


function regname2addr(regname:string): TMemoryAddress ;
  begin
    result.mat := matPhysical22 ;
    result.val := MEMORYCELL_ILLEGALVAL ;
    if regname = 'R0' then result.val := _17777700 ;
    if regname = 'R1' then result.val := _17777701 ;
    if regname = 'R2' then result.val := _17777702 ;
    if regname = 'R3' then result.val := _17777703 ;
    if regname = 'R4' then result.val := _17777704 ;
    if regname = 'R5' then result.val := _17777705 ;
    if regname = 'SP' then result.val := _17777706 ;
    if regname = 'PC' then result.val := _17777707 ;

    if regname = 'CPUERR' then result.val := _17777766 ;
    if regname = 'PIRQ' then result.val := _17777772 ;
    if regname = 'PSW' then result.val := _17777776 ;

    if regname = 'DR' then begin
      result.mat := matVirtual ;
      result.val := MEMORYCELL_SPECIALADDR_DISPLAYREG ;
    end;
    if regname = 'SR' then begin
      result.mat := matVirtual ;
      result.val := MEMORYCELL_SPECIALADDR_SWITCHREG ;
    end;

  end{ "function regname2addr" } ;



function SimhCpuStateName(s: TSimhCpuState): string ;
  begin
    case s of
      scsUnknown: result := 'Unknown' ;
      scsHalted: result := 'Halted' ;
      scsRunning: result := 'Running' ;
    end;
  end;

constructor TConsolePDP11SimH.Create(memorycellgroups: TMemoryCellGroups) ;
  begin
    inherited Create ;
    CommandTimeoutMillis := SIMH_CMD_TIMEOUT ;
    MMU := TPdp11MMu.Create(memorycellgroups) ;
    RcvScanner := TConsoleSimHScanner.Create ;
    CpuState := scsUnknown ;
    SilentHaltPending := false ;
    SilentHaltTimer := TTimer.Create(nil) ;
    SilentHaltTimer.Interval := 200 ;
    SilentHaltTimer.OnTimer := SilentHaltTimerTimer ;
    SilentHaltTimer.Enabled := true ;
  end;

destructor TConsolePDP11SimH.Destroy ;
  begin
    SilentHaltTimer.Free ;
    RcvScanner.Free ;
    inherited ;
  end;

// Runs independently of whatever triggered the run - see the comment on
// SilentHaltTimer. Skips while some other console operation is already
// mid-flight (same guard MonitorTimerCallback uses), so it never competes
// with, eg. an in-progress Deposit/Examine/HaltCpu.
procedure TConsolePDP11SimH.SilentHaltTimerTimer(Sender: TObject) ;
  var pcaddr: TMemoryAddress ;
  begin
    if not SilentHaltPending then Exit ;
    if InCriticalSection then Exit ;
    try
      BeginCriticalSection ;
      if not SilentHaltPending then Exit ; // re-check now that we hold the section
      SilentHaltPending := false ;
      Log('SilentHaltTimerTimer: CPU halted with no explicit stop message (eg. no program loaded) - resolving PC') ;
      pcaddr.mat := matPhysical22 ;
      pcaddr.val := _17777707 ;
      onExecutionStopPcVal.mat := matVirtual ;
      onExecutionStopPcVal.val := Examine(pcaddr) ;
      onExecutionStopDetected := true ;
    finally
      EndCriticalSection ;
    end;
  end{ "procedure TConsolePDP11SimH.SilentHaltTimerTimer" } ;


function TConsolePDP11SimH.getName: string ;
  begin
    result := 'SimH PDP-11 console' ;
  end;

// Terminal-Einstellungen für SimH
function TConsolePDP11SimH.getTerminalSettings: TTerminalSettings ;
  begin
//    result.Receive_CRisCRLF := false ; // Unser "Enter" gibt CR
//    result.Receive_LFisCRLF := false ; // Ausgabe bricht Zeilen mit LF um
    result.Receive_CRisNewline := true ; // Unser "Enter" gibt CR
    result.Receive_LFisNewline := true ; // Telnet bricht Zeilen mit LF um
    result.Backspace := #8 ; //
    result.TabStop := 8 ;
  end;

function TConsolePDP11SimH.getFeatures: TConsoleFeatureSet ;
  begin
    result := [
            cfNonFatalHalt,
            cfNonFatalUNIBUStimeout,
            cfActionResetMachine, // reset unabhängig von run: RESET ALL
            cfActionResetMaschineAndStartCpu, // weiterlaufen mit Init: RUN.
            cfActionContinueCpu, // weiterlaufen ohne Init: GO bzw C
            cfActionHaltCpu, // Console kann Program stoppen
            cfActionSingleStep
            // cfMicroStep
            ] ;
    // kein cfFlagResetCpuSetsPC: "Reset" setzt den PC NICHT!
  end{ "function TConsolePDP11SimH.getFeatures" } ;


function TConsolePDP11SimH.getPhysicalMemoryAddressType: TMemoryAddressType ;
  begin
    // SimH hat immer 22 Bit physical addresses, auch wenn er kleine PDP-11 emuliert!
    result := matPhysical22 ;
  end;


// Logs to the optional "SimH Remote Console Log" window (see comment on
// the interface declaration), then sends exactly as the base class would.
procedure TConsolePDP11SimH.WriteToPDP(buff: string) ;
  begin
    if Connection.SimhRemoteLog <> nil then
      Connection.SimhRemoteLog.AppendLine('> ' + String2PrintableText(buff, true)) ;
    inherited WriteToPDP(buff) ;
  end;


// Aus SerialRcvDataBuffer die Antworten extrahieren
// und in die Colection AnswerLines schreiben
// erkennt im output von SimH die nächste Antwort phrase
// wird vom "onRcv"-Even aufgerufen - letztlich von SerialIoHub-PollTimer
function TConsolePDP11SimH.DecodeNextAnswerPhrase: boolean ;
  var
    curline, leadingtext: string ;
    i: integer ;
    eoln, promptfound: boolean ;
    s: string ;
    haltanswerline, curanswerline: TConsoleAnswerPhrase ;
  begin
    result := false ;

    // arbeite auf SerialRcDataBuffer
    // verarbeiter Pufferstart bis EOLN.
    i := 1 ;

    // leading EOLN  weg
    while (i <= length(RcvScanner.CurInputLine)) and CharInSet(RcvScanner.CurInputLine[i], [CHAR_SIMH_CR, CHAR_SIMH_LF])  do begin
      inc(i) ;
    end;
    RcvScanner.CurInputLine := Copy(RcvScanner.CurInputLine, i, maxint) ;

    // Scanne bis Zeilenende oder Prompt. SimH sometimes sends text with no
    // trailing CRLF before the next "sim> " (eg. "Simulator Running..." -
    // see _sim_rem_message()/scp.c), so the prompt can arrive glued onto
    // the end of an otherwise-unterminated line instead of starting one.
    // Stop as soon as curline ENDS WITH the prompt (not just equals it),
    // so that glued-on case is still recognized instead of being scanned
    // past forever (the loop would otherwise never see a CR/LF to stop on).
    i := 1 ;
    curline := '' ;
    promptfound := false ;
    while (i <= length(RcvScanner.CurInputLine))
            and not promptfound
            and not CharInSet(RcvScanner.CurInputLine[i],[CHAR_SIMH_CR, CHAR_SIMH_LF])  do begin
      curline := curline + RcvScanner.CurInputLine[i] ;
      inc(i) ;
      promptfound := (length(curline) >= length(SIMH_PROMPT))
              and (Copy(curline, length(curline)-length(SIMH_PROMPT)+1, length(SIMH_PROMPT)) = SIMH_PROMPT) ;
    end ;
    eoln := (i <= length(RcvScanner.CurInputLine)) and CharInSet(RcvScanner.CurInputLine[i], [CHAR_SIMH_CR, CHAR_SIMH_LF]) ; // vorzeitiger Stop, weil eoln getroffen


    curanswerline := nil ;
    // in curline steht jetzt die erste unverarbeitete Ausgabezeile von SimH
    if promptfound and (curline <> SIMH_PROMPT) then begin
      // Prompt glued onto preceding text with no CRLF between them - split
      // off the leading text as its own otherline phrase now, and leave
      // the prompt itself in CurInputLine so the next call sees it as a
      // clean, standalone "curline = SIMH_PROMPT" match below.
      leadingtext := Copy(curline, 1, length(curline) - length(SIMH_PROMPT)) ;
      curanswerline := Answerlines.Add as TConsoleAnswerPhrase ;
      curanswerline.phrasetype := phOtherLine ;
      curanswerline.rawtext := leadingtext ;
      curanswerline.otherline := leadingtext ;
      curline := leadingtext ; // so only the leading part gets consumed below
    end else
    if curline = SIMH_PROMPT then begin
      // merke die Zeile vor der Prompt
      if Answerlines.Count > 0 then
        haltanswerline := Answerlines.Items[Answerlines.Count-1] as  TConsoleAnswerPhrase
      else haltanswerline := nil ;

      curanswerline := Answerlines.Add as TConsoleAnswerPhrase ;
      curanswerline.phrasetype := phPrompt ;
      curanswerline.rawtext := curline ;

      // Hier nicht as OnHalt event auslösen ... das will wahrscheinlich
      //Funktionen durchführen, (EXAMINE list), die wiederum vom background-empfang abhängig sind!
      // war die Phrase davor ein "phHalt", wird jetzt das OnHalt-Event ausgelöst
      if (haltanswerline <> nil) and (haltanswerline.phrasetype = phHalt) then begin
        onExecutionStopPcVal := haltanswerline.haltaddr ;
        onExecutionStopDetected := true ;
        // MonitorTimer kann jetzt OnExecutionStop auslösen
      end else begin
        onExecutionStopPcVal.val := MEMORYCELL_ILLEGALVAL ;
        onExecutionStopDetected := false ;
        // No explicit halt message preceded this prompt. If we were
        // confirmed Running right up until now, this prompt is the ONLY
        // sign we'll ever get that the CPU silently stopped (eg. it
        // started on effectively empty/zeroed memory, executed the
        // implicit HALT at address 0, and nothing else). Flag it for
        // ResetMachineAndStartCpu to resolve the real PC and notify the
        // UI - but only based on this confirmed event, never by guessing
        // from a timeout (a genuinely still-running program never sends a
        // prompt at all, so this flag simply never gets set for it -
        // sending anything ourselves to check would incorrectly interrupt
        // it, which is exactly the bug this replaces).
        if CpuState = scsRunning then
          SilentHaltPending := true ;
      end;
    end { "if curline = SIMH_PROMPT" } ;

    if (curanswerline = nil) and eoln then begin
      // Analyse der letzten vollständigen Zeile
      if (pos('SIMULATION STOPPED', Uppercase(curline)) > 0)
              or (pos('HALT', Uppercase(curline)) > 0)
              or (pos('STEP EXPIRED', Uppercase(curline)) > 0)
              or (pos('TRAP', Uppercase(curline)) > 0)
              or (pos('BREAKPOINT', Uppercase(curline)) > 0)
        then begin

          // erkenne, ob es ein CPU-stop ist
          //   Simulation stopped, PC: 002502 (MOV (SP)+,177776)
          // oder
          //  HALT instruction, PC: 000114 (SWAB (R0)+)
          // oder
          //  Step expired, PC: 000006 (SWAB -(R0))
          // Es gibt den virtuellen PC aus

          i := pos('PC:', curline) ;
          if i > 0 then begin // else: unknown error!
            s := Trim(Copy(curline, i+3, 7)) ;
            curanswerline := Answerlines.Add as TConsoleAnswerPhrase ;
            curanswerline.phrasetype := phHalt ;
            curanswerline.rawtext := curline ;
            curanswerline.haltaddr := OctalStr2Addr(s, matVirtual) ;
            // halt -phrase löst noch nicht das OnExecutionStop-Event aus.
            // erst, wenn die cmd prompt erkannt wird
          end ;
        end{ "if (pos('SIMULATION STOPPED', Uppercase(curline)) > 0) or (pos('HALT', Upperc..." } ;
      if (curanswerline = nil) and eoln then begin
        // examineanswer: Form "addr: value", addr auch PC, RO, ...
        curanswerline := Answerlines.Add as TConsoleAnswerPhrase ;
        curanswerline.phrasetype := phExamine ;
        curanswerline.rawtext := curline ;
        try // bei Formatfehler: curanswerline wieder löschen und := nil
          i := pos('Address space exceeded', curline) ;
          if i > 0 then begin
            // UNIBUS timeout ist gültige Antwort
            curanswerline.examineaddr.mat := matPhysical22 ;
            curanswerline.examineaddr.val := MEMORYCELL_ILLEGALVAL ;  // adresse ist leider unbekannt
            curanswerline.examinevalue := MEMORYCELL_ILLEGALVAL ; // gültiges Fehlersignal
          end else begin

            // es kommt <addr>:  <val> zurück
            s := ExtractWord(1, curline, [' ', #9]) ; // val extrahieren
            if (s = '') or (s[length(s)] <> ':') then raise EConsoleScannerUnknownExpression.Create('no examine answer') ; //no error

            s := Copy(s, 1, length(s)-1) ;
            curanswerline.examineaddr := regname2addr(s) ;
            // ist es registername oder oktal?
            if curanswerline.examineaddr.val = MEMORYCELL_ILLEGALVAL then
              curanswerline.examineaddr := OctalStr2Addr(s, matPhysical22) ; // exception
            if curanswerline.examineaddr.val = MEMORYCELL_ILLEGALVAL then
              raise EConsoleScannerUnknownExpression.Create('no examine answer') ; //no error

            s := ExtractWord(2, curline, [' ', #9]) ; // val extrahieren
            curanswerline.examinevalue := OctalStr2Dword(s, 16) ; // exception?
            if curanswerline.examinevalue = MEMORYCELL_ILLEGALVAL then raise EConsoleScannerUnknownExpression.Create('no examine answer') ; //no error

            s := ExtractWord(3, curline, [' ', #9]) ; // val extrahieren
            if s <> '' then raise EConsoleScannerUnknownExpression.Create('no examine answer') ; //no error
          end { "if i > 0 ... ELSE" } ;
        except
          curanswerline.Free ;
          curanswerline := nil ; // probiere nächsten Typ
        end{ "try" } ;
      end { "if (curanswerline = nil) and eoln" } ;

      if (curanswerline = nil) and eoln then begin
        curanswerline := Answerlines.Add as TConsoleAnswerPhrase ;
        curanswerline.phrasetype := phOtherLine ;
        curanswerline.rawtext := curline ;
        curanswerline.otherline := curline ;
      end;
    end{ "if (curanswerline = nil) and eoln" } ;

    if curanswerline <> nil then begin
      // CPU run-state tracking (TSimhCpuState) - updated right here so it
      // stays correct continuously, not just right after a command was
      // sent: a running program can also stop on its own (HALT instruction,
      // breakpoint, UNIBUS timeout) at any later time, and this scanner
      // keeps running via the background poll regardless of which method
      // call (if any) is currently waiting on something.
      case curanswerline.phrasetype of
        phHalt: CpuState := scsHalted ;
        phPrompt: CpuState := scsHalted ; // a prompt is only ever sent when SimH isn't actively running
        phOtherLine: if curanswerline.otherline = 'Simulator Running...' then CpuState := scsRunning ;
      end ;
      if Connection.SimhRemoteLog <> nil then
        Connection.SimhRemoteLog.AppendLine('< ' + String2PrintableText(curanswerline.rawtext, true)) ;
      //curline ist verarbeitet, entferne es aus SerialRcvDataBuffer
      RcvScanner.CurInputLine := Copy(RcvScanner.CurInputLine, length(curline)+1, maxint) ;
      Log(curanswerline.AsText) ;
    end ; //else Log('invalid curAnswerPhrase, SerialRcvDataBuffer="%s"', [SerialRcvDataBuffer]) ;

    // true, wenn phrase erkannt
    result := curanswerline <> nil ;

  end{ "function TConsolePDP11SimH.DecodeNextAnswerPhrase" } ;



procedure TConsolePDP11SimH.Resync ;
  begin
    try
      BeginCriticalSection ; // User sperren

      examine_lastaddr.val := MEMORYCELL_ILLEGALVAL ; // ungültig, da 32 bit
      deposit_lastaddr.val := MEMORYCELL_ILLEGALVAL ;
      CpuState := scsUnknown ; // wir wissen nach einem (Re-)Connect nichts über den Laufzustand
      SilentHaltPending := false ;

      // Irgendwas eingeben, es muss die Prompt "sim>" kommen.
      // Ein einzelnes "RETURN" wiederholt das letzte Kommando ...
      // unvorhersehbare Folgen!
      RcvScanner.Clear ; // unverarbeiteter Input weg
      Answerlines.Clear ; // erkannter Input weg

      // nur NACH diesem Befehel kann mit EXAMINE auf den iospace zugegriffen
      // werden ????
      WriteToPDP('sh cpu iospace'+ CHAR_SIMH_CR) ;
      CheckPrompt('Could not wake up SimH');

      // receive polling schnell stellen, versuche, 38400 baud zu erreichen

      // poll-arg = simulated PDP-11 instruction between polls
      // execution speed is almost unknown ...
      // if executing at 5 MHZ, baudrate =38400
      // char rate = 3840 , timing = 5000000/3840 = 1300

      WriteToPDP('set throttle 5M'+ CHAR_SIMH_CR) ; // 5MIPS
      CheckPrompt('"set throttle" failed');
      WriteToPDP('deposit tti time 1300'+ CHAR_SIMH_CR) ;
      CheckPrompt('"deposit tti time" failed');

      // die letzten 100 Befehle speichern
      WriteToPDP('SET CPU HISTORY=100'+ CHAR_SIMH_CR) ;
      CheckPrompt('"deposit tti time" failed');

      // Quatsch eingeben, damit ein einzelnes Return nix wiederholt.
//      WriteToPDP('Hello, SimH!'+ CHAR_SIMH_CR) ;
//      CheckPrompt('Could not wake up SimH');
      Log('SimH ready and prompting "sim>"') ;
    finally
      OutputDebugString('Resync ends') ;
      EndCriticalSection ;
    end { "try" } ;
  end { "procedure TConsolePDP11SimH.Resync" } ;

// Telnet initialisieren
// return hauen und sicher stellen, dass Antwort da ist.

procedure TConsolePDP11SimH.Init(aConnection: TSerialIoHub) ;
  var i: integer ;
  begin
    try
      BeginCriticalSection ; // User sperren
      inherited Init(aConnection) ;
      // 1. Sek warten, die Startausgabe weg lesen!
      for i := 1 to 100 do begin
        Application.ProcessMessages ;  // Background Empfang
        sleep(10) ;
//aConnection.Physical_Poll(nil);
      end;

      Resync ;
    finally
      OutputDebugString('Init ends') ;
      EndCriticalSection ;
    end { "try" } ;
  end{ "procedure TConsolePDP11SimH.Init" } ;



// SimH's remote console only accepts a fixed whitelist of commands
// (see "allowed_remote_cmds"/"allowed_master_remote_cmds" in SimH's
// sim_console.c). A rejected command (eg. the DO-script batching this unit
// used to send) still returns to the "sim>" prompt, so plain CheckPrompt()
// does not notice the failure - it only sees the error text SimH sends
// back as an unrecognized extra line. DEPOSIT and RESET produce no output
// at all on success, so any such line here means the command was rejected.
//
// SimH's remote console also echoes every command it receives back over
// the same telnet line character-by-character before acting on it (plain
// terminal echo), so the line we just sent (sentcmd) always shows up as
// its own phOtherLine too - that echo must be excluded, or every command
// (including ones SimH accepts) would look "rejected".
procedure TConsolePDP11SimH.CheckPromptNoOutput(errinfo, sentcmd: string) ;
  var
    i: integer ;
    answerline: TConsoleAnswerPhrase ;
    errtext, echoedcmd: string ;
  begin
    CheckPrompt(errinfo) ;
    echoedcmd := Trim(sentcmd) ;
    errtext := '' ;
    for i := 0 to Answerlines.Count - 1 do begin
      answerline := Answerlines.Items[i] as TConsoleAnswerPhrase ;
      if (answerline.phrasetype = phOtherLine)
              and (Trim(answerline.otherline) <> echoedcmd) then
        errtext := errtext + answerline.otherline + ' ' ;
    end;
    errtext := Trim(errtext) ;
    if errtext <> '' then
      raise Exception.CreateFmt('%s: SimH rejected the command: "%s"', [errinfo, errtext]) ;
  end{ "procedure TConsolePDP11SimH.CheckPromptNoOutput" } ;


procedure TConsolePDP11SimH.Deposit(addr: TMemoryAddress ; val: dword) ;
  var s, regname: string ;
  begin
    // VB: console ist bereit
    try
      BeginCriticalSection ; // User sperren

      regname := '' ;
      if addr.mat = matSpecialRegister then begin
        regname := addr2regname(addr) ;
      end else begin
        // addr kann auch Virtual sein! SimH kann das! bis auf weiters aber
        // nicht benutzen, bis verhalten klar!
        assert(MMU.getPhysicalAddressType = matPhysical22) ;
        if addr.mat = matVirtual then
          addr := MMU.Virtual2PhysicalData(addr) ;
        assert(addr.mat = matPhysical22) ;
        assert(addr.val <> MEMORYCELL_ILLEGALVAL) ;

        regname := addr2regname(addr) ;
      end;
      if regname <> '' then begin // es ist ein CPU-Register
        s := Format('D %s %s'+CHAR_SIMH_CR, [regname, Dword2OctalStr(val)]) ;
        deposit_lastaddr.val := MEMORYCELL_ILLEGALVAL ;
      end else begin
        s := Format('D %s %s'+CHAR_SIMH_CR, [Dword2OctalStr(addr.val), Dword2OctalStr(val)]) ;
        deposit_lastaddr := addr ;
      end;

      // SimH refuses to deposit into a live PC while the CPU is actually
      // running (confirmed: it replies "Invalid argument") - CpuState lets
      // that be reported clearly and immediately instead of round-tripping
      // to SimH just to find out.
      if (regname = 'PC') and (CpuState = scsRunning) then
        raise Exception.Create('DEPOSIT failed: cannot set PC while the CPU is running') ;

      Answerlines.Clear ;
      WriteToPDP(s) ;
      CheckPromptNoOutput('DEPOSIT failed, no prompt', s) ;
    finally
      OutputDebugString('Deposit ends') ;
      EndCriticalSection ;
    end { "try" } ;
  end{ "procedure TConsolePDP11SimH.Deposit" } ;


// alle edit_values setzen
function TConsolePDP11SimH.Examine(addr: TMemoryAddress): dword ;
  var s, regname: string ;
    answerline: TConsoleAnswerPhrase ;
  begin
    // VB: console ist bereit
    try
      BeginCriticalSection ; // User sperren

      regname := '' ;

      if addr.mat = matSpecialRegister then begin
        regname := addr2regname(addr) ;
      end else begin
        assert(MMU.getPhysicalAddressType = matPhysical22) ;
        assert(addr.mat = matPhysical22) ; // TEST, BIS MMU angeschlossen ist!
        if addr.mat = matVirtual then
          addr := MMU.Virtual2PhysicalData(addr) ;
        assert(addr.mat = matPhysical22) ;
        assert(addr.val <> MEMORYCELL_ILLEGALVAL) ;

        regname := addr2regname(addr) ;
      end;

      if regname <> '' then begin // es ist ein CPU-Register
        s := Format('E %s'+ CHAR_SIMH_CR, [regname]) ;
        examine_lastaddr.val := MEMORYCELL_ILLEGALVAL ;
      end else begin
        s := Format('E %s' + CHAR_SIMH_CR, [Dword2OctalStr(addr.val)]) ;
        examine_lastaddr := addr ;
      end;

      Answerlines.Clear ;
      WriteToPDP(s) ;
      // Antwort format:
      //  <addr> <val>
      //  sim>
      answerline := WaitForAnswer(phExamine, SIMH_CMD_TIMEOUT) ;

      if answerline = nil then
        result := MEMORYCELL_ILLEGALVAL // keine Antwort, oder ? Fehler
      else if (answerline.examinevalue <> MEMORYCELL_ILLEGALVAL)
              and (answerline.examineaddr.val <> addr.val) then
        raise Exception.CreateFmt('EXAMINE failure: request "%s", answer is "%s!"',
                [s, answerline.rawtext])
      else result := answerline.examinevalue ;

      CheckPrompt('EXAMINE failed, no prompt') ;
    finally
      OutputDebugString('Examine ends') ;
      EndCriticalSection ;
    end { "try" } ;
  end{ "function TConsolePDP11SimH.Examine" } ;


// eine ganze Memorylist auslesen.
// SimH kann E addr,addr,addr,... auswerten.
procedure TConsolePDP11SimH.Examine(mcg: TMemoryCellGroup ; unknown_only: boolean; abortable:boolean) ;

// Examine-Commandos für eine Liste ausgeben. addr_inc: 1 für globale register, sonst 2
// nur solche listmembers beachten, die tag = 0 haben (= noch nicht abgefragt sind)
// result: true, wenn alle cells abgefragt wurden
// register werden an bekanntem Registername erkannt
// false: neuer Aufruf ist nötig, mindestens die erste Zelle wurde abgefragt
// UNIBUSTIMEOUTS: abbruch, mindestens die 1. Zelle ist gesetzt (mit INVALID)

  function examineAddrList(list: TList ; addr_inc: integer): boolean ;

  // true, wenn list[idx] nicht in von-bis Beriech mit aufgenommen werden darf
    function is_SpecialAddrname(idx: integer): boolean ;
      begin
        result := addr2regname(TMemoryCell(list[idx]).addr, {tmpval!}true) <> '' ;
      end ;

    const
      max_block_len = 100 ;
    var
      blockstart, blockend: integer ; // start .. end-1 ist ein Block
      blockstart1: integer ; // Beginn eines von-bis Bereichs
      i, j: integer ;
      s: string ;
      mc: TMemoryCell ;
      cmd, sep: string ;
      starttime: dword ;
      answerline: TConsoleAnswerPhrase ;
      next_expected_addr: TMemoryAddress ;
      block_failure: boolean ; // Blockabfrage ist durcheinander, address error: restart nötig
      ready: boolean ; // false: das frage/antwort-Spiel abbrechen
      found: boolean ;
      //lastaddr: TMemoryAddress ;
      timeout: boolean ;
    begin { "function examineAddrList" }

      // Zusicherung: pro Aufruf wird immer mindestens eine weitere
      // Adresse mit tag = 1  markiert!
      result := false ;

      // finde alle sequentiellen Bereiche. addressen physical vergleichen ... addr.tmpval!
      // finde erste, nicht abgefragte adresse
      blockstart := -1 ;
      for i := 0 to list.Count - 1 do
        if TMemoryCell(list[i]).tag = 0 then begin
          blockstart := i ;
          break ;
        end;
      if blockstart = -1 then begin
        result := true ; // alle memorycells wurden einmal abgefragt, oder list empty
        Exit ;
      end;

      // finde alle sequentiellen Bereiche.
      // addressen physical vergleichen ... addr.tmpval!
      // es wird nur ein Command für die ganze Liste ausgegeben:
      // E 0-100,230,234,r0,pc,1000-1006
      // Oder:
      // E R0,R1,R2,R3,R4
      BusyForm.Start('Examining ...', list.Count, abortable) ;

      try
        block_failure := false ;
        while not BusyForm.Aborted and not block_failure and (blockstart < list.Count) do begin

          // finde einen block, in dem die Adressen um 2 aufsteigen
          // und keine Register dabei sind
          // block darf aber nicht länger als max_block_len werden,
          // längere blöcke werden unterbrochen.
          // Register, die '?' heissen, sind immer unbekannt.
          cmd := 'E' ;
          sep := ' ' ;
          blockend := blockstart ;  // blockend immer nächster Index NICHT im Bereich

          // Kommaliste aus von-bis bereichen bilden
          repeat
            blockstart1 := blockend ; // start des nächsten von-bis-Bereichs
            blockend := blockstart1+1 ;

            // (A) einzelnen von-bis bereich bilden
//          if is_SpecialAddrname(blockend) then
//            inc(blockend)
//          else
            while (blockend < list.Count)
                    and (TMemoryCell(list[blockend-1]).tag = 0)
                    and (TMemoryCell(list[blockend-1]).addr.tmpval + 2 = TMemoryCell(list[blockend]).addr.tmpval)
                    and not is_SpecialAddrname(blockend)
                    // blocklänge begrenzen
                    and ((blockend-blockstart) < max_block_len)
                    do
              inc(blockend) ;

            // cmd für von-bis Bereich rendern
            if blockend - blockstart1 > 1 then begin
              cmd := cmd + sep + Format('%s-%s', [
                      Dword2OctalStr(TMemoryCell(list[blockstart1]).addr.tmpval, 0),
                      Dword2OctalStr(TMemoryCell(list[blockend-1]).addr.tmpval, 0)
                      ]) ;
            end else begin // einzelne Adresse
              s := addr2regname(TMemoryCell(list[blockstart1]).addr, {tmpval!}true) ;
              if s = '' then
                cmd := cmd + sep + Dword2OctalStr(TMemoryCell(list[blockstart1]).addr.tmpval, 0)
              else
                cmd := cmd + sep + s ;
            end ;
            sep := ',' ;

            // Wie (A), nur negativ und ohne Test auf Unterbechung im Adressbereich
          until (blockend >= list.Count)
                  or ((blockend-blockstart) >= max_block_len) ;

          Answerlines.Clear ; // Empfangsbuffer leeren
          WriteToPDP(cmd + CHAR_SIMH_CR) ;
          // Antwort format:
          //  <addr>: <val>
          //  <addr>: <val>
          //  ...
          //  sim>
          // Ignoriere <addr>

          // warten, bis
          // - alle adressen abgefragt wurden
          // - oder ILLEGAL VAL kam. Dann gabs an der adresse
          //   (letzteadresse+inc) ein UNIBUS TIMEOUT und multi-read brach ab
          // - timeout
          starttime := GetTickCount ; // Timeout reset
          ready := false ;
          // lastaddr ist die letzte gute adresse,
          // UNIBUS timeouts werden lastaddr + inc zugeordnet
          next_expected_addr := TMemoryCell(list[blockstart]).addr ;

          repeat
            Application.ProcessMessages ; // background receive
                BusyForm.StepIt(Answerlines.Count) ;  // es sollten nur Examine-Aanswers kommen
                // no hidden ProcessMessages while scanning Answerlines: inhibit new recoeve
            // alle antworten analysieren
            for i := 0 to Answerlines.Count-1 do begin
              answerline := Answerlines.Items[i] as TConsoleAnswerPhrase ;
              if answerline.phrasetype = phExamine then begin
                Log('list examine: processing answer');
                Log(answerline.AsText);
                starttime := GetTickCount ; // Timeout reset
                // gültiges address/wert paar, oder TIMEOUT
                if answerline.examinevalue = MEMORYCELL_ILLEGALVAL then begin
                  // die aktuelle Adresse verursachte einen Fehler,
                  // sie ist aber unbekannt!
                  answerline.examineaddr.val := next_expected_addr.tmpval ;
                  block_failure := true ;
                end ;
                // finde memorycell über adresse
                found := false ;
                for j := blockstart to blockend-1 do begin
                  mc := TMemoryCell(list[j]) ;
                  if mc.addr.tmpval = answerline.examineaddr.val then begin
                    next_expected_addr := answerline.examineaddr ; // antworten kommen strikt aufsteigend
                    next_expected_addr.tmpval := answerline.examineaddr.tmpval + addr_inc ; // antworten kommen strikt aufsteigend
                    mc.tag := 1 ; // wert ist jetzt abgefragt
//Log('!!!3 mc[%s].tag = 1', [Dword2OctalStr(mc.addr.tmpval)]) ;
                    mc.pdp_value := answerline.examinevalue ;
                    found := true ;
                  end;
                end;
                if not found then Log('NO Memorycell set by this answer!');

              end{ "if answerline.phrasetype = phExamine" } ;
            end{ "for i" } ;
            // alle antworten von SimH sind jetzt abgearbeitet
            Answerlines.Clear ;

            // check, ob alle adressen abgefragt wurden
            ready := true ;
            for i := blockstart to blockend-1 do
              if TMemoryCell(list[i]).tag = 0 then
                ready := false ;
//Log('!!!4 ready=%d', [ord(ready)]) ;
            timeout := (starttime + SIMH_CMD_TIMEOUT < GetTickCount) ;
          until timeout or ready or block_failure;
          if timeout then begin // keine Exception, sonst wird die ganze Useraktion abgebrochen
            Log('EXAMINE list failure: timeout waiting for list addr %s!',
                    [Dword2OctalStr(next_expected_addr.tmpval, 22)]) ;
            result := true ; // keine weiteren versuche, Endlos-schleife!
          end;
          // nächster Block für neues "E" command
          blockstart := blockend ;
        end { "while not BusyForm.Aborted and not block_failure and (blockstart < list.Count)" } ;
        if BusyForm.Aborted then result := true ; // do not retry
      finally
        BusyForm.Close ;
      end { "try" } ;
    end{ "function examineAddrList" } ;


  var i: integer ;
    mc: TMemoryCell ;
    listmem: TList ; // sortierte Liste mit Memoryadressen (inkrement 2) ;
    listcpureg: TList ; // sortierte Liste mit CPU-Regsiteradressen (inkrement 2) ;
  begin { "procedure TConsolePDP11SimH.Examine" }
    // a) memorycells sortiert auslesen
    // b) Memory/globalregister Bereiche unterscheiden, zusammenhängende
    //    Adressbereiche unterscheiden
    // c) sequentiell aufeinanderfolgende Adressen auslesen

    listmem := TList.Create ;
    listcpureg := TList.Create ;
    try
      // list kann virtual sein ... mc's nach physical umrechnen
      // an hier ist .tmpval 22 bit!
      BeginCriticalSection ; // User sperren
      for i := 0 to mcg.Count - 1 do begin
        mc := mcg.Cell(i) ;
        mc.tag := 0 ; // markiere als "noch keine antwort"
        if not unknown_only or (mc.pdp_value = MEMORYCELL_ILLEGALVAL) then begin
          // "tmpval" aller memorycell.addr wird die physical addr
          // nur auszulesende Adressen in die Listen
          // Register, die '?' heissen, sind von SimH nicht abfragbar
          assert(MMU.getPhysicalAddressType = matPhysical22) ;
          if mc.addr.mat = matVirtual then
            mc.addr.tmpval := MMU.Virtual2PhysicalData(mc.addr).val
          else
            mc.addr.tmpval :=  mc.addr.val ;

          if addr2regname(mc.addr, {tmpval!}true) <> '?' then
            if addr2regname(mc.addr, {tmpval!}true) <> '' then
              listcpureg.Add(mc)
            else listmem.Add(mc) ;
        end{ "if not unknown_only or (mc.pdp_value = MEMORYCELL_ILLEGALVAL)" } ;
      end{ "for i" } ;

      listmem.Sort(MemoryCellSortCompare) ; // aufsteigend sortieren
      listcpureg.Sort(MemoryCellSortCompare) ;

      // alle die analysieren, die tag = 0 haben
      // Abfrage kann mittendrin abbrechen, wenn address failure
      while not examineAddrList(listmem, 2) do ;
      while not examineAddrList(listcpureg, 1) do ;

    finally
      listmem.Free ;
      listcpureg.Free ;
      EndCriticalSection('Examine') ;
    end{ "try" } ;

  end { "procedure TConsolePDP11SimH.Examine" } ;


// sagt der TPDP-Console, dass sie nix mehr über SimH weiss
procedure TConsolePDP11SimH.ClearState ;
  begin
    inherited ;
    examine_lastaddr.val := MEMORYCELL_ILLEGALVAL ; // erzwinge explizite Adressausgabe
    deposit_lastaddr.val := MEMORYCELL_ILLEGALVAL ; // erzwinge explizite Adressausgabe
    CpuState := scsUnknown ;
    SilentHaltPending := false ;
  end;


// "RESET" is not in SimH's remote console command whitelist (see comment
// on CheckPromptNoOutput). Unlike ResetMachineAndStartCpu, there is no
// whitelisted command that resets the machine WITHOUT also starting the
// CPU - "RUN" resets, but immediately starts execution from the current
// PC, which would run an unknown number of instructions before pdp11gui
// could stop it again. Rather than silently doing nothing (the previous
// behaviour, since CheckPrompt alone doesn't notice the rejected command)
// or risking that unsafe RUN-then-halt approach, this now fails loudly so
// the caller/user knows the reset did not happen.
procedure TConsolePDP11SimH.ResetMachine ; // Maschine CPU reset
  begin
    try
      BeginCriticalSection ; // User sperren
      Answerlines.Clear ;
      // Der PC wird nicht gesetzt => kein cfFlagResetCpuSetsPC
      WriteToPDP('reset all'+ CHAR_SIMH_CR) ;
      CheckPromptNoOutput('Reset failed, no prompt', 'reset all') ;
      CpuState := scsHalted ; // reset always halts
    finally
      EndCriticalSection ;
    end;
  end;




// PC ist virtuelle 16 bit Adresse
// Run mit Reset
// "RESET" is not in SimH's remote console command whitelist (see comment on
// CheckPromptNoOutput), so a separate "reset cpu" + "go" no longer works
// over the "Direct simh"/telnet remote console: the reset silently gets
// rejected and only the "go" actually runs. "RUN" *is* whitelisted, and
// internally resets all devices before starting (see sim_run_boot_prep() in
// SimH's scp.c) - so a single "run" replaces "reset cpu" + "go" and is the
// only way left to get an actual reset over this channel. "-Q" suppresses
// SimH's "Resetting all devices..." notice it would otherwise print on
// every run after the first.
procedure TConsolePDP11SimH.ResetMachineAndStartCpu(newpc_v: TMemoryAddress) ;  // CPU starten.
  var s: string ;
  begin
    try
      BeginCriticalSection ; // User sperren

      assert(newpc_v.mat = matVirtual) ;

      Answerlines.Clear ;
      SilentHaltPending := false ;
      onExecutionStopDetected := false ; // clear any stale flag from an earlier, unrelated action
      s  := Format('run -q %s'+ CHAR_SIMH_CR, [Dword2OctalStr(newpc_v.val, 16)]) ;
      WriteToPDP(s) ;
      // keine Prompt, CPU läuft jetzt - stays fire-and-forget, does not
      // wait for/block on confirmation (that used to freeze the UI for
      // however long confirmation took - observed to occasionally run into
      // several seconds).
      //
      // Set CpuState optimistically, right now, synchronously - same
      // pattern ContinueCpu already uses. Without this there is a real
      // race: HaltCpu decides purely from CpuState, and if it's clicked
      // before the scanner has processed "Simulator Running..." (easy to
      // do now that this method returns instantly), CpuState is still
      // stale and HaltCpu wrongly concludes there is nothing to halt while
      // the CPU is, in fact, genuinely running. If the CPU turns out to
      // have silently self-halted instead (eg. no program loaded, PC
      // pointing at zeroed memory that decodes as HALT), the scanner
      // corrects CpuState back to Halted and flags SilentHaltPending
      // within one poll cycle, and SilentHaltTimerTimer resolves the real
      // PC and notifies the UI shortly after - see its comment.
      CpuState := scsRunning ;
    finally
      EndCriticalSection ;
    end{ "try" } ;
  end{ "procedure TConsolePDP11SimH.ResetMachineAndStartCpu" } ;


procedure TConsolePDP11SimH.ContinueCpu ; // Maschine CPU reset
  begin
    Answerlines.Clear ;
    WriteToPDP('cont'+ CHAR_SIMH_CR) ;
    CpuState := scsRunning ; // optimistic; the scanner corrects it if this turns out to be wrong
//      CheckPrompt('Continue failed, no prompt') ;

  end;

// PC ist virtuelle 16 bit Adresse
// ^E only makes SimH's remote console do anything special ("Simulation
// stopped, PC: ...") while it considers itself mid-RUN - verified live
// against a real running loop. Outside that state it is just an inert
// stray byte that eventually surfaces as "Unknown command". doHalt()
// (FormExecuteU) calls this unconditionally regardless of believed UI
// state ("improvised" halt, always available) - CpuState is tracked
// continuously (see DecodeNextAnswerPhrase) precisely so this can check
// the real, protocol-confirmed state instead of guessing from a timeout.
procedure TConsolePDP11SimH.HaltCpu(var newpc_v: TMemoryAddress) ; // CPU anhalten
  var answerline: TConsoleAnswerPhrase ;
  begin
    try
      BeginCriticalSection ; // User sperren

      if CpuState <> scsRunning then begin
        Log('HaltCpu: CpuState=%s, nothing to halt', [SimhCpuStateName(CpuState)]) ;
        newpc_v.mat := matUnknown ;
        newpc_v.val := MEMORYCELL_ILLEGALVAL ;
        Exit ;
      end;

      Answerlines.Clear ;
      // ^E hauen. Dann muss die CPU ihren PC auspucken und anhalten
      WriteToPDP(CHAR_SIMH_HALT) ; // ^E

      answerline := WaitForAnswer(phHalt, SIMH_HALT_TIMEOUT) ;
      WriteToPDP(CHAR_SIMH_CR) ; // Störungen beseitigen
      if answerline = nil then begin
        // CpuState said Running, so this is a genuine unexpected failure
        // (unlike the "already halted" case above, filtered out before we
        // ever sent anything).
        Log('HaltCpu: CpuState was Running but ^E got no reply') ;
        newpc_v.mat := matUnknown ;
        newpc_v.val := MEMORYCELL_ILLEGALVAL ;
        Exit ;
      end;

      CheckPrompt('Stopping CPU failed, no prompt') ;
      // jetzt wurde der Output mit ReadFromPdp() gelesen,
      // und MonitorPdpOutput() hat den CpuStop-Event erkannt
      newpc_v := onExecutionStopPcVal ;
    finally
      EndCriticalSection ;
    end{ "try" } ;
  end{ "procedure TConsolePDP11SimH.HaltCpu" } ;


// PC ist virtuelle 16 bit Adresse
// einen Zyklus ausführen, danach CPU-Stop-Event auslösen
procedure TConsolePDP11SimH.SingleStep;
  var answerline: TConsoleAnswerPhrase ;
    pcaddr: TMemoryAddress ;
  begin
    try
      BeginCriticalSection ; // User sperren

//        assert(newpc_v.mat = matVirtual) ;

      // vor Singlestep den PC setzen.
      // Im SimH-Step-Cmd kann er nicht nochmal angegeben werden.
      pcaddr.mat := matPhysical22 ;
      pcaddr.val := _17777707 ;
//        Deposit(pcaddr, newpc_v.val) ;


      Answerlines.Clear ;
      WriteToPDP('STEP 1'+ CHAR_SIMH_CR) ;
      answerline := WaitForAnswer(phHalt, SIMH_CMD_TIMEOUT) ;
      if answerline = nil then raise Exception.Create('Single Step failed, no answer') ;

      CheckPrompt('Single Step failed, no prompt') ;
      CpuState := scsHalted ;
      // jetzt wurde der Output mit ReadFromPdp() gelesen,
      // und MonitorPdpOutput() hat den CpuStop-Event erkannt
//        newpc_v := onExecutionStopPcVal ;
    finally
      EndCriticalSection ;
    end{ "try" } ;
  end{ "procedure TConsolePDP11SimH.SingleStep" } ;



end{ "unit ConsolePDP11SimHU" } .



