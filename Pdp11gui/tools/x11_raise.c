/* Companion to x11_click.c: raises and focuses an X11 window by ID, so
 * screenshots/clicks land on the app window instead of whatever else is on
 * top (e.g. the terminal running the test session). Window IDs come from
 * `xwininfo -root -tree`.
 *
 * Build: gcc -o x11_raise x11_raise.c -lX11
 * Usage: DISPLAY=:0 ./x11_raise <window-id-hex-or-dec>
 */
#include <X11/Xlib.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    Window w = strtoul(argv[1], NULL, 0);
    XMapRaised(d, w);
    XRaiseWindow(d, w);
    XSetInputFocus(d, w, RevertToParent, CurrentTime);
    XFlush(d);
    XCloseDisplay(d);
    return 0;
}
