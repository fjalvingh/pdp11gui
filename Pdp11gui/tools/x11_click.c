/* Minimal X11 mouse-move-and-click helper, for driving the app's UI during
 * headless/screenshot-based testing when xdotool/wmctrl/xte aren't
 * installed and can't be (no network access to apt). Uses XTest, which only
 * needs libxtst-dev.
 *
 * Build: gcc -o x11_click x11_click.c -lX11 -lXtst
 * Usage: DISPLAY=:0 ./x11_click <x> <y>   (root-window absolute coordinates)
 */
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    int x = atoi(argv[1]);
    int y = atoi(argv[2]);
    XTestFakeMotionEvent(d, -1, x, y, 0);
    XFlush(d);
    usleep(200000);
    XTestFakeButtonEvent(d, 1, True, 0);
    XFlush(d);
    usleep(80000);
    XTestFakeButtonEvent(d, 1, False, 0);
    XFlush(d);
    XCloseDisplay(d);
    return 0;
}
