#!/bin/sh
# Launcher for pdp11GUI that forces correct HiDPI scaling on Linux.
#
# Background: the app is built against Lazarus's Qt5 widgetset (LCL's GTK2
# widgetset has no HiDPI support at all, and its GTK3 widgetset is alpha
# quality and crashes on startup - see LINUX_PORT_TODO.md). Qt5 scales
# correctly, but only if told the scale factor explicitly: neither its
# Wayland auto-detection nor its X11/Xft.dpi auto-detection reliably picked
# up this display's 200% setting during testing, so we compute it from
# Xft.dpi (set by the desktop to 96 * scale%) and pass it in ourselves.
cd "$(dirname "$0")"

dpi=$(xrdb -query 2>/dev/null | awk '/Xft\.dpi:/{print $2}')
if [ -n "$dpi" ]; then
    scale=$(awk -v dpi="$dpi" 'BEGIN{printf "%.2f", dpi/96}')
else
    scale=1
fi

export QT_QPA_PLATFORM=xcb
export QT_SCALE_FACTOR="$scale"

# Popup menus (QMenu) resolve their font from the logical font DPI, which
# already reflects the real Xft.dpi (192 = 200%), and then get
# QT_SCALE_FACTOR applied on top of that when rasterized - double-scaling
# just the dropdown text while leaving the menu bar and other LCL-drawn
# widgets (which use an explicit pixel-sized font, scaled only once)
# correctly sized. Pinning the font DPI to the unscaled 96 baseline makes
# QT_SCALE_FACTOR the only source of scaling, so popups end up sized to
# match everything else instead of coming out roughly 2x too large.
export QT_FONT_DPI=96

exec ./pdp11GUI "$@"
