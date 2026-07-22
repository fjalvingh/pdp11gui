# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PDP11GUI is a Lazarus/Free Pascal GUI application (targeting MS Windows) that serves as an IDE for PDP-11 computers. It communicates with real PDP-11 hardware over RS-232, with SimH simulators over Telnet, or with built-in software simulations, and provides tools for assembly, memory inspection, disassembly, and disk image I/O.

## Build System

- **IDE:** Lazarus (Free Pascal Compiler)
- **Project file:** `pdp11GUI.lpi` (open this in Lazarus to build)
- **Main program:** `pdp11GUI.dpr`
- **Unit output:** `lib/$(TargetCPU)-$(TargetOS)/`
- **Build:** Open `pdp11GUI.lpi` in Lazarus and use Build/Compile menu; there is no standalone CLI build script.
- **External tools at runtime:** `macro11.bat` (invokes MACRO11.exe assembler), `m4.bat` (M4 preprocessor for driver templates)

## Linux/Qt5 HiDPI Notes

The app must be built with the Qt5 widgetset (`lazbuild --ws=qt5 pdp11GUI.lpi`) — GTK2 (lazbuild's default) has no HiDPI support at all, and GTK3 crashes on startup. Run via `run.sh`, which computes `QT_SCALE_FACTOR` from the desktop's `Xft.dpi` and also sets `QT_FONT_DPI=96`.

`QT_FONT_DPI=96` works around a Qt5/X11 double-scaling bug: popup menus (`TMenuItem` dropdowns, rendered as native `QMenu` windows) resolve their font from the logical font DPI, which already reflects the real `Xft.dpi` (e.g. 192 at 200% scaling), and then get `QT_SCALE_FACTOR` applied again on top when rasterized — roughly doubling just the dropdown text. The menu bar and other LCL-drawn widgets use an explicit pixel-sized font that only scales once, so only dropdowns were affected. Pinning the font DPI to the unscaled 96 baseline makes `QT_SCALE_FACTOR` the sole source of scaling.

For headless UI testing (screenshots, driving menus) on a box without `xdotool`/`wmctrl`/`xte` and no network access to install them, use `tools/x11_click.c` (move + click via XTest) and `tools/x11_raise.c` (raise/focus a window by ID from `xwininfo -root -tree`). Build with `gcc -o x11_click tools/x11_click.c -lX11 -lXtst` (needs `libxtst-dev`, usually already present).

## Architecture

The application is a Lazarus MDI (Multi-Document Interface) application. `FormMainU.pas` is the MDI parent that manages all tool windows.

### Layered Structure

**Communication / Console Layer**
- `SerialIoHubU` — central hub routing I/O between the serial/Telnet connection and higher layers
- `CommU` — low-level COM port wrapper
- `ConsoleGenericU` — abstract base class defining the console interface (`Examine`, `Deposit`, `Run`, `SingleStep`, `Reset`)
- Concrete console implementations follow the naming pattern `ConsolePDP11*U.pas`:
  - `ConsolePDP1144U` / `ConsolePDP1144v340cU` — real PDP-11/44 over RS-232
  - `ConsolePDP11ODTU` — ODT protocol for 11/23, 11/73, 11/93
  - `ConsolePDP11M9301U` / `ConsolePDP11M9312U` — M9301/M9312 boot ROM consoles
  - `ConsolePDP11SimHU` — SimH simulator over Telnet
  - `ConsolePDP11ODTK1630U` — Robotron K1630 variant
- Each real console has a parallel `Fake*` unit (e.g. `ConsolePDP1144FakeU`) for offline testing without hardware.

**Address & Memory Model**
- `AddressU` — unified address type covering 16-bit virtual, 18-bit physical, 22-bit physical, and special registers; handles automatic width conversion
- `MemoryCellU` — `TMemoryCell` (single address+value) and `TMemoryCellGroup` (collection); implements a publish-subscribe notification so all open tool windows stay synchronized when any window modifies memory. This avoids redundant Examine commands over slow serial lines.
- `Pdp11MmuU` — MMU simulation for virtual→physical address translation (kernel/user modes); its PAR/PDR registers are stored in their own `TMemoryCellGroup`
- `BitFieldU` — named bit-field representation for register inspection

**Tool Windows (MDI children)**
All inherit from `FormChildU`. Created/shown from `FormMainU` menus:
- `FormTerminalU` — raw serial I/O display
- `FormMacro11SourceU`, `FormMacro11ListingU`, `FormMacro11CodeU` — MACRO-11 assembler IDE
- `FormMemoryListU`, `FormMemoryTableU` — memory display (kept in sync via `MemoryCellGroup` notifications)
- `FormMemoryLoaderU`, `FormMemoryDumperU` — load/dump memory in various formats (octal pairs, absolute paper tape, Intel HEX)
- `FormMemoryTestU` — stuck-bit, addressing, and pattern memory tests
- `FormBitfieldsU` — live bit-field/register inspector
- `FormMmuU` — MMU virtual→physical translation viewer
- `FormDisasU` — disassembler (delegates opcode decoding to `pdp11disas.dll`)
- `FormDiscImageU` — disk image read/write (RL02, RX02, RM02, RK06/07, MSCP, etc.)
- `FormPdp1170PanelU` — simulated PDP-11/70 hardware console panel
- `FormExecuteU`, `FormExecuteBlinkenlightU` — run/step/reset execution control
- `FormIoPageScannerU` — UNIBUS I/O page device scanning
- `FormMicroCodeU` — PDP-11/44 microcode viewer
- `FormNumberconverterU` — radix conversion utility

**Settings & Persistence**
- `RegistryU` — all application state (window positions, serial settings, machine type) is stored in the Windows Registry
- `FormSettingsU` — configuration dialog

**External modules (relative paths)**
- `../common/` — shared utilities (`AppControlU.pas`, `JH_Utilities.pas`)
- `../PDP1170Panel/delphi/` — PDP-11/70 panel simulation with IO-Warrior USB binding (`iowkit.pas`)

### PDP-11 Driver Sources

`/driver/` contains MACRO-11 assembly source for device drivers that get compiled and loaded into PDP-11 memory at runtime:
- `pdp11gui_rl11.mac` — RL02 disk controller
- `pdp11gui_rx11.mac` — RX02 floppy controller
- `pdp11gui_mscp.mac` — MSCP mass storage
- `pdp11gui_serialio_dl11.mac` — DL11 serial interface

## Key Conventions

- **Octal throughout:** All addresses and memory values follow PDP-11 convention (octal). Use `OctalConst.pas` for constants; all user-facing I/O is in octal.
- **Unit naming:** `*U.pas` suffix on unit files (e.g. `FormMainU.pas`, `ConsoleGenericU.pas`).
- **Fake consoles for testing:** Develop/test console logic using the `Fake*` units to avoid needing real hardware.
- **Memory change propagation:** When modifying a `TMemoryCell`, call `SyncMemoryCells()` on the owning `TMemoryCellGroup` so all subscribed windows update — do not manually refresh individual windows.
- **Console protocol parsing:** Each console implementation contains a scanner (e.g. `TConsolePDP1144Scanner`) that parses the console's text output (prompts, examine/deposit responses). When adding a new console variant, follow this scanner pattern.
