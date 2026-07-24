# Changes

This file tracks notable new functionality added to pdp11gui. See `CLAUDE.md` for the rule that keeps it up to date.

## 2026-07-24

- **"SimH direct" connection.** A new console connection type, selectable in the settings dialog as "SimH direct (pdp11gui launches SimH)". Instead of requiring the user to start `open-simh` by hand and configure its remote console, pdp11gui now launches the `pdp11` executable itself (found on `PATH`) using a generated copy of the chosen `.ini` file, and connects to it over two telnet links: one to SimH's "remote console" (the `sim>` command interface used for examine/deposit/run/reset) and one to the emulated PDP-11's own serial console. See `ConsolePDP11SimHU.pas` and `SerialIoHubU.Physical_InitForSimhProcess`.
