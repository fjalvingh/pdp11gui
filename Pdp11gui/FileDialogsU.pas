unit FileDialogsU;
{
   Central handling of all file open/save dialogs.

   Every file dialog in PDP11GUI behaves the same way:
   - the first dialog of a program run starts in the user's home directory,
   - every later dialog starts in the directory used last,
   - hidden files are never shown.

   Call ExecuteFileDialog() instead of TOpenDialog.Execute()/TSaveDialog.Execute(),
   and call InitFileDialogs() once at program start, before the widgetset is
   created.
}

interface

uses
  Dialogs ;

{ Prepare the file dialog machinery. Must be called before Application.Initialize. }
procedure InitFileDialogs ;

{ Show a file dialog, starting in the directory used last (the user's home
  directory for the first dialog of this program run). Only the *name* part of
  suggestedFilename is used as preselected file name; its directory is ignored,
  so that the dialog always opens where the user was working last.
  Returns true if the user selected a file. }
function ExecuteFileDialog(dialog: TOpenDialog; const suggestedFilename: string = '') : boolean ;


implementation

uses
  SysUtils
{$IFDEF LCLQt5}
  , qt5
{$ENDIF}
  ;

{$IFDEF LCLQt5}
const
  // Qt::AA_DontUseNativeDialogs. Not (yet) part of the QtApplicationAttribute
  // enum in the Qt5Pas bindings, so it has to be passed by its numeric value.
  QtApplicationAttribute_DontUseNativeDialogs = 23 ;
{$ENDIF}

var
  // directory of the file selected in the last dialog, '' before the first one
  LastDirectory: string = '' ;


procedure InitFileDialogs ;
  begin
{$IFDEF LCLQt5}
    // Under GNOME, Qt hands file dialogs over to the desktop's GTK3 file
    // chooser. That chooser has its own idea of the directory to start in and
    // obeys the desktop wide "show hidden files" setting, so it ignores both
    // InitialDir and the wish not to see hidden files. Qt's own file dialog
    // does what the application asks for, so use that one everywhere.
{$PUSH}{$R-}{$WARN 4110 OFF}
    QCoreApplication_setAttribute(
      QtApplicationAttribute(QtApplicationAttribute_DontUseNativeDialogs), true) ;
{$POP}
{$ENDIF}
  end{ "procedure InitFileDialogs" } ;


function FileDialogDirectory: string ;
  begin
    if (LastDirectory <> '') and DirectoryExists(LastDirectory) then
      result := LastDirectory
    else
      result := GetUserDir ; // home directory, always with trailing delimiter
    result := ExcludeTrailingPathDelimiter(result) ;
  end{ "function FileDialogDirectory" } ;


function ExecuteFileDialog(dialog: TOpenDialog; const suggestedFilename: string) : boolean ;
  var dir: string ;
  begin
    dialog.InitialDir := FileDialogDirectory ;
    dialog.Options := dialog.Options - [ofForceShowHidden] ;
    dialog.FileName := ExtractFileName(suggestedFilename) ;

    result := dialog.Execute ;

    if result then begin
      dir := ExtractFilePath(dialog.FileName) ;
      if DirectoryExists(dir) then
        LastDirectory := dir ;
    end;
  end{ "function ExecuteFileDialog" } ;


end{ "unit FileDialogsU" } .
