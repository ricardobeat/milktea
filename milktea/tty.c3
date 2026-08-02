module milktea;
import std::atomic;

faultdef TTY_GETATTR_FAILED, TTY_SETATTR_FAILED;

const int STDIN_FILENO  = 0;
const int STDOUT_FILENO = 1;
const int TCSANOW       = 0;
const short POLLIN      = 1;

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
extern fn int c3_get_winsize_px(int fd, ushort* xpx, ushort* ypx);
extern fn sz c3_time_ms();
extern fn sz c3_monotonic_ms();
extern fn double c3_sin(double x);
extern fn double c3_cos(double x);
extern fn int rand();
extern fn void srand(uint seed);
extern fn int c3_list_dir(char* path, char* names, int* is_dirs, int max_entries);
extern fn long c3_time_ms_long();
extern fn void* signal(int signum, void* handler);
extern fn char* getenv(char* name);
extern fn int raise(int signum);
extern fn int kill(int pid, int signum);
extern fn int getpid();

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
	if (c3_get_winsize_px(STDOUT_FILENO, &ws.ws_xpixel, &ws.ws_ypixel) != 0) {
		c3_get_winsize_px(STDIN_FILENO, &ws.ws_xpixel, &ws.ws_ypixel);
	}
	return ws;
}

// Atomic flag so the SIGWINCH handler (async signal context) and the event
// loop (main thread) can race without the optimizer caching a stale value.
// Relaxed ordering is sufficient: no other memory needs to be ordered around
// this flag, only the flag itself must be visible across threads/signals.
Atomic{bool} g_win_resized;

// g_saved_tty stores the pre-raw-mode terminal state so signal handlers can restore it.
TtyState g_saved_tty;
bool g_tty_saved = false;
// g_in_alt_screen lets the signal handler exit alt screen if needed.



bool* g_in_alt_screen_ptr = null;

const int SIGINT  = 2;
const int SIGTERM = 15;

fn void sigwinch_handler(int sig) {
	g_win_resized.store(true, RELAXED);
}

// fatal_signal_handler restores the terminal and re-raises the signal with default action.
fn void fatal_signal_handler(int sig) {
	// Restore TTY raw mode
	if (g_tty_saved) {
		tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_tty.termios_buf[0]);
	}
	// Exit alt screen if active
	if (g_in_alt_screen_ptr != null && *g_in_alt_screen_ptr) {
		// write alt-screen-off and show-cursor directly (avoid calling render fns)
		char[] alt_off = (char[])"\x1b[?1049l\x1b[?25h";
		sz written     = 0;
		while (written < alt_off.len) {
			sz n = write(STDOUT_FILENO, &alt_off[written], alt_off.len - written);
			if (n <= 0) break;
			written += n;
		}
	} else {
		// Inline mode: show cursor
		char[] show = (char[])"\x1b[?25h";
		write(STDOUT_FILENO, &show[0], show.len);
	}
	// Reset signal to default and re-raise so the process exits with correct status
	signal(sig, null);
	raise(sig);
}

fn void setup_signals(TtyState saved, bool* in_alt_screen) {
	g_saved_tty = saved;
	g_tty_saved = true;
	g_in_alt_screen_ptr = in_alt_screen;
	signal(SIGWINCH, &sigwinch_handler);
	signal(SIGINT, &fatal_signal_handler);
	signal(SIGTERM, &fatal_signal_handler);
}

// teardown_signals restores the default disposition for every signal
// setup_signals installed and drops the pointer into the Program frame.
//
// Program is a stack local in every entry point (run, @run, @run_program), so
// leaving the handlers installed after run() returns leaves
// g_in_alt_screen_ptr aimed at a reclaimed frame — a later SIGINT would read
// whatever now occupies that slot. Sequential Program runs are supported, so
// this is a reachable path, not just a shutdown nicety.
fn void teardown_signals() {
	signal(SIGWINCH, null);
	signal(SIGINT, null);
	signal(SIGTERM, null);
	g_in_alt_screen_ptr = null;
	g_tty_saved = false;
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

// time_ms returns monotonic milliseconds — the basis for every timer deadline
// and hold window in the event loop. It must not move when the system clock
// does: an NTP or DST step backwards would stall every armed timer for the
// length of the step, and a step forwards would fire them all at once.
fn sz time_ms() {
	return (sz)c3_monotonic_ms();
}

// wall_time_ms returns milliseconds since the Unix epoch. Used only by
// every(), which deliberately snaps its deadline to calendar boundaries so a
// 1s display ticks exactly on :00.
fn sz wall_time_ms() {
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