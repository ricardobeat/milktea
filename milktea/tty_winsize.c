#include <sys/ioctl.h>

int c3_get_winsize(int fd, unsigned short *row, unsigned short *col) {
    struct winsize ws;
    int result = ioctl(fd, TIOCGWINSZ, &ws);
    if (result == 0) {
        *row = ws.ws_row;
        *col = ws.ws_col;
    }
    return result;
}

int c3_get_winsize_px(int fd, unsigned short *xpx, unsigned short *ypx) {
    struct winsize ws;
    int result = ioctl(fd, TIOCGWINSZ, &ws);
    if (result == 0) {
        *xpx = ws.ws_xpixel;
        *ypx = ws.ws_ypixel;
    }
    return result;
}
