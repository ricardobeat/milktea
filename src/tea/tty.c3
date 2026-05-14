module tea;

faultdef TTY_GETATTR_FAILED, TTY_SETATTR_FAILED;

const int STDIN_FILENO = 0;
const int STDOUT_FILENO = 1;
const int TCSANOW = 0;
const short POLLIN = 1;

// TIOCGWINSZ is provided by <sys/ioctl.h> in tty_winsize.c — not needed here.
// SIGWINCH is 28 on both macOS and Linux.
const int SIGWINCH = 28;

extern fn int tcgetattr(int fd, char* termios_buf);
extern fn int tcsetattr(int fd, int flags, char* termios_buf);
extern fn int cfmakeraw(char* termios_buf);
extern fn int poll(void* fds, ulong nfds, int timeout);
extern fn sz read(int fd, void* buf, sz nbytes);
extern fn sz write(int fd, void* buf, sz nbytes);
extern fn int c3_get_winsize(int fd, ushort* row, ushort* col);
extern fn sz c3_time_ms();
extern fn double c3_sin(double x);
extern fn double c3_cos(double x);
extern fn int rand();
extern fn void srand(uint seed);
extern fn int c3_list_dir(char* path, char* names, int* is_dirs, int max_entries);
extern fn long c3_time_ms_long();
extern fn void* signal(int signum, void* handler);

struct TtyState {
    char[256] termios_buf;
}

struct PollFd {
    int fd;
    short events;
    short revents;
}

struct WinSize {
    ushort ws_row;
    ushort ws_col;
    ushort ws_xpixel;
    ushort ws_ypixel;
}

fn WinSize get_window_size() {
    WinSize ws;
    // Try stdout first, then stdin
    if (c3_get_winsize(STDOUT_FILENO, &ws.ws_row, &ws.ws_col) != 0) {
        c3_get_winsize(STDIN_FILENO, &ws.ws_row, &ws.ws_col);
    }
    return ws;
}

bool g_win_resized = false;

fn void sigwinch_handler(int sig) {
    g_win_resized = true;
}

fn void setup_sigwinch() {
    signal(SIGWINCH, &sigwinch_handler);
}

fn TtyState? raw_mode_enter() {
    TtyState saved;

    if (tcgetattr(STDIN_FILENO, &saved.termios_buf[0]) < 0) {
        return TTY_GETATTR_FAILED~;
    }

    char[256] raw = saved.termios_buf;
    cfmakeraw(&raw[0]);

    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw[0]) < 0) {
        return TTY_SETATTR_FAILED~;
    }

    return saved;
}

fn void raw_mode_restore(TtyState saved) {
    tcsetattr(STDIN_FILENO, TCSANOW, &saved.termios_buf[0]);
}

fn sz time_ms() {
    return (sz)c3_time_ms();
}

fn sz read_stdin_timeout(char[] buf, int timeout_ms) {
    if (buf.len == 0) return 0;

    PollFd pfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    pfd.revents = 0;

    int poll_result = poll(&pfd, 1, timeout_ms);
    if (poll_result <= 0) return 0;

    sz n = read(STDIN_FILENO, &buf[0], buf.len);
    if (n < 0) return 0;
    return n;
}

fn sz read_stdin(char[] buf) {
    return read_stdin_timeout(buf, 50);
}

fn void write_stdout(char[] bytes) {
    sz written = 0;
    while (written < bytes.len) {
        sz n = write(STDOUT_FILENO, &bytes[written], bytes.len - written);
        if (n <= 0) break;
        written += n;
    }
}
