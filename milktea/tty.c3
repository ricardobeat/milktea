module milktea;
import std::atomic;

faultdef TTY_GETATTR_FAILED, TTY_SETATTR_FAILED, ALT_SCREEN_ALREADY_ENTERED;

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
	// Pixel size of one character cell. Sourced from the CSI 16 t / OSC 1337
	// probe (see probe_terminal_caps) and kept up to date by runtime replies;
	// 0 + cell_px_known == false means the terminal never answered.
	ushort cell_w_px;
	ushort cell_h_px;
	bool cell_px_known;
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
	ws.cell_w_px = (ushort)g_cell_w_px;
	ws.cell_h_px = (ushort)g_cell_h_px;
	ws.cell_px_known = g_cell_px_known;
	return ws;
}

// ---- Terminal capability replies ----
//
// Modern terminals answer queries on stdin mixed in with key events:
//   CSI 16 t          -> CSI 6 ; <height> ; <width> t   (cell size in pixels,
//                        height first, matching xterm's XTWINOPS order)
//   OSC 1337 ReportCellSize -> OSC 1337 ; ReportCellSize=<height> ; <width>
//                        (iTerm2 only — its CSI 16 t handler is unimplemented)
//   APC ESC_G ...     -> kitty graphics protocol replies (a=q capability probe)
//
// probe_terminal_caps sends all three queries before the reader thread starts
// and collects the answers synchronously; runtime CSI 16 t replies are routed
// through report_cell_size_reply by the key parser (input.c3).
//
// tmux caveat: tmux (>= 3.3) intercepts CSI 16 t and answers from its own pane
// geometry, which is close but not always exact. GNU Screen does not answer
// at all. Exact outer-terminal values need DCS passthrough, which is not
// attempted here.

int g_cell_w_px = 0;
int g_cell_h_px = 0;
bool g_cell_px_known = false;
bool g_tgp_replied = false;

// How long probe_terminal_caps waits for replies before giving up. Terminals
// that support none of the queries (alacritty, GNU Screen) pay this cost at
// startup; keep it small.
const sz PROBE_TIMEOUT_MS = 150;

fn void report_cell_size_reply(int height, int width) {
	if (height <= 0 || width <= 0) return;
	g_cell_h_px = height;
	g_cell_w_px = width;
	g_cell_px_known = true;
}

fn void report_tgp_reply() {
	g_tgp_replied = true;
}

fn bool is_csi_final(char c) @local {
	return c >= 0x40 && c <= 0x7e;
}

// handle_probe_reply inspects one CSI reply body (bytes between "ESC [" and
// the final byte). Only XTWINOPS cell-size reports (param 6) are interpreted.
fn void handle_probe_csi(char[] body) @local {
	int[8] params;
	int count = 0;
	int value = 0;
	bool have = false;
	foreach (c : body) {
		if (c >= '0' && c <= '9') {
			value = value * 10 + (c - '0');
			have = true;
		} else if (c == ';') {
			if (count < 8) params[count++] = have ? value : 0;
			value = 0;
			have = false;
		}
		// private prefixes / intermediates (", ? etc.) are not expected in replies
	}
	if (have && count < 8) params[count++] = value;
	if (count >= 3 && params[0] == 6) {
		report_cell_size_reply(params[1], params[2]);
	}
}

// handle_probe_string inspects one OSC/APC body. For OSC 1337 it parses
// iTerm2's ReportCellSize=<height>;<width>; for APC ESC_G it records that the
// terminal speaks the kitty graphics protocol (the a=q probe is answered with
// OK or ERR — either way the protocol is implemented).
fn void handle_probe_string(bool is_osc, char[] body) @local {
	if (is_osc) {
		String prefix = (String)"1337;ReportCellSize=";
		if (body.len <= prefix.len) return;
		// Prefix match on the raw bytes.
		for (sz i = 0; i < prefix.len; i++) {
			if (body[i] != prefix[i]) return;
		}
		char[] rest = body[prefix.len..];
		// Format: <height>;<width>  (height first, like XTWINOPS 16)
		int[2] vals = { 0, 0 };
		int idx = 0;
		foreach (c : rest) {
			if (c >= '0' && c <= '9') {
				vals[idx] = vals[idx] * 10 + (c - '0');
			} else if (c == ';' && idx == 0) {
				idx = 1;
			} else {
				return; // unexpected payload — don't guess
			}
		}
		report_cell_size_reply(vals[0], vals[1]);
	} else {
		// APC (ESC G ...): kitty graphics protocol reply.
		if (body.len > 0 && body[0] == 'G') report_tgp_reply();
	}
}

// parse_probe_replies consumes complete escape-sequence replies from the front
// of buf and returns the number of bytes consumed. Noise bytes (e.g. keys the
// user typed during the probe) are skipped; an incomplete trailing sequence is
// left in the buffer for the next round or returned to the input stream.
fn sz parse_probe_replies(char[] buf) @local {
	sz pos = 0;
	while (pos < buf.len) {
		if (buf[pos] != 0x1b) {
			pos++;
			continue;
		}
		if (pos + 1 >= buf.len) break; // lone ESC at the end — wait for more
		char second = buf[pos + 1];
		if (second == '[') {
			sz i = pos + 2;
			while (i < buf.len && !is_csi_final(buf[i])) i++;
			if (i >= buf.len) break; // incomplete
			handle_probe_csi(buf[pos + 2..i]);
			pos = i + 1;
		} else if (second == ']' || second == '_') {
			// OSC/APC: terminated by BEL (0x07) or ST (ESC \)
			sz i = pos + 2;
			while (i + 1 < buf.len && buf[i] != 0x07 && !(buf[i] == 0x1b && buf[i + 1] == '\\')) i++;
			if (i + 1 >= buf.len && buf[i] != 0x07) break; // incomplete
			sz next = (buf[i] == 0x07) ? i + 1 : i + 2;
			// C3 ranges are end-inclusive: [pos+2 .. i-1] excludes the terminator.
			if (i > pos + 2) {
				handle_probe_string(second == ']', buf[pos + 2..i - 1]);
			}
			pos = next;
		} else {
			pos += 2; // two-byte escape we don't care about
		}
	}
	return pos;
}

// probe_terminal_caps sends the cell-size and kitty-graphics queries and
// collects replies with a bounded wait. Must run before the reader thread is
// started (it reads stdin directly). Any bytes that are not part of a reply
// — keystrokes typed during the probe, trailing incomplete sequences — are
// copied to leftover (up to its length) so the event loop can process them
// like any other input; the return value is the number of bytes copied.
fn sz probe_terminal_caps(char[] leftover) {
	write_stdout((char[])"\x1b[16t");
	write_stdout((char[])"\x1b]1337;ReportCellSize\x07");
	// Kitty graphics capability probe: a=q with a 1x1 pixel RGB payload id 31.
	// Supported terminals answer APC ESC_Gi=31;... (OK or ERR); unsupported
	// ones stay silent. The payload matters: Ghostty only replies when the
	// query completes an image load, so a data-less query is ignored there.
	write_stdout((char[])"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");

	char[256] acc;
	sz len = 0;
	sz deadline = time_ms() + PROBE_TIMEOUT_MS;
	while (time_ms() < deadline) {
		if (g_cell_px_known && g_tgp_replied) break;
		char[128] chunk;
		sz n = read_stdin_timeout(chunk[..], 30);
		if (n > 0) {
			for (sz i = 0; i < n && len < acc.len; i++) {
				acc[len++] = chunk[i];
			}
		}
		// C3 slice ranges are end-inclusive, so acc[..len] would hand parse one
		// byte of stack garbage past the data; consumed then exceeds len and the
		// unsigned len underflows, wedging the probe. Use start:length instead.
		sz consumed = parse_probe_replies(acc[0:len]);
		if (consumed > 0) {
			for (sz i = consumed; i < len; i++) {
				acc[i - consumed] = acc[i];
			}
			len -= consumed;
		}
	}
	sz out = 0;
	for (sz i = 0; i < len && out < leftover.len; i++) {
		leftover[out++] = acc[i];
	}
	return out;
}

// ---- Exit cleanup hook ----
//
// Modules that own terminal-only state (e.g. placed kitty-graphics images)
// register a cleanup callback; it runs on abnormal exit (fatal signals) and
// during normal program teardown. Handlers run in signal context: they must
// only call write() with prebuilt constant strings — no formatting, no
// allocation.
alias CleanupFn = fn void();

CleanupFn g_cleanup_fn = null;

fn void register_cleanup(CleanupFn f) {
	g_cleanup_fn = f;
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
	// Drop graphics state first, while the alt screen (if any) is still up —
	// avoids flashing tiles onto the restored normal screen.
	if (g_cleanup_fn != null) g_cleanup_fn();
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
// Regression tests for the startup probe's reply parser: the whole reply and
// a reply split across two reads must both be recognized. Globals are saved
// and restored so the tests never leak state into other tests.
fn void test_probe_parse_whole_reply() @test {
	bool saved_cell = g_cell_px_known;
	bool saved_kgp = g_tgp_replied;
	g_cell_px_known = false;
	g_tgp_replied = false;
	defer {
		g_cell_px_known = saved_cell;
		g_tgp_replied = saved_kgp;
	}

	char[256] acc;
	sz len = 0;
	char[] seq = "\x1b[6;20;10t\x1b]1337;ReportCellSize=20;10\x07\x1b_Gi=31;OK\x1b\\";
	foreach (b : seq) acc[len++] = b;
	parse_probe_replies(acc[0:len]);
	assert(g_cell_px_known);
	assert(g_tgp_replied);
}

fn void test_probe_parse_split_reply() @test {
	bool saved_cell = g_cell_px_known;
	bool saved_kgp = g_tgp_replied;
	g_cell_px_known = false;
	g_tgp_replied = false;
	defer {
		g_cell_px_known = saved_cell;
		g_tgp_replied = saved_kgp;
	}

	char[256] acc;
	sz len = 0;
	char[] part1 = "\x1b[6;20;10t\x1b]1337;ReportCellSize=20;10\x07\x1b_Gi=31;O";
	foreach (b : part1) acc[len++] = b;
	sz consumed = parse_probe_replies(acc[0:len]);
	sz keep = len - consumed;
	for (sz j = 0; j < keep; j++) acc[j] = acc[consumed + j];
	len = keep;
	char[] part2 = "K\x1b\\";
	foreach (b : part2) acc[len++] = b;
	parse_probe_replies(acc[0:len]);
	assert(g_tgp_replied);
}
