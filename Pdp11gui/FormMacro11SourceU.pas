unit FormMacro11SourceU;
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

interface

uses
  SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, SynEdit, ExtCtrls,
  FileUtil,
  FormChildU,
  AppControlU,
  JH_Utilities;

type
  TFormMacro11Source = class(TFormChild)
      PanelT: TPanel;
      Editor: TSynEdit;
      LoadButton: TButton;
      SaveAsButton: TButton;
      CompileButton: TButton;
      OpenDialog1: TOpenDialog;
      SaveDialog1: TSaveDialog;
      SaveButton: TButton;
      NewButton: TButton;
      procedure LoadButtonClick(Sender: TObject);
      procedure SaveAsButtonClick(Sender: TObject);
      procedure CompileButtonClick(Sender: TObject);
      procedure SaveButtonClick(Sender: TObject);
      procedure EditorResize(Sender: TObject);
      procedure EditorChange(Sender: TObject);
      procedure FormShow(Sender: TObject);
      procedure NewButtonClick(Sender: TObject);
    private
      { Private-Deklarationen }
      originalFileContent: TStringList ; // disk mirror to calculate "Changed()"
      // Ersatz fuer JvEditor.LineInformations: JvEditor/JVCL ist unter
      // Lazarus nicht verfuegbar, Editor ist jetzt ein TSynEdit.
      // Es kann jeweils nur 1 Zeile markiert sein (Fehler- oder
      // Ausfuehrungszeile) - genau wie im alten Code, der bei jedem Aufruf
      // erst alle anderen Zeilen auf "unselected" zuruecksetzte.
      // Siehe LINUX_PORT_TODO.md.
      HighlightLine: integer ; // 0-based Zeilenindex, -1 = keine
      HighlightBG, HighlightFG: TColor ;
      procedure EditorSpecialLineColors(Sender: TObject; Line: integer;
              var Special: boolean; var FG, BG: TColor) ;
      procedure FormAfterShow(Sender: TObject);
      procedure FormBeforeHide(Sender: TObject);
    public
      { Public-Deklarationen }
      macro11_appcontrol: TAppControl ;
      SourceFilename: string ;
      CanTranslate: boolean ; // true, wenn gültiger File geladen
      Translated: boolean ; // true, wenn MACRO-11 Lauf erfolgreich
      constructor Create(aOwner: TComponent) ; override ;
      destructor Destroy ; override ;
      procedure UpdateDisplay ;
      procedure LoadFile(fname:string);
      procedure SaveFile(fname:string);
      function Changed: boolean ; // true, if unsaved changes in Editor
      procedure Compile ;
      procedure setErrorLine(n:integer) ;
      procedure setExecutionLine(n:integer) ;

    end{ "TYPE TFormMacro11Source = class(TFormChild)" } ;

implementation


uses
  RegistryU,
  AuxU,
  FormMainU // wg. zugriff auf Listing Window
          , FormMacro11ListingU;

{$R *.dfm}

constructor TFormMacro11Source.Create(aOwner: TComponent) ;
  begin
    inherited Create(aOwner) ;
    originalFileContent := TStringList.Create ;

    // private events
    // die MDI-Show/Hide logik in TFormChild verursacht Windowsgehler,
    // wenn JVEditor eine lange Source geladen hat.
    OnAfterShow := FormAfterShow ; // lädt den letzten File
    OnBeforeHide := FormBeforeHide ;

    CanTranslate := false ;
    Translated := false ;

    // Farbe fuer die markierte Zeile (Fehler- oder Ausfuehrungszeile;
    // das alte JvEditor-basierte setErrorLine()/setExecutionLine() nutzten
    // beide "lssErrorPoint", die ErrorPoint-Farben werden daher fuer beide
    // Faelle verwendet - siehe EditorSpecialLineColors())
    HighlightLine := -1 ;
    HighlightBG := ColorCodeErrorBkGnd ;
    HighlightFG := ColorCodeErrorText ;
    Editor.OnSpecialLineColors := EditorSpecialLineColors ;

    macro11_appcontrol := TAppControl.Create ;
  end{ "constructor TFormMacro11Source.Create" } ;


destructor TFormMacro11Source.Destroy ;
  begin
    macro11_appcontrol.Free ;
    originalFileContent.Free ;
    inherited ;
  end;

procedure TFormMacro11Source.UpdateDisplay ;
  var i: integer ;
  begin
    // bei Änderung:
    if Changed then
      Caption := setFormCaptionInfoField(Caption, ' * ' + SourceFilename)
    else
      Caption := setFormCaptionInfoField(Caption, SourceFilename) ;

    if Trim(SourceFilename) = '' then
      SaveButton.Enabled := false // kein Name bekannt
    else SaveButton.Enabled := true ;

    // wenn irgendwas nicht leeres drin steht: Compile-knopf an.
    CanTranslate := false ;
    for i := 0 to Editor.Lines.Count - 1 do
      if Trim(Editor.Lines[i]) <> '' then
        CanTranslate := true ;

    // noch ein Check: gültige Datei da?
    if not FileExists(SourceFilename) then
      CanTranslate := false ;

    CompileButton.Enabled := CanTranslate ;

    // Der CompileButton ist auch disabled, wenn neue Source eingeben wurde,
    // aber noch kein filenamen bekannt ist!
    // (Da dann nicht fürs compilieren gespeichert werden kann)

  end{ "procedure TFormMacro11Source.UpdateDisplay" } ;

procedure TFormMacro11Source.EditorChange(Sender: TObject);
  begin
    Log('TFormMacro11Source.Changed := true') ;
    UpdateDisplay ;
  end;

// Ersatz fuer JvEditor.LineInformations.SelectStyle[]: markiert
// "HighlightLine" (falls gesetzt) mit "HighlightBG"/"HighlightFG".
procedure TFormMacro11Source.EditorSpecialLineColors(Sender: TObject; Line: integer;
        var Special: boolean; var FG, BG: TColor) ;
  begin
    if (Line - 1) = HighlightLine then begin
      Special := true ;
      FG := HighlightFG ;
      BG := HighlightBG ;
    end ;
  end{ "procedure TFormMacro11Source.EditorSpecialLineColors" } ;


procedure TFormMacro11Source.EditorResize(Sender: TObject);
  begin
    Invalidate ; // zeichnet sich sonst nicht richtig neu
  end;

procedure TFormMacro11Source.FormBeforeHide(Sender: TObject);
  begin
    // source aus editor löschen
    Editor.Lines.Clear ;
    originalFileContent.Clear ; // supress "Changed = true"
  end;

procedure TFormMacro11Source.FormShow(Sender: TObject);
  begin
    UpdateDisplay ;
  end;

procedure TFormMacro11Source.FormAfterShow(Sender: TObject);
  begin
    // source neu in editor laden
    // letzten File automatisch laden
    SourceFilename := TheRegistry.Load('SourceFilename', '') ;
    if SourceFilename <> '' then
      LoadFile(SourceFilename);
  end;


// Die Zeile mit einem Fehler drin markieren
procedure TFormMacro11Source.setErrorLine(n:integer) ;
  begin
    dec(n) ; // Lines[] ab 0 !
    HighlightLine := n ;
    Editor.Invalidate ;
    Editor.CaretX := 1 ;
    Editor.CaretY := n+1 ; // scrolle sichtbar, Zeile anfahren
    Editor.EnsureCursorPosVisible ;
  end;

// Die gerade ausgeführte Zeile markieren
procedure TFormMacro11Source.setExecutionLine(n:integer) ;
  begin
    HighlightLine := n ;
    Editor.Invalidate ;
  end;



// fname = '': new emtpy file
procedure TFormMacro11Source.LoadFile(fname:string);
  var
    tmpLines: TStringList ;
    i: integer ;
  begin
    originalFileContent.Clear ;
    Caption := setFormCaptionInfoField(Caption, '') ;
    CanTranslate := false ;

    if (fname <> '') and not FileExists(fname) then
      Exit ;

    // 1. clear editor

    setErrorLine(-1); // marker löschen
    setExecutionLine(-1);
    Editor.Clear ;

    if fname <> '' then begin
      // 2. load file
      tmpLines:= TStringList.Create ;
      try
        Log('LoadFromFile(%s)', [fname]) ;
        try
          tmpLines.LoadFromFile(fname);
        except on E: Exception do
            raise Exception.CreateFmt('Error in Macro11Source.Loadfile(): can not read file %s', [fname]);
        end;
        // laden mit detab: TJvEditor does not display Tabs?
        for i := 0 to tmpLines.Count - 1 do
          tmpLines[i] := detab(tmpLines[i], 8) ;
        Editor.BeginUpdate ; // supress events while loading
        Editor.Lines.Assign(tmpLines) ;
        originalFileContent.Assign(tmpLines) ;
        Editor.EndUpdate ;

        Log('TFormMacro11Source.Loadfile(): Changed := false') ;

        TheRegistry.Save('SourceFilename', fname);
      finally
        tmpLines.Free ;
      end{ "try" } ;

    end { "if fname <> ''" } ;
    // Editor.LineInformations.SelectStyle[6] := lssUnselected ;
    // Editor.LineInformations.SelectStyle[8] := lssBreakPoint ;
    // Editor.LineInformations.SelectStyle[10] := lssDebugPoint ;
    // Editor.LineInformations.SelectStyle[12] := lssErrorPoint ;
    CanTranslate := true ;
    SourceFilename := fname ; // '', if "New"
    UpdateDisplay ;
  end{ "procedure TFormMacro11Source.LoadFile" } ;


procedure TFormMacro11Source.SaveFile(fname:string);
  var f: System.Text ;
    i: integer ;
    s: string ;
  begin
    Log('TFormMacro11Source.SaveFile(%s)', [fname]) ;
    try
      AssignFile(f, fname) ;
      try
        Rewrite(f) ;
        for i := 0 to Editor.Lines.Count - 1 do begin
          s := Editor.Lines[i] ;
          s := entab(s, 8) ; // unnötig, und kaputt?
          writeln(f, s) ;
        end;
        originalFileContent.Assign(Editor.Lines) ;
        Log('TFormMacro11Source.Savefile(): Changed := false') ;
      finally
        CloseFile(f) ;
      end;
    except on E: Exception do
        raise Exception.CreateFmt('Error in Macro11Source.SaveFile(): can not save to file %s', [fname]);
    end{ "try" } ;
    TheRegistry.Save('SourceFilename', fname);
    Caption := setFormCaptionInfoField(Caption, fname) ;
    UpdateDisplay ;
  end{ "procedure TFormMacro11Source.SaveFile" } ;

// compare Editor content with fileContent
function TFormMacro11Source.Changed: boolean ;
  begin
    // Editor.Lines.SaveToFile('e:\temp\editorslines.txt') ;
    // originalFileContent.SaveToFile('e:\temp\originalFileContent.txt');
    result := not Editor.Lines.Equals(originalFileContent) ;
  end;

// Source Im Editor mit MACRO11 übersetzten
// Listing automatisch ins Listingfenster laden
//
procedure TFormMacro11Source.Compile;
  const timeout_millis = 5000 ; // macro11 darf max 5 Sek laufen!
  var
    macro11_path: string ;
    listfilename: string ;
    workdir: string ;
    errormsg: string ;
    errorline: integer ;

  // Startet macro11 mit den gegebenen argv[]-Elementen und wartet bis
  // Ende oder Timeout. "args" landen 1:1 als eigene Kommandozeilen-
  // Argumente (kein Shell-String, siehe AppControlU.StartApplication).
  procedure RunMacro11(const args: array of string) ;
    var starttime: dword ;
      timeout: boolean ;
      i: integer ;
      argsStr: string ;
    begin
      argsStr := '' ;
      for i := low(args) to high(args) do
        argsStr := argsStr + args[i] + ' ' ;
      Log('Starting MACRO11:') ;
      Log('  Path    : %s', [macro11_path]) ;
      Log('  args    : %s', [argsStr]) ;
      Log('  work dir: %s', [workdir]) ;
      with macro11_appcontrol do begin
        starttime := GetTickCount ;
        StartApplication(macro11_path, args, workdir) ;
        // warte, bis timeout, oder macro11 fertig
        repeat
          Application.ProcessMessages ;
          sleep(50) ;
          timeout :=  GetTickCount > (starttime+timeout_millis) ;
        until timeout or not ApplicationContact ;
        if timeout then
          raise Exception.CreateFmt('MACRO11 timeout: running longer then %d secs', [timeout_millis div 1000]) ;
      end{ "with macro11_appcontrol" } ;
    end{ "procedure RunMacro11" } ;

  begin
    // Marken löschen
    setExecutionLine(-1) ;
    setErrorLine(-1);
    errormsg := '' ;
    errorline := -1 ;
    Translated := false ;

    // macro11 auf dem PATH suchen (Linux: siehe ~/bin/macro11,
    // https://github.com/rhefner1/macro11 - ersetzt das alte, Windows-
    // spezifische macro11.bat/macro11.exe).
    macro11_path := FindDefaultExecutablePath('macro11') ;
    if macro11_path = '' then
      raise Exception.Create('"macro11" not found on PATH. Install it and make sure it is on the PATH.') ;

    workdir := ExtractFileDir(SourceFilename) ;
    if not IsDirectoryWriteable(workdir) then
      raise Exception.CreateFmt('Can not write to directory "%s". Perhaps it''s read-only flag or you must "Run as Admin".',
              [workdir]) ;

    if Changed then
      // auto speichern. Disk driver are readonly and write protected.
      SaveFile(SourceFilename) ;

    listfilename := ChangeFileExt(SourceFilename, '.lst') ; // same directory
    DeleteFile(listfilename) ;

    // wie macro11.bat: normaler Lauf, Listing in Oktal
    // "-e AMA" (absolute statt PC-relative Adressierung) ist in macro11.bat
    // auskommentiert, wird daher hier auch nicht benutzt.
    RunMacro11([SourceFilename, '-l', listfilename]) ;

    // wie macro11.bat: zusaetzlicher Lauf, Listing mit Code in Hex statt
    // Oktal (fuer Logic-Analyzer-Auswertung). Ein Fehlschlagen hiervon soll
    // den Compile-Vorgang nicht abbrechen, macro11.bat prueft das genauso
    // wenig.
    try
      RunMacro11(['-e', 'listhex', SourceFilename, '-l', listfilename + '.hex']) ;
    except
      on E: Exception do
        Log('MACRO11 hex listing failed: %s', [E.Message]) ;
    end;

    ///// Mögliche Fehlermeldungen erkennen
    ///   in der Source und im Listing rot markieren,
    ///   und im Logfenster anzeigen
    if not FileExists(listfilename) then begin
      errormsg := Format('MACRO11 failure: list file %s not found', [listfilename]) ;
    end else begin
      // Codeform füllen und anzeigen. Fehler im Listing finden und anzeigen
      with FormMain do begin
        // listingform füllen und anzeigen

        TheRegistry.Save(FormMacro11Listing) ; // jetzige position sichern
        setChildFormVisibility(FormMacro11Listing, true);

        FormMacro11Listing.LoadFile(listfilename) ; // echtes load erst in OnAfterShow()
        // Nur die Listingform kann auch die Fehlermeldungen finden
        FormMacro11Listing.ParseCode ;
        errormsg  := FormMacro11Listing.FirstErrorMsg ;
        errorline := FormMacro11Listing.FirstErrorLineNr ;

        // nicht automatisch den hex dump anzeigen.
        // FormMacro11Listing.ShowCodeForm ;
      end{ "with FormMain" } ;

      // Wenn eine Fehlerzeile da ist:
      if errormsg <> '' then begin
        setErrorLine(errorline) ;
        errormsg := Format('MACRO-11 Error in line %d: "%s"', [errorline, errormsg]) ;

        Log(errormsg) ;
        UpdateDisplay ;
        BringToFront ;

        MessageDlg(errormsg, mtError, [mbOk], 0) ; // aufpoppen!
      end else begin
        Translated := true ;
      end;
    end{ "if not FileExists(listfilename) ... ELSE" } ;

  end{ "procedure TFormMacro11Source.Compile" } ;


procedure TFormMacro11Source.CompileButtonClick(Sender: TObject);
  begin
    Compile ;
  end;


procedure TFormMacro11Source.NewButtonClick(Sender: TObject);
  begin
    LoadFile('') ; // "new"
  end;


procedure TFormMacro11Source.LoadButtonClick(Sender: TObject);
  begin
    if SourceFilename = '' then
      OpenDialog1.InitialDir := FormMain.DefaultDataDirectory
    else OpenDialog1.InitialDir := ExtractFilePath(SourceFilename) ;
    if OpenDialog1.Execute then begin
      LoadFile(OpenDialog1.FileName) ;
    end;
  end;


procedure TFormMacro11Source.SaveAsButtonClick(Sender: TObject);
  begin
    if SaveDialog1.InitialDir = '' then
      SaveDialog1.InitialDir := FormMain.DefaultDataDirectory ;
    SaveDialog1.FileName := SourceFilename ;
    if SaveDialog1.Execute then begin
      SourceFilename := SaveDialog1.FileName ;
      SaveFile(SourceFilename);
    end;
    UpdateDisplay ;
  end;

procedure TFormMacro11Source.SaveButtonClick(Sender: TObject);
  begin
    if not FileExists(SourceFilename) then
      SaveAsButtonClick(Sender) // fall back to "Save As"
    else begin
      SaveFile(SourceFilename);
      UpdateDisplay ;
    end;
  end;


end{ "unit FormMacro11SourceU" } .
