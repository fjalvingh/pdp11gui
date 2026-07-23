# PDP11GUI
PDP11GUI is an integrated development environment (IDE) for PDP-11’s, running under MS Windows.

You can write programms in assembler and load them onto the PDP-11, run programs or single step them, disassemble code, load, dump and display memory and inspect registers.

See the [PDP11GUII home page](http://www.retrocmp.com/tools/pdp11gui) for documentation and a tutorial.

## Linux build

PDP11GUI has been ported from Delphi/VCL to Lazarus/Free Pascal so it can
be built and run on Linux. See `LINUX_PORT_TODO.md` for background on the
port and known gaps.

### Install Lazarus

```
sudo apt-get install lazarus
```

This pulls in the Free Pascal compiler (`fpc`) as a dependency, so no
separate install step is needed for it.

### Install the Qt5 widgetset dependencies

The app is built against Lazarus's Qt5 widgetset, not the default GTK2
one, because GTK2 has no HiDPI support (see `LINUX_PORT_TODO.md` for
details):

```
sudo apt-get install libqt5pas1 libqt5pas-dev
```

### Build

Run the build script from the project root:

```
./build.sh
```

This invokes `lazbuild --ws=qt5 Pdp11gui/pdp11GUI.lpi` and produces the
`pdp11GUI` executable in the `Pdp11gui/` directory.

### Run

Don't run `Pdp11gui/pdp11GUI` directly. Use the launcher script instead:

```
./Pdp11gui/run.sh
```

`run.sh` computes the correct Qt scale factor from the desktop's DPI
setting and exports it before starting the app, which `pdp11GUI` itself
does not do — running the binary directly can result in incorrect HiDPI
scaling.

