#!/bin/sh
# Full build for pdp11GUI on Linux.
#
# Must use the Qt5 widgetset explicitly - plain `lazbuild pdp11GUI.lpi`
# defaults to GTK2, which has no HiDPI support (see LINUX_PORT_TODO.md).
# Requires libqt5pas1 and libqt5pas-dev (apt-get install libqt5pas1
# libqt5pas-dev).
set -e

cd "$(dirname "$0")/Pdp11gui"

lazbuild --ws=qt5 pdp11GUI.lpi

echo "Build succeeded: $(pwd)/pdp11GUI"
