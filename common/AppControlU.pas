unit AppControlU;

{
 Appcontrol:
 Steuerung einer fremden Applikation mit Maus und Tastatur.
 Fuer Scripting.

 Es gibt nur eine globale Instanz von der Klasse: AppControl,
 sie wird gleich hier erzeugt.

 --- Linux/Lazarus port ---
 Das Original war eine sehr grosse (~900 Zeilen), rein auf Win32-APIs
 (FindWindow, keybd_event, mouse_event, SetCursorPos, PostMessage, ...)
 aufgebaute GUI-Automatisierung: Fenster eines fremden Programms per Titel/
 Klassenname finden, und darin per simulierten Maus-/Tastatur-Events
 "wie ein Mensch" Text eintippen und klicken.

 In der gesamten App wird davon tatsaechlich nur der Kern benutzt (siehe
 FormMacro11SourceU.pas: Compile()): eine externe Anwendung starten
 (StartApplication) und pruefen, ob sie noch laeuft (ApplicationContact).
 Der ganze Maus-/Tastatur-Simulationsteil (FindWindowByTitleOrClassname,
 MouseClick/Move, humanMouseMove/Click, KeyDown/KeyUp, EnterText,
 setWindowSize/Position, ...) hat keinen einzigen Aufrufer im Projekt und
 wurde daher nicht portiert - siehe LINUX_PORT_TODO.md. Falls das jemals
 gebraucht wird, braucht es unter Linux/X11 ohnehin ein komplett anderes
 Fundament (z.B. xdotool oder eine libXtst-Anbindung), keine 1:1-Portierung
 der Win32-Aufrufe.

 StartApplication/ApplicationContact sind hier echt (nicht gestubbt)
 implementiert, auf Basis von FPC's plattformunabhaengiger TProcess.
}

interface

uses
  Classes,
  Process;

type

  // wird von Scripting benutzt
  TAppControl = class(TPersistent)
    private
      fProcess: TProcess;
    public
      constructor Create;
      destructor Destroy; override;

      // startet imagefilename mit args im Verzeichnis workingdir.
      procedure StartApplication(imagefilename, args, workingdir: string);
      // false, wenn die von StartApplication() gestartete Anwendung nicht
      // mehr laeuft (oder nie gestartet wurde).
      function ApplicationContact: boolean;
      // wartet, bis die Anwendung beendet ist (oder gibt sofort zurueck,
      // wenn sie nicht laeuft), und liefert den Exitcode.
      function WaitForApplication: integer;
      procedure ApplicationTerminate;

    end{ "TYPE TAppControl = class(TPersistent)" } ;

implementation

uses
  SysUtils;

constructor TAppControl.Create;
  begin
    inherited;
    fProcess := nil;
  end;

destructor TAppControl.Destroy;
  begin
    ApplicationTerminate;
    inherited;
  end;

procedure TAppControl.StartApplication(imagefilename, args, workingdir: string);
  begin
    ApplicationTerminate; // vorherigen Prozess ggf. beenden

    fProcess := TProcess.Create(nil);
    try
      fProcess.Executable := imagefilename;
      if args <> '' then
        fProcess.Parameters.Add(args); // Original uebergab args ebenfalls als 1 String (Windows CommandLine-Konvention)
      fProcess.CurrentDirectory := workingdir;
      fProcess.Options := [];
      fProcess.ShowWindow := swoShowNormal;
      fProcess.Execute;
    except
      on E: Exception do begin
        FreeAndNil(fProcess);
        raise Exception.CreateFmt('Could not start application from "%s": %s', [imagefilename, E.Message]);
      end;
    end;
  end{ "procedure TAppControl.StartApplication" } ;

function TAppControl.ApplicationContact: boolean;
  begin
    result := (fProcess <> nil) and fProcess.Running;
  end;

function TAppControl.WaitForApplication: integer;
  begin
    result := 0;
    if fProcess <> nil then begin
      fProcess.WaitOnExit;
      result := fProcess.ExitStatus;
    end;
  end;

procedure TAppControl.ApplicationTerminate;
  begin
    if fProcess <> nil then begin
      if fProcess.Running then
        fProcess.Terminate(1);
      FreeAndNil(fProcess);
    end;
  end;

end{ "unit AppControlU" } .
