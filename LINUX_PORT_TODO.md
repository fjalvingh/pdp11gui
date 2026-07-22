# PDP11GUI: Delphi -> Lazarus/Linux port — running log

This file tracks decisions, compromises, and known gaps made while porting
PDP11GUI from Delphi/Windows to Lazarus/Free Pascal on Linux. It exists so
we don't lose track of behavioral changes that were made purely to get the
project compiling, and which may need revisiting.

Goal right now: get `pdp11GUI.lpi` to build cleanly with `lazbuild` on
Linux/GTK2. Runtime/UI correctness is being deferred to a follow-up pass
(see "Not yet verified at runtime" below).

## Project-wide changes

- `pdp11GUI.lpi`: added `<Parsing><SyntaxOptions><SyntaxMode Value="Delphi"/>`.
  Without this, FPC's default ObjFPC mode rejects the extremely common
  Delphi idiom `SomeEvent := SomeMethod;` (assigning a method to an event
  property without an explicit `@`) with "Wrong number of parameters
  specified". Delphi mode avoids having to touch every such assignment
  across ~90 files.
- `pdp11GUI.lpi` search paths: added `../common`, `../PDP1170Panel/delphi`,
  and the precompiled `fcl-net` units dir (for `Sockets`/`NetDB`, used by
  `GetIPAddress`).
- Removed decorative/unused `Windows` (and sometimes `Messages`) unit
  imports from ~48 files. Each was checked for real Win32 API usage
  (`GetTickCount`, message handlers, `WM_*`, etc.) before removal — none
  had any. `GetTickCount` itself is cross-platform via `SysUtils`.
- `FormChildU.pas`: added `Controls` to `uses` — `TFormStyle` lives in
  `Controls` in LCL, not `Forms` (unlike Delphi's VCL).

## JVCL removed (TJvStringGrid -> TStringGrid)

JVCL (JEDI VCL) is not available for Lazarus. `TJvStringGrid` was used as
the grid component in the core memory-display subsystem:
`FormMmuU`, `FrameMemoryCellGroupGridU`, `FormMicroCodeU`, `FormBitfieldsU`,
`MemoryCellU`, `FrameMemoryCellGroupListU` (both the `.pas` field/type
declarations and the `.dfm` `object ... : TJvStringGrid` class names).

Swapped mechanically to LCL's built-in `TStringGrid`. The code in these
files only used plain grid members (`Cells`, `ColWidths`, `OnSelectCell`,
`OnGetEditText`/`OnSetEditText`, `OnDrawCell`, `InplaceEditor`), which
`TStringGrid` also supports — no JVCL-only APIs (sorting, special column
types, DB-awareness) were found in use.

**Not yet verified at runtime**: the `.dfm` files may still contain
JVCL-only published properties in the grid `object` blocks that
`TStringGrid` doesn't have. Lazarus's form-streaming is normally tolerant
of unknown properties (skips + warns rather than crashing), but this needs
to actually be checked once the app can run.

## TRichEdit removed (-> TMemo), 2026-07-22

`FormTerminalU.pas` (the raw serial I/O terminal window) used Delphi's
`TRichEdit` to color-code text by origin: PDP output vs. user-typed input
vs. system/status messages (via `RichEdit1.SelAttributes.Color`, see old
lines ~199-205).

Base Lazarus/LCL has **no built-in rich-text-edit widget**. The `RichMemo`
third-party package would restore this, but was not installed (network
access to fetch it is available if this is revisited — see below).

**Decision (user, 2026-07-22): use a plain `TMemo` for now.** This means
the terminal window will lose the color distinction between PDP
output/user input/system messages — all text will render in one color.
Functionally the terminal still works (echo, logging, copy, clear, etc.).

**Follow-up if color-coding is wanted back**: install the `RichMemo`
Lazarus package (https://github.com/lazarus-ccr / OPM) and reinstate
`TRichEdit`-equivalent usage in `FormTerminalU.pas`, or implement a
custom-colored view (e.g. a `TSynEdit` with a small custom highlighter).

## common/JH_Utilities.pas — Windows API replacements

This is the base utility unit almost everything else depends on
(`RegistryU.TheRegistry` is a `TJH_Registry` from here). Replacements:

- `TRegistry` (Windows registry) -> FPC's `fcl-registry` `Registry` unit,
  which is cross-platform: on Linux it emulates the same `TRegistry` API
  backed by a file (not a real registry). `RegistryU.pas` sets
  `Key := '\Software\Joerg Hoppe\PDP11GUI\'` — the `\`-separated key-path
  convention is independent of filesystem path separators and works
  unchanged under `fcl-registry`.
- `GetLastErrorText` -> `SysErrorMessage(GetLastOSError)`.
- `GetEnv` -> `SysUtils.GetEnvironmentVariable` (cross-platform).
- `TempFilename` -> `SysUtils.GetTempFileName` (cross-platform).
- `FileSetReadOnly` / `DirectoryExists` / `IsDirectoryWriteable` ->
  rewritten on `FileGetAttr`/`FileSetAttr`/`FileCreate`/`FileClose`
  (cross-platform in `SysUtils`) instead of raw
  `GetFileAttributes`/`CreateFile`/Windows handles.
- `SetForegroundWindowEx` -> **stubbed to always return `true`** (was a
  Win32-version workaround for `SetForegroundWindow`/`AttachThreadInput`;
  confirmed unused anywhere else in the app, so this is currently inert,
  but flagging in case it's wired up later).
- `SHGetFolderPath` -> **repurposed**, no longer takes a real `CSIDL`;
  always returns `GetAppConfigDir(false)` (per-user config dir, e.g.
  `~/.config/<vendor>/<app>`). Only caller is `FormMainU.pas` (see below).
- `GetIPAddress` -> reimplemented with FPC's `Sockets`/`NetDB`
  (`ResolveHostByName` + `NetAddrToStr`) instead of `WinSock`.
- `TJH_Registry.SaveToFile` / `LoadFromFile` (export/import via
  `regedit.exe`) -> **stubbed to raise "not supported on this platform"**.
  Confirmed unused anywhere in the app currently. If ever wired up, needs
  a real design (there is no Windows-registry-file-format equivalent to
  export/import on Linux — `fcl-registry`'s backing file could maybe be
  copied directly instead).
- `ReRaiseExceptionWithStackDump` -> simplified to a plain re-raise; the
  JCL (`JclDebug`) stack-dump logic was removed (JCL isn't available for
  Lazarus, and this function is confirmed unused in the app).
- `OptimizeAnyGridColWidths` -> dropped the dead `TDBGrid` code path
  (no `TDBGrid`/`DB`/`DBGrids` usage exists anywhere in the app); now
  `TStringGrid`-only.
- `StartProcess` / `RunProcess` (raw `CreateProcess`/`TProcessInformation`)
  -> **removed entirely**. Confirmed unused anywhere in the app (the real
  process-launching code path is `common/AppControlU.pas`'s
  `StartApplication`, used by `FormMacro11SourceU.pas` to run
  `macro11.bat` — see "Not yet ported" below).
- `OutputDebugString` -> writes to stderr instead of the Win32 debug API.
  Used for real tracing in `ConsolePDP11SimHU.pas`.
- `GetFolder` (Windows `SHBrowseForFolder` folder picker) -> reimplemented
  using LCL's cross-platform `SelectDirectory` (Dialogs unit). Confirmed
  unused anywhere in the app currently.

## AuxU.pas

- Removed JVCL (`JvExGrids`/`JvStringGrid`) and `ShellApi`.
  `FormGridSaveColWidths`/`FormGridLoadColWidths` (both confirmed unused
  elsewhere) now take `TStringGrid`.
- `OpenTextFileInNotepad` (confirmed unused elsewhere) reimplemented via
  `LCLIntf.OpenDocument` — opens the file in whatever the OS default
  handler is, instead of hunting for `notepad.exe` under `%WINDIR%`.

## Known NOT-yet-ported (real Windows API usage found, work still ahead)

These files were confirmed via keyword scan to use *real* Win32 APIs
(beyond decorative `Windows` imports) and still need actual porting work,
not yet started as of this entry:

- **`CommU.pas`** — the actual RS-232 serial port layer:
  `CreateFile`/`ReadFile`/`WriteFile`/`SetCommState`/`GetCommState`/`DCB`/
  `EscapeCommFunction`/`PurgeComm`/`CloseHandle`. This is core
  hardware-communication code (talking to a real PDP-11 over serial) and
  needs a genuine Linux port (termios-based, or a cross-platform serial
  library). Not started.
- **`SerialXferU.pas`** — uses `WaitForSingleObject` (thread
  synchronization). Needs a cross-platform sync primitive.
- **`SerialIoHubU.pas`** — uses `QueryPerformanceCounter`-family timing
  and `Sleep`. Needs cross-platform high-res timing
  (`SerialIoHubU.indy.pas` is a dead alternate, not in the `.dpr` — ignore
  it).
- **`common/AppControlU.pas`** — process launching/control used by
  `FormMacro11SourceU.pas` to invoke `macro11.bat`/`m4.bat`: heavy Win32
  usage (`CloseHandle`, `GetCursorPos`, `SetCursorPos`, `SetWindowPos`,
  `keybd_event`, `ShellExecute`, `PostMessage`, `WaitForSingleObject`,
  `HWND`). Needs a `TProcess`-based rewrite. Also note: `macro11.bat` and
  `m4.bat` are Windows batch files — even after `AppControlU.pas` is
  ported, we'll need Linux shell-script equivalents (or confirm a Linux
  MACRO11 binary exists) for the assembler/M4 preprocessor to actually run.
- **`pdp1170panel/delphi/iowkit.pas`** and
  **`pdp1170panelImplementorPhysicalU.pas`** — bind to the Windows
  `iowkit.dll` (IO-Warrior USB HID library) for the real PDP-11/70 hardware
  front-panel. No Linux port exists; likely needs a libusb-based
  reimplementation, or this hardware-panel feature should be feature-gated
  out of the Linux build entirely (it's a niche feature — a simulated panel
  also exists in `FormPdp1170PanelU.pas`, need to check if that's
  independent of the hardware binding).

## Known correctness gap: hardcoded `\` path separators

`JH_Utilities.pas` (`CorrectPath`, `GetAbsolutePath`, `AssertPath`,
`GetUniqueFilename`, ...) and likely other files build file paths with a
literal `'\'` separator. On Linux this is just a regular filename
character (not a path separator), so this logic will misbehave for real
path construction (e.g. produce a single file literally named
`foo\bar.txt` instead of a `foo/bar.txt` path). Not yet addressed — needs
a systematic sweep replacing hardcoded `'\'` with `PathDelim` in
path-building code. Deferred because it's a correctness issue, not a
compile blocker, and touches a lot of code.

## `.dfm` -> `.lfm` conversion: not yet done

Forms currently still ship as Delphi `.dfm` (binary/text Delphi form
format). Compilation doesn't require this (the `{$R}` directive just
embeds whatever resource file exists), but Lazarus's own form designer and
possibly its default form-streaming expect `.lfm`. This needs checking
once the project actually links, and especially once we start testing
forms at runtime (the `.dfm` `object ... : TStringGrid` edits made for the
JVCL swap are a stopgap, not a real `.lfm` conversion).

## JVCL `TJvEditor` removed (-> SynEdit), 2026-07-22

`FormMacro11SourceU.pas`, `FormMacro11ListingU.pas`, `FormDisasU.pas` (the
MACRO-11 source editor, the compiler-listing viewer, and the disassembly
viewer) all used JVCL's `TJvEditor` as their source-code editing widget.
Swapped to Lazarus's bundled `SynEdit` package (`TSynEdit`), added as a
required package in `pdp11GUI.lpi`.

What carried over directly (same API on `TSynEdit`): `.Lines`, `.Clear`,
`.BeginUpdate`/`.EndUpdate`.

What was reimplemented:
- `LineInformations.SelectStyle[i] := lssDebugPoint/lssErrorPoint/
  lssUnselected` (JVCL's per-line background-color marking, used to
  highlight the current execution line / error line / PC line) ->
  replaced with `TSynEdit.OnSpecialLineColors` plus a small per-form
  `HighlightLine`/`HighlightLines` field tracking which line(s) are
  currently marked. Behavior preserved as closely as possible, including
  one quirk: `FormMacro11SourceU.setExecutionLine()` used
  `lssErrorPoint`(not `lssDebugPoint`) in the original code too (looks
  like a copy-paste bug), which was preserved rather than "fixed".
- `MakeRowVisible(n)` + `SetCaret(1,n)` -> `CaretX`/`CaretY` +
  `EnsureCursorPosVisible`.

What was **dropped** (no SynEdit equivalent attempted):
- Custom `OnPaintGutter` handlers (`EditorPaintGutter` in
  `FormMacro11SourceU.pas`, drew right-aligned line numbers; in
  `FormMacro11ListingU.pas`, additionally drew a `"PC>"` marker at the
  current PC line) — these relied on JvEditor internals (`TopRow`,
  `VisibleRowCount`, `CellRect`, `GutterWidth`) that don't exist on
  `TSynEdit`. Removed entirely; `TSynEdit` has its own built-in
  line-number gutter (`TSynGutterLineNumber`, on by default), so line
  numbers still show, but the `"PC>"` text marker in the gutter is gone —
  the PC line is still visually distinguished by its background color via
  `OnSpecialLineColors`, just without the text marker in the gutter.

## Third-party dependency stopgaps

- **Telnet (`OverbyteIcsTnCnx`/ICS)**: `SerialIoHubU.pas` used the
  "Overbyte ICS" (Internet Component Suite) `TTnCnx` Telnet client, not
  available for Lazarus. Replaced with a **local compat stub**
  (`Pdp11gui/OverbyteIcsTnCnx.pas`) implementing the same small API
  surface actually used (`Create`, `Name`, `TermType`, `host`, `port`,
  `OnDataAvailable`, `OnSessionConnected`, `OnDisplay`, `Connect`, `Close`,
  `SendStr`, `Free`) — but `Connect`/`SendStr` just **raise an exception**
  ("not yet ported"). This means: **Telnet connections (e.g. to a SimH
  simulator) do not work yet.** Serial/COM connections are unaffected.
  `OverbyteIcsWndControl` was dropped from the `uses` clause entirely —
  nothing in the app referenced any of its symbols directly (it was only
  an internal dependency of the real ICS `TTnCnx`).
  **Follow-up**: implement real Telnet over FPC's cross-platform `Sockets`/
  `NetDB` units (a background thread doing blocking reads + `TThread.
  Synchronize` to call `OnDataAvailable`, or a non-blocking socket polled
  from a `TTimer`, would both work — SimH's telnet console is fairly raw
  and likely doesn't need full option-negotiation to be usable).

- **`common/AppControlU.pas`** (used by `FormMacro11SourceU.pas` to launch
  `macro11.bat`): the original was a ~900-line Win32 GUI-automation engine
  (find a window by title/classname, simulate mouse clicks/moves and
  "human-like" keyboard typing via `keybd_event`/`mouse_event`/
  `SetCursorPos`/`PostMessage`/...). **Confirmed zero callers anywhere in
  the app** for all of that (`FindWindowByTitleOrClassname`, `MouseClick`,
  `MouseMove`, `humanMouseMove`, `humanMouseClick`, `KeyDown`, `KeyUp`,
  `EnterText`, `setWindowSize`, `setWindowPosition`,
  `ConnectTo*WindowByTitleOrClassname`, `ApplicationPath`,
  `ShowApplication`, ...) — only `Create`/`Destroy`/`StartApplication`/
  `ApplicationContact` are actually used (to launch `macro11.bat` and poll
  whether it's still running). **Rewrote the whole unit** to just those
  four, implemented for real (not stubbed) on FPC's cross-platform
  `Process` unit (`TProcess`). This is arguably *more correct* than the
  original: the original's `ApplicationContact` checked
  `GetWindowRect(AppMainWindowHandle, ...)`, but `AppMainWindowHandle` was
  never actually set anywhere in the app (nothing calls
  `ConnectToMainWindowByTitleOrClassname`), so on real Windows that check
  was effectively always `false` immediately — the new version uses
  `TProcess.Running`, which actually tracks the launched process.
  If the mouse/keyboard GUI-automation feature is ever wanted again on
  Linux, it needs a different foundation entirely (X11 has no equivalent
  to `keybd_event`/`SetCursorPos`; would need something like `xdotool` or
  an `libXtst` binding), not a port of the Win32 calls.

- **`FormAboutU.pas`**: used JCL's (JEDI Code Library) `TJclFileVersionInfo`
  to read Product Name/Version/Description/Copyright out of the .exe's
  Win32 `VERSIONINFO` resource. Linux ELF binaries have no equivalent
  concept, and the app doesn't track a version string anywhere else in the
  Pascal source (it's Windows-resource-only). Simplified the About box to
  show `Application.Title` and dropped the version/description/copyright
  fields that can't be read. **Follow-up**: if a real version string is
  wanted, it needs a source of truth added somewhere in the Pascal code
  (a constant, or a generated include file from the build).

## `CommU.pas` — real termios-based serial port (not a stub)

Unlike the stopgaps above, this one **was fully reimplemented**, not
stubbed, since it's small (~400 lines, one self-contained class) and is
arguably the single most important subsystem in the app (talking to real
PDP-11 hardware over RS-232). Rewritten on FPC's `BaseUnix`/`termio` units
instead of the Win32 COM-port API
(`CreateFile`/`ReadFile`/`WriteFile`/`SetCommState`/`GetCommState`/`DCB`/
`EscapeCommFunction`/`PurgeComm`/`ClearCommError`).

**Device naming caveat**: the rest of the app (`FormSettingsU.pas`'s
`ComportComboBox`) still presents a Windows-style `"COM1".."COM11"`
dropdown, stored as a 1-based integer (`TComm.Port`). Linux has no
`"COM1"` convention — real devices are paths like `/dev/ttyUSB0` (USB
serial adapter — the realistic way to hook up real PDP-11 hardware today)
or `/dev/ttyS0` (built-in serial port). `TComm.DeviceName` heuristically
maps `Port=N` to `/dev/ttyUSB<N-1>` if that device file exists, else
`/dev/ttyS<N-1>`. **Follow-up**: replace the settings UI's fixed
`"COM1".."COMn"` list with either a real enumeration of `/dev/tty*`
devices, or a free-text device-path field — the current numeric mapping
is a workable stopgap, not a good long-term UX.

Also note: `MARKPARITY`/`SPACEPARITY` (mark/space parity) are accepted by
the `Parity` property for API compatibility but are treated the same as
`NOPARITY` in `ApplyTermios` — Linux termios has no standard way to
express mark/space parity (this was already an obscure, rarely-used
feature; no caller in the app currently sets it).

## Still open / not yet reached

- `FormBusyU.pas` used old XE3-style qualified imports
  (`Winapi.Windows, Winapi.Messages, System.SysUtils, ...`) — fixed, same
  as the plain `Windows` case (import was entirely unused, just removed).
- Full first successful `lazbuild` compile not yet achieved — this file
  will be updated as new blockers are found and resolved.
