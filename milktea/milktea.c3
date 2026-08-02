module milktea;

import std::core::dstring;
import std::core::mem;
import std::core::mem::allocators;
import std::thread;
import std::atomic;
import std::time;
import std::io;
import xray;

// Cursor shapes (matches Go tea.CursorShape constants)
enum CursorShape : int {
	CURSOR_BLOCK,
	CURSOR_UNDERLINE,
	CURSOR_BAR,
}

// Mouse mode — controls whether the terminal sends mouse events.
enum MouseMode : int {
	MOUSE_MODE_NONE,
	MOUSE_MODE_CELL_MOTION,
	MOUSE_MODE_ALL_MOTION,
}

// Cursor represents a cursor on the terminal screen.
// x, y are 0-indexed relative to the top-left corner of the View content.
// color is an optional hex color string (e.g. "#ff6600"). Empty = terminal default.
struct Cursor {
	int x;
	int y;
	CursorShape shape;
	bool blink;
	String color;
}

struct Overlay {
	String content;
	int x;
	int y;
	int w;
	int h;
	bool transparent;
	char alpha; // 0 = opaque (default), 1-254 = blended
	xray::LayerStyle layer_style;
}

const int MAX_OVERLAYS = 8;

struct View {
	String content;
	Cursor cursor;
	bool has_cursor;
	bool alt_screen;
	MouseMode mouse_mode;
	xray::Cell[] cells;
	sz cells_width;
	sz cells_height;
	String mouse_cursor;
	Overlay[MAX_OVERLAYS] overlays;
	int overlay_count;
	bool report_key_events;
	bool mouse_pixels;
}

// new_view creates a View with the given content and default settings (no cursor, no alt screen).
fn View new_view(String content) {
	return { .content = content };
}

// new_alt_screen_view creates a View with alt screen enabled.
fn View new_alt_screen_view(String content) {
	return { .content = content, .alt_screen = true };
}

// new_alt_cell_view creates an alt-screen View backed by a direct cell grid.
fn View new_alt_cell_view(xray::Cell[] cells, sz width, sz height) {
	return { .cells = cells, .cells_width = width, .cells_height = height, .alt_screen = true };
}

// new_cursor creates a Cursor at the given position with default shape (blinking block).
fn Cursor new_cursor(int x, int y) {
	return { .x = x, .y = y, .shape = CursorShape.CURSOR_BLOCK, .blink = true };
}

// View builder methods — enable fluent declarative View construction.
// Example: return new_view("hello").set_cursor(5, 3).set_alt_screen(true);

fn View View.set_cursor(self, int x, int y) {
	View v = self;
	v.has_cursor = true;
	v.cursor = new_cursor(x, y);
	return v;
}

fn View View.set_cursor_shape(self, int x, int y, CursorShape shape, bool blink) {
	View v = self;
	v.has_cursor = true;
	v.cursor = { .x = x, .y = y, .shape = shape, .blink = blink };
	return v;
}

fn View View.set_cursor_color(self, String color) {
	View v = self;
	v.cursor.color = color;
	return v;
}

fn View View.set_alt_screen(self, bool on) {
	View v = self;
	v.alt_screen = on;
	return v;
}

fn View View.set_mouse_cursor(self, String name) {
	View v = self;
	v.mouse_cursor = name;
	return v;
}

fn View View.set_mouse_mode(self, MouseMode mode) {
	View v = self;
	v.mouse_mode = mode;
	return v;
}

// set_report_key_events opts in to the kitty keyboard protocol's key-release
// and key-repeat reporting (progressive enhancement flag 2). When enabled,
// KeyMsg.action carries KEY_PRESS / KEY_REPEAT / KEY_RELEASE; terminals that
// don't support the kitty protocol are unaffected (the extra push/pop is
// silently ignored, same as the base kitty keyboard layer). Apps that never
// call this see byte-identical KeyMsg.action == KEY_PRESS behavior to before
// this option existed.
fn View View.set_report_key_events(self, bool on) {
	View v = self;
	v.report_key_events = on;
	return v;
}

// set_mouse_pixels opts in to DEC mode 1016 (SGR-Pixels mouse reporting).
// When enabled (and mouse_mode is not MOUSE_MODE_NONE), the terminal reports
// mouse coordinates in pixels relative to the terminal window in addition to
// cell coordinates; MouseMsg.px/py carry the raw 0-based pixel values while
// row/col continue to carry the cell position (converted from pixels using
// the terminal's reported window/cell size). Terminals that don't support
// mode 1016 simply ignore it and continue sending cell coordinates — in that
// case px/py stay 0 and row/col behave exactly as before this option existed.
fn View View.set_mouse_pixels(self, bool on) {
	View v = self;
	v.mouse_pixels = on;
	return v;
}

// add_overlay attaches a floating overlay to the view.
// Overlays are rendered in insertion order, up to MAX_OVERLAYS (8) total.
// Any call beyond MAX_OVERLAYS is silently ignored — callers that need more
// overlays must merge content before adding.
//
// transparent: when true, blit_ansi skips cells whose content is a space with
//   default style, letting the background show through instead of overwriting it.
//   Use for overlays whose content is sparse or irregularly shaped.
//
// layer_style: configures drop-shadow and inner-shadow effects rendered around
//   the overlay. The drop-shadow is composited under the overlay content;
//   the inner-shadow is composited on top (inside the overlay bounds).
//   Both fields default to disabled (zero-value LayerStyle).
fn View View.add_overlay(self, int x, int y, int w, int h, String content, char alpha = 0,
	bool transparent = false, xray::LayerStyle layer_style = {})
{
	View v = self;
	if (v.overlay_count < MAX_OVERLAYS) {
		v.overlays[v.overlay_count] = {
			.content = content,
			.x = x, .y = y, .w = w, .h = h,
			.alpha = alpha,
			.transparent = transparent,
			.layer_style = layer_style,
		};
		v.overlay_count++;
	}
	return v;
}

// should_support_sync_output checks env vars to estimate whether the
// terminal supports synchronized output (mode 2026). This is a heuristic
// matching the Go version's shouldQuerySynchronizedOutput().
fn bool should_support_sync_output() {
	// SSH sessions — most modern SSH terminals support it
	char* ssh_tty = getenv("SSH_TTY");
	if (ssh_tty != null) return true;

	// Windows Terminal
	char* wt_session = getenv("WT_SESSION");
	if (wt_session != null) return true;

	// Check TERM_PROGRAM for known terminals
	char* term_prog = getenv("TERM_PROGRAM");
	if (term_prog != null) {
		String tp = ((ZString)term_prog).str_view();
		if (tp.starts_with("ghostty")) return true;
		if (tp.starts_with("WezTerm")) return true;
		if (tp.starts_with("Alacritty")) return true;
		if (tp.starts_with("kitty")) return true;
		if (tp.starts_with("rio")) return true;
		if (tp.starts_with("iTerm.app")) return true;
		if (tp.starts_with("vscode")) return true;
	}

	// tmux/screen — likely supports it when inside a capable outer terminal
	char* tmux = getenv("TMUX");
	if (tmux != null) return true;
	char* screen = getenv("STY");
	if (screen != null) return true;

	return false;
}

// viewf creates a formatted View (shorthand for new_view + string::tformat).
fn View viewf(String fmt, args...) {
	return new_view(string::tformat(fmt, ...args));
}

// view_alto creates an alt-screen View with formatted content.
fn View view_alto(String fmt, args...) {
	return new_alt_screen_view(string::tformat(fmt, ...args));
}

enum MsgKind : char {
	NONE,
	KEY,
	WINDOW_SIZE,
	FOCUS,
	BLUR,
	MOUSE,
	QUIT,
	TICK,
	USER,
	// PASTE carries the complete text of one bracketed paste (mode 2004).
	// Ordinal 9 — appended after USER so existing ordinals are unchanged.
	PASTE,
	// PASTE_START / PASTE_END are internal-only sentinels produced by parse_key
	// when it recognises the ESC[200~ / ESC[201~ bracketed-paste markers.
	// They are consumed in Program.run() and never forwarded to model.update().
	PASTE_START,
	PASTE_END,
}

struct WindowSizeMsg {
	int width;
	int height;
}

struct Msg {
	MsgKind kind;
	KeyMsg key;
	WindowSizeMsg window_size;
	MouseMsg mouse;
	int tag;
	void* user;
	void* owner;
	// paste holds the raw pasted text for MsgKind.PASTE messages.
	// Lifetime: valid only during the dispatch() call that delivers it —
	// the string is a view into paste_buf which is cleared immediately after
	// dispatch returns. Do not store it; copy if the model needs it later.
	String paste;
}

// Cmd: function pointer producing a Msg. A null Cmd means "no command".
alias Cmd = fn Msg();

interface Model {
	fn Cmd init();
	fn Cmd update(Msg msg);
	fn View view();
	fn void on_mount() @optional;
	fn void on_destroy() @optional;
	fn void on_focus() @optional;
	fn void on_blur() @optional;
}

// Constants
const sz MAX_BATCH  = 16;
const sz MAX_TIMERS = 32;
// How long to hold a lone leading ESC before flushing it as a keypress,
// giving the rest of a split escape sequence time to arrive.
const sz ESC_HOLD_MS = 50;
// Longest OSC 22 mouse cursor name tracked across frames. The longest CSS
// cursor keyword is "no-drop"/"nesw-resize" class at 12 chars; 32 leaves room
// for terminal-specific names. Longer names still render — they just always
// re-emit, since they can't be cached for comparison.
const sz MAX_MOUSE_CURSOR_LEN = 32;

struct TimerEntry {
	bool active;
	sz deadline_ms;
	Cmd callback;
	void* owner;
}

// Program holds all mutable runtime state for a running TUI.
// Enables sequential multi-instance use and proper testability.
struct Program {
	Model model;
	TimerEntry[MAX_TIMERS] timers;
	bool in_alt_screen;
	// Cached window size (including pixel dimensions) used to convert
	// SGR-Pixels (mode 1016) mouse coordinates to cell coordinates without
	// an ioctl per mouse event. Refreshed on init and on WINDOW_SIZE changes.
	WinSize cached_ws;
	MouseMode mouse_mode;
	bool report_key_events;
	bool mouse_pixels;
	bool debug;
	char[512] pending;
	sz pending_len;
	// When pending is stuck on a leading ESC, the wall-clock time (ms) at
	// which the lone ESC is flushed as a real keypress. 0 = no hold active.
	sz esc_deadline_ms;

	// Test / injection support
	bool test_mode;
	int inject_width;
	int inject_height;
	DString* output_buf;
	char[] inject_input;
	sz inject_input_pos;
	// Ring buffer for Send()-injected messages.
	Msg[MAX_BATCH] send_queue;
	int send_head;
	int send_tail;
	// Mutex protecting send_queue / send_head / send_tail.
	// Initialized lazily inside run() so send() is safe to call before
	// the program is started (send_mu_init guards against that path).
	thread::Mutex send_mu;
	bool send_mu_init;

	// Threaded input reader
	thread::Thread reader_thread;

	// Xray renderer (differential rendering + sync output)
	xray::Renderer* renderer;

	// Last emitted OSC 22 mouse cursor name; avoids re-emitting every frame.
	// Stored as owned bytes rather than a String: the name comes from a View
	// built inside render_current_view's @pool(), so keeping the slice would
	// retain temp memory that is freed before the next frame compares against
	// it. Names are short CSS cursor keywords ("pointer", "nwse-resize").
	char[MAX_MOUSE_CURSOR_LEN] last_mouse_cursor_buf;
	sz last_mouse_cursor_len;
	// False once an uncacheable (over-long) name has been emitted, forcing the
	// next frame to re-emit rather than compare against a stale buffer.
	bool last_mouse_cursor_valid;

	// Last rendered content height (rows), for clean exit in inline (non-alt-screen) mode.
	sz last_content_rows;

	// Bracketed paste accumulation state.
	// in_paste is true while ESC[200~ has been seen but ESC[201~ has not yet arrived.
	// paste_buf accumulates raw paste bytes across multiple read() calls.
	// Heap-allocated and persistent (the temp allocator doesn't survive loop iterations).
	// Initialised inside run(); freed in the cleanup defer.
	bool in_paste;
	DString paste_buf;
}

// File-scope input queue — not inside Program to avoid copies.
InputQueue g_input_queue;

// ============================================================
// InputQueue — ring buffer for raw stdin bytes.
// The reader thread pushes; the main event loop drains.
// ============================================================

const sz INPUT_BUF_SIZE = 4096;

struct InputQueue {
	char[INPUT_BUF_SIZE] buf;
	sz head;
	sz tail;
	thread::Mutex mu;
	thread::ConditionVariable cond;
	bool closed;
	// Bytes silently dropped because the ring was full; accumulated under mu.
	// Drained by the main loop via input_queue_take_dropped().
	sz dropped;
}

fn void? input_queue_init(InputQueue* q) {
	q.head = 0;
	q.tail = 0;
	q.closed = false;
	q.mu.init()!;
	q.cond.init()!;
}

// input_queue_close signals the reader thread to stop.
// It is safe to call while the reader is still running — it locks the mutex,
// sets closed, and broadcasts so the reader wakes from its cond wait.
// After this call, join the reader thread before calling input_queue_destroy.
fn void input_queue_close(InputQueue* q) {
	q.mu.lock();
	q.closed = true;
	q.cond.broadcast();
	q.mu.unlock();
}

fn void input_queue_destroy(InputQueue* q) {
	// At this point the reader thread must have already been joined.
	// Destroying the condvar and mutex while the reader is alive is UB.
	q.cond.destroy();
	q.mu.destroy();
}

fn void input_queue_push(InputQueue* q, char[] data) {
	q.mu.lock();
	for (sz i = 0; i < data.len; i++) {
		sz next = (q.head + 1) % INPUT_BUF_SIZE;
		if (next == q.tail) {
			// Ring is full — count remaining bytes as dropped so the main
			// loop can surface them via debug_warn without a racy g_program access here.
			q.dropped += data.len - i;
			break;
		}
		q.buf[q.head] = data[i];
		q.head = next;
	}
	q.cond.signal();
	q.mu.unlock();
}

// input_queue_take_dropped reads and resets the dropped-byte counter under
// the queue mutex. Returns 0 when nothing was dropped.
fn sz input_queue_take_dropped(InputQueue* q) {
	q.mu.lock();
	sz n = q.dropped;
	q.dropped = 0;
	q.mu.unlock();
	return n;
}

fn sz input_queue_drain(InputQueue* q, char[] out) {
	q.mu.lock();
	defer q.mu.unlock();
	sz count = 0;
	while (count < out.len && q.tail != q.head) {
		out[count] = q.buf[q.tail];
		q.tail = (q.tail + 1) % INPUT_BUF_SIZE;
		count++;
	}
	return count;
}

// input_queue_wait blocks until data is available or timeout_ms elapses.
// Called with the queue unlocked; returns with queue unlocked.
fn void input_queue_wait(InputQueue* q, sz timeout_ms) {
	q.mu.lock();
	if (q.tail == q.head && !q.closed) {
		(void)q.cond.wait_timeout(&q.mu, (time::Duration)((long)timeout_ms * time::MS));
	}
	q.mu.unlock();
}

fn bool input_queue_is_closed(InputQueue* q) {
	q.mu.lock();
	bool c = q.closed;
	q.mu.unlock();
	return c;
}

// ============================================================
// input_reader_thread — reads stdin, pushes bytes into InputQueue.
// Runs on a dedicated thread so the event loop is never blocked
// by stdout writes.
// ============================================================

fn int input_reader_fn(void* arg) {
	InputQueue* q = (InputQueue*)arg;
	char[256] tmp;

	while (!input_queue_is_closed(q)) {
		PollFd pfd;
		pfd.fd = STDIN_FILENO;
		pfd.events = POLLIN;
		pfd.revents = 0;

		int r = poll(&pfd, 1, 50); // 50ms timeout
		if (r <= 0) continue;

		sz n = read(STDIN_FILENO, &tmp[0], 256);
		if (n <= 0) {
			// EOF or a hard read error: no further input can ever arrive.
			// Mark the queue closed rather than just returning — otherwise the
			// event loop keeps blocking in input_queue_wait for up to a second
			// per iteration, forever, with nothing left to wake it. Closing
			// also broadcasts, so a waiter is released immediately.
			input_queue_close(q);
			break;
		}

		input_queue_push(q, tmp[:n]);
	}
	return 0;
}

// Global pointer to the currently running program.
// Set during Program.run(), cleared on exit.
// Safe because only one program can run at a time (one terminal).
Program* g_program = null;

// debug_warn appends a timestamped line to milktea-debug.log.
// Only writes when the running program has debug=true; silently swallows all
// I/O errors so a logging failure never disrupts the TUI surface.
// Never touches stdout/stderr — those are the terminal rendering surface.
fn void debug_warn(String msg) @local {
	if (g_program == null || !g_program.debug) return;
	// Open in append mode so successive calls accumulate in one file.
	File? f = io::file::open("milktea-debug.log", "a");
	if (catch f) return;
	(void)f.write((char[])msg);
	(void)f.write((char[])"\n");
	(void)f.close();
}

fn Msg make_quit_msg() @local {
	return { .kind = MsgKind.QUIT };
}

// tick_msg creates a TICK message for animation/timers.
fn Msg tick_msg() {
	return { .kind = MsgKind.TICK };
}

// Common cursor characters.
const String CURSOR_BLOCK     = "\xe2\x96\x88"; // █
const String CURSOR_UNDERLINE = "\xe2\x96\x84"; // ▄
const String CURSOR_BAR       = "\xe2\x96\x82"; // ▂

fn Cmd quit() {
	return &make_quit_msg;
}

// ============================================================
// Program options — configure a Program before run()
// ============================================================

// with_window_size sets a fixed window size, bypassing the TTY query.
fn void with_window_size(Program* self, int w, int h) {
	self.inject_width = w;
	self.inject_height = h;
}

// with_test_mode enables test mode: skips raw mode, cursor control,
// focus/mouse sequences, signal handling, and TTY queries.
// Output is captured to the given DString instead of stdout.
fn void with_test_mode(Program* self, DString* output) {
	self.test_mode = true;
	self.output_buf = output;
}

// with_input injects raw input bytes that the event loop will consume
// instead of reading from stdin.
fn void with_input(Program* self, char[] data) {
	self.inject_input = data;
	self.inject_input_pos = 0;
}

// ============================================================
// Send — inject a message into the running event loop
// ============================================================

// send enqueues a message for the event loop to process.
// Thread-safe: protected by send_mu, which is initialized in run().
// Calls before run() (send_mu_init == false) are silently dropped — the
// program isn't running yet so there is no consumer to wake.
// In test mode, the message is placed in a ring buffer consumed by run().
// When the ring is full the message is dropped; enable Program.debug to
// surface this in milktea-debug.log.
fn void Program.send(Program* self, Msg msg) {
	if (!self.send_mu_init) return; // program not running; no consumer
	self.send_mu.lock();
	int next = (self.send_head + 1) % (int)MAX_BATCH;
	bool dropped = next == self.send_tail;
	if (!dropped) {
		self.send_queue[self.send_head] = msg;
		self.send_head = next;
	}
	self.send_mu.unlock();
	// Warn outside the locked region — debug_warn does file I/O.
	if (dropped) debug_warn("send queue full; message dropped");
}

// send_recv dequeues a previously sent message. Returns true if a message
// was available, false if the queue is empty.
fn bool Program.send_recv(Program* self, Msg* out) {
	self.send_mu.lock();
	if (self.send_tail == self.send_head) {
		self.send_mu.unlock();
		return false;
	}
	*out = self.send_queue[self.send_tail];
	self.send_tail = (self.send_tail + 1) % (int)MAX_BATCH;
	self.send_mu.unlock();
	return true;
}

// dispatch processes a message through the model, returning true if QUIT was seen.
// Command chains are capped at MAX_BATCH (16) iterations. A model whose update()
// continuously returns a non-NONE Cmd will be truncated at that limit; the
// truncation is surfaced via debug_warn() so it is visible in debug mode without
// ever crashing or blocking the event loop.
fn bool dispatch(Program* self, Model model, Msg m) @local {
	if (m.kind == MsgKind.QUIT) return true;
	Cmd c     = model.update(m);
	int chain = 0;
	while (c != null && chain < MAX_BATCH) {
		Msg next = c();
		if (next.kind == MsgKind.QUIT) return true;
		if (next.kind == MsgKind.NONE) break;
		c = model.update(next);
		chain++;
	}
	// Warn when the chain was cut off — the model may have intended more work.
	if (chain >= MAX_BATCH && c != null) {
		debug_warn("command chain exceeded MAX_BATCH; truncated");
	}
	return false;
}

// emit_sgr writes an SGR sequence to the program's output.
fn void Program.emit_sgr(Program* self, String seq) {
	if (self.test_mode) {
		if (self.output_buf != null) {
			self.output_buf.append_string(seq);
		}
	} else {
		write_stdout((char[])seq);
	}
}

// apply_mouse_pixels converts a parsed MouseMsg's row/col — which the SGR
// parser always treats as raw coordinates from the terminal — into proper
// pixel (px/py) and cell (row/col) values when DEC mode 1016 (SGR-Pixels) is
// active.
//
// The wire format for mode 1006 and 1016 is identical; only the terminal's
// interpretation of the reported x/y differs. To tell them apart without a
// side channel, this uses two signals:
//   1. If the cached window size has no pixel dimensions (ws_xpixel/ws_ypixel
//      == 0, e.g. tmux or terminals that don't populate TIOCGWINSZ pixel
//      fields), the terminal cannot be sending pixel coordinates usefully —
//      fall back to treating row/col as cell coordinates untouched.
//   2. Otherwise, if the raw coordinates already fall within the current
//      cell grid, the terminal likely ignored mode 1016 and is still sending
//      cell coordinates — again fall back untouched (px/py stay 0).
//   3. Otherwise, treat row/col as 0-based pixel coordinates: store them in
//      px/py and derive cell row/col by dividing by the per-cell pixel size.
fn void Program.apply_mouse_pixels(Program* self, MouseMsg* mouse) {
	WinSize ws = self.cached_ws;
	if (ws.ws_xpixel == 0 || ws.ws_ypixel == 0 || ws.ws_col == 0 || ws.ws_row == 0) {
		return;
	}
	if (mouse.col < (int)ws.ws_col && mouse.row < (int)ws.ws_row) {
		// Coordinates already fit inside the cell grid — terminal is still
		// sending cell coordinates (mode 1016 unsupported/ignored).
		return;
	}

	int raw_x = mouse.col;
	int raw_y = mouse.row;

	double cell_w = (double)ws.ws_xpixel / (double)ws.ws_col;
	double cell_h = (double)ws.ws_ypixel / (double)ws.ws_row;

	int cell_col = (int)((double)raw_x / cell_w);
	int cell_row = (int)((double)raw_y / cell_h);

	if (cell_col < 0) cell_col = 0;
	if (cell_col >= (int)ws.ws_col) cell_col = (int)ws.ws_col - 1;
	if (cell_row < 0) cell_row = 0;
	if (cell_row >= (int)ws.ws_row) cell_row = (int)ws.ws_row - 1;

	mouse.px = raw_x;
	mouse.py = raw_y;
	mouse.col = cell_col;
	mouse.row = cell_row;
}

// tick registers a timer that fires after delay_ms.
// Default: 16ms (~60fps) sending a TICK message.
// When all MAX_TIMERS slots are occupied the timer is silently dropped;
// enable Program.debug to surface this in milktea-debug.log.
fn Cmd tick(sz delay_ms = 16, Cmd callback = &tick_msg, void* owner = null) {
	if (g_program == null) return null;
	sz deadline = time_ms() + delay_ms;
	for (sz i = 0; i < MAX_TIMERS; i++) {
		if (!g_program.timers[i].active) {
			g_program.timers[i].active = true;
			g_program.timers[i].deadline_ms = deadline;
			g_program.timers[i].callback = callback;
			g_program.timers[i].owner = owner;
			return null;
		}
	}
	// No free slot found — all MAX_TIMERS entries are active.
	debug_warn("timer table full; tick dropped");
	return null;
}

// every registers a timer that fires at the next clock boundary (wall-clock aligned).
// Unlike tick(), the deadline is snapped to the next multiple of interval_ms,
// so successive calls stay locked to absolute time regardless of drift.
// Use for clock displays, countdowns, and periodic sync.
// Default: 16ms (~60fps) sending a TICK message.
// When all MAX_TIMERS slots are occupied the timer is silently dropped;
// enable Program.debug to surface this in milktea-debug.log.
// snap_delay returns how long to wait from `wall` to reach the next multiple
// of `interval_ms`. Always in (0, interval_ms], so a timer re-armed exactly on
// a boundary waits a full interval rather than firing again immediately.
fn sz snap_delay(sz wall, sz interval_ms) {
	if (interval_ms <= 0) return 1;
	sz elapsed = wall % interval_ms;
	return elapsed == 0 ? interval_ms : interval_ms - elapsed;
}

fn Cmd every(sz interval_ms = 16, Cmd callback = &tick_msg, void* owner = null) {
	if (g_program == null) return null;
	// A zero interval would divide-by-zero on the modulo below; clamp to 1ms.
	// Semantically, 0 means "as fast as possible" — 1ms is the smallest
	// meaningful interval and avoids crashing inside the framework.
	if (interval_ms == 0) interval_ms = 1;
	// The delay is computed against the wall clock so the deadline lands on a
	// calendar boundary (a 1s display ticks exactly on :00). The stored
	// deadline is monotonic, matching what the event loop compares against —
	// mixing the two clocks in one field would make every deadline wrong by
	// the offset between them.
	sz deadline = time_ms() + snap_delay(wall_time_ms(), interval_ms);
	for (sz i = 0; i < MAX_TIMERS; i++) {
		if (!g_program.timers[i].active) {
			g_program.timers[i].active = true;
			g_program.timers[i].deadline_ms = deadline;
			g_program.timers[i].callback = callback;
			g_program.timers[i].owner = owner;
			return null;
		}
	}
	// No free slot found — all MAX_TIMERS entries are active.
	debug_warn("timer table full; every dropped");
	return null;
}

fn void cancel(void* owner) {
	if (g_program == null || owner == null) return;
	for (sz i = 0; i < MAX_TIMERS; i++) {
		if (g_program.timers[i].active && g_program.timers[i].owner == owner) {
			g_program.timers[i].active = false;
		}
	}
}

// run executes the event loop for the program.
fn void? Program.run(Program* self) {
	g_program = self;
	self.pending_len = 0;
	self.in_alt_screen = false;
	// No OSC 22 emitted yet, which is indistinguishable from having emitted
	// the empty (reset) name — so a first frame with no cursor stays silent.
	self.last_mouse_cursor_len = 0;
	self.last_mouse_cursor_valid = true;
	self.send_head = 0;
	self.send_tail = 0;
	for (sz i = 0; i < MAX_TIMERS; i++) {
		self.timers[i] = { };
	}
	// Initialize send_mu before marking it ready so that any concurrent
	// send() call after this point sees a valid mutex.
	self.send_mu.init()!;
	self.send_mu_init = true;
	defer {
		// Disable send() before destroying the mutex so late callers
		// see send_mu_init == false and return early rather than
		// locking a destroyed mutex.
		self.send_mu_init = false;
		self.send_mu.destroy();
		g_program = null;
	}

	TtyState saved;
	// Initialise paste accumulation buffer; freed in the cleanup defer.
	self.in_paste = false;
	self.paste_buf.init(&allocators::LIBC_ALLOCATOR, 256);

	// Tracks how far setup got, so the cleanup defer below tears down exactly
	// what was built. Setup can fail partway (queue init, thread spawn), and a
	// defer registered after the failing statement never runs — so the restore
	// must be armed before the terminal is touched, not after setup completes.
	bool tty_raw       = false;
	bool queue_created = false;
	bool reader_running = false;

	if (!self.test_mode) {
		saved = raw_mode_enter()!;
		tty_raw = true;
	}

	// Armed immediately: from here on, every exit path restores the terminal.
	defer {
		if (tty_raw) {
			if (self.mouse_pixels) {
				disable_mouse_pixels();
				self.mouse_pixels = false;
			}
			disable_mouse();
			disable_bracketed_paste();
			// Pop the key-events enhancement layer first (if it was pushed on top
			// of the base layer), then pop the base kitty keyboard layer — restores
			// the terminal's previous mode.
			if (self.report_key_events) {
				disable_kitty_key_events();
				self.report_key_events = false;
			}
			disable_kitty_keyboard();
			disable_focus();
			show_cursor();
			write_stdout((char[])OSC_CURSOR_COLOR_RESET);
			write_stdout((char[])OSC_MOUSE_CURSOR_RESET);
			// For inline (non-alt-screen) mode: move cursor below the last rendered
			// content so the shell prompt appears on a clean line after the app exits.
			if (!self.in_alt_screen && self.last_content_rows > 0) {
				write_stdout((char[])string::tformat("\x1b[%d;1H\x1b[m\r\n", self.last_content_rows));
			}
			// Stop dereferencing this frame's fields from signal handlers before
			// it goes away — Program is a stack local in every entry point.
			teardown_signals();
			raw_mode_restore(saved);
		}
	}

	if (!self.test_mode) {
		hide_cursor();
		enable_focus();
		enable_bracketed_paste();
		// Push kitty keyboard protocol flag 1 (disambiguate escape codes).
		// Terminals that don't support it ignore the sequence — safe to push always.
		enable_kitty_keyboard();
		setup_signals(saved, &self.in_alt_screen);

		// Start the reader thread so stdin reads never block the event loop.
		input_queue_init(&g_input_queue)!;
		queue_created = true;
		thread::Thread.create(&self.reader_thread, &input_reader_fn, &g_input_queue)!;
		reader_running = true;
	}

	// Defers live at function scope so they run after the event loop exits,
	// not when the if-block above closes (C3 defer is block-scoped).
	defer {
		// Free the paste accumulation buffer regardless of test mode.
		self.paste_buf.free();

		if (self.renderer != null) {
			self.renderer.destroy();
			mem::free(self.renderer);
			self.renderer = null;
		}
		// Two-phase shutdown: first signal the reader to stop, then join
		// it so we never call input_queue_destroy while the reader thread
		// may still be executing input_queue_push / input_queue_is_closed
		// (which lock the mutex — destroying a locked mutex is UB on most
		// POSIX implementations and all ARM memory models).
		if (queue_created) {
			input_queue_close(&g_input_queue);
			if (reader_running) self.reader_thread.join();
			input_queue_destroy(&g_input_queue);
		}
	}
	defer {
		if (&self.model.on_destroy) self.model.on_destroy();
	}
	defer {
		if (self.in_alt_screen) {
			if (self.test_mode) {
				if (self.output_buf != null) {
					self.output_buf.append_string(SGR_ALT_OFF);
				}
			} else {
				exit_alt_screen();
			}
		}
	}

	Cmd c0 = self.model.init();
	if (c0 != null) {
		Msg m0 = c0();
		if (m0.kind != MsgKind.NONE && dispatch(self, self.model, m0)) return;
	}

	if (&self.model.on_mount) self.model.on_mount();

	// Determine initial window size
	WinSize initial_ws;
	if (self.inject_width > 0 && self.inject_height > 0) {
		initial_ws.ws_col = (ushort)self.inject_width;
		initial_ws.ws_row = (ushort)self.inject_height;
	} else if (!self.test_mode) {
		initial_ws = get_window_size();
		if (initial_ws.ws_col == 0) initial_ws.ws_col = 80;
		if (initial_ws.ws_row == 0) initial_ws.ws_row = 24;
	} else {
		initial_ws.ws_col = 80;
		initial_ws.ws_row = 24;
	}
	self.cached_ws = initial_ws;

	// Create xray renderer for differential rendering (non-test mode only)
	if (!self.test_mode) {
		self.renderer = xray::new_renderer((sz)initial_ws.ws_col, (sz)initial_ws.ws_row, &write_stdout);
		if (should_support_sync_output()) {
			self.renderer.set_sync_supported(true);
		}
	}

	Msg init_wmsg = { .kind = MsgKind.WINDOW_SIZE, .window_size = { (int)initial_ws.ws_col, (int)initial_ws.ws_row } };
	if (dispatch(self, self.model, init_wmsg)) return;

	// Render initial view
	self.render_current_view();

	char[256] tmp;

	while (true) {
		// Fire expired timers
		bool dirty = false;
		sz now     = time_ms();
		for (sz i = 0; i < MAX_TIMERS; i++) {
			if (self.timers[i].active && now >= self.timers[i].deadline_ms) {
				Cmd cb = self.timers[i].callback;
				void* owner = self.timers[i].owner;
				self.timers[i].active = false;
				Msg m = cb();
				m.owner = owner;
				if (m.kind != MsgKind.NONE && dispatch(self, self.model, m)) return;
				dirty = true;
				now = time_ms();
			}
		}

		// Read input — from injected buffer, the reader thread queue, or stdin
		sz n = 0;
		if (self.test_mode) {
			n = self.drain_inject_input(tmp[..]);
		} else {
			n = input_queue_drain(&g_input_queue, tmp[..]);
			// Check for bytes the reader thread dropped due to a full ring buffer.
			// We read and reset the counter here (main thread only) to avoid touching
			// g_program from the reader thread where it would be racy.
			sz idropped = input_queue_take_dropped(&g_input_queue);
			if (idropped > 0) {
				@pool() {
					debug_warn(string::tformat(
						"input ring full; %d byte(s) dropped by reader thread", idropped));
				};
			}
		}

		// Drain Send()-injected messages
		Msg injected;
		while (self.send_recv(&injected)) {
			if (dispatch(self, self.model, injected)) return;
			dirty = true;
		}

		if (!self.test_mode && g_win_resized.load(RELAXED)) {
			g_win_resized.store(false, RELAXED);
			WinSize ws = get_window_size();
			self.cached_ws = ws;
			if (self.renderer != null) {
				self.renderer.resize((sz)ws.ws_col, (sz)ws.ws_row);
			}
			Msg wm = { .kind = MsgKind.WINDOW_SIZE, .window_size = { (int)ws.ws_col, (int)ws.ws_row } };
			if (dispatch(self, self.model, wm)) return;
			dirty = true;
		}

		if (n > 0) {
			sz copied = 0;
			for (sz i = 0; i < n && self.pending_len < self.pending.len; i++) {
				self.pending[self.pending_len++] = tmp[(sz)i];
				copied++;
			}
			// Warn when the pending buffer filled up before all bytes were copied.
			// This normally means a very long escape sequence or burst of input
			// arrived faster than the parser can consume it.
			if (copied < n) {
				@pool() {
					debug_warn(string::tformat(
						"pending buffer full; %d input byte(s) dropped", n - copied));
				};
			}
		}

		// New bytes resolve (or restart) the lone-ESC ambiguity, so the
		// hold timer must start over.
		if (n > 0) self.esc_deadline_ms = 0;

		bool stuck   = false;
		bool reparse = true;
		while (reparse) {
			reparse = false;
			stuck   = false;

			// ---- Paste accumulation ----
			// While inside a bracketed paste, scan the pending buffer for the
			// terminator ESC[201~ rather than running parse_key byte-by-byte.
			// This ensures raw pasted bytes (including ESC sequences) are never
			// misinterpreted as key events.
			//
			// The terminator is 6 bytes: \x1b [ 2 0 1 ~
			// We may need to withhold the last 5 bytes (len-1 of the terminator)
			// when a read ends mid-terminator so we can recognise it on the next read.
			while (self.in_paste && self.pending_len > 0) {
				// Safety cap: discard bytes beyond 1 MB of paste content.
				// (1 MB = 1 048 576 bytes)
				const sz PASTE_MAX = 1048576;
				const char[] PASTE_TERM = "\x1b[201~";
				const sz PASTE_TERM_LEN = 6; // \x1b [ 2 0 1 ~

				// Scan for the terminator in pending.
				// found = true and term_pos = byte offset when the terminator is present.
				bool found = false;
				sz term_pos = 0;
				for (sz i = 0; i + PASTE_TERM_LEN <= self.pending_len; i++) {
					bool match = true;
					for (sz j = 0; j < PASTE_TERM_LEN; j++) {
						if (self.pending[i + j] != PASTE_TERM[j]) {
							match = false;
							break;
						}
					}
					if (match) {
						term_pos = i;
						found = true;
						break;
					}
				}

				if (found) {
					// Found the terminator: append everything before it.
					if (term_pos > 0) {
						if (self.paste_buf.len() + term_pos <= PASTE_MAX) {
							self.paste_buf.append_bytes(self.pending[:term_pos]);
						} else {
							debug_warn("bracketed paste exceeded 1 MB; bytes dropped");
						}
					}
					// Consume bytes before + the terminator itself.
					sz consume = term_pos + PASTE_TERM_LEN;
					for (sz i = consume; i < self.pending_len; i++) {
						self.pending[i - consume] = self.pending[i];
					}
					self.pending_len -= consume;

					// Emit ONE PASTE message; str_view is valid during dispatch
					// because paste_buf is not touched again until after return.
					Msg pm;
					pm.kind  = MsgKind.PASTE;
					pm.paste = self.paste_buf.str_view();
					if (dispatch(self, self.model, pm)) return;
					dirty = true;

					// Reset paste state.
					self.paste_buf.clear();
					self.in_paste = false;
				} else {
					// Terminator not (fully) in pending. Withhold the last
					// (PASTE_TERM_LEN - 1) bytes in case they are a partial
					// terminator prefix split across reads. But only withhold
					// bytes that actually are a prefix of the terminator.
					//
					// Strategy: find the longest suffix of pending that is a
					// prefix of the terminator, withhold exactly that many bytes.
					sz safe = self.pending_len; // how many bytes we can safely consume
					for (sz prefix_len = PASTE_TERM_LEN - 1; prefix_len >= 1; prefix_len--) {
						// Check if the last prefix_len bytes of pending match
						// the first prefix_len bytes of the terminator.
						if (prefix_len > self.pending_len) continue;
						sz start = self.pending_len - prefix_len;
						bool match = true;
						for (sz j = 0; j < prefix_len; j++) {
							if (self.pending[start + j] != PASTE_TERM[j]) {
								match = false;
								break;
							}
						}
						if (match) {
							safe = start;
							break;
						}
					}

					// Append the safe portion to paste_buf.
					if (safe > 0) {
						if (self.paste_buf.len() + safe <= PASTE_MAX) {
							self.paste_buf.append_bytes(self.pending[:safe]);
						} else {
							debug_warn("bracketed paste exceeded 1 MB; bytes dropped");
							safe = self.pending_len; // consume all to make progress
						}
						for (sz i = safe; i < self.pending_len; i++) {
							self.pending[i - safe] = self.pending[i];
						}
						self.pending_len -= safe;
					} else {
						// The entire pending buffer is a potential terminator prefix;
						// leave it in place and wait for more input.
						stuck = true;
					}
					break; // wait for more input in either case
				}
			}

			// ---- Normal key parsing (only when not in paste mode) ----
			while (!self.in_paste && self.pending_len > 0) {
				ParseResult pr = parse_key(self.pending[:self.pending_len]);
				if (pr.consumed == 0) {
					stuck = true;
					break;
				}

				for (sz i = pr.consumed; i < self.pending_len; i++) {
					self.pending[i - pr.consumed] = self.pending[i];
				}
				self.pending_len -= pr.consumed;

				if (pr.kind == MsgKind.PASTE_START) {
					// Enter paste accumulation mode; inner loop above handles the rest.
					if (self.in_paste) {
						// Nested PASTE_START while already in paste — ignore gracefully.
						debug_warn("bracketed paste: PASTE_START while already in paste mode; ignored");
					} else {
						self.in_paste = true;
					}
					reparse = true;
					break; // switch to paste loop on next iteration
				} else if (pr.kind == MsgKind.PASTE_END) {
					// PASTE_END outside of paste — spurious, ignore.
					debug_warn("bracketed paste: PASTE_END received outside of paste mode; ignored");
					continue;
				}

				if (pr.key.code == KeyCode.NONE && pr.kind == MsgKind.KEY) continue;

				Msg m;
				if (pr.kind == MsgKind.FOCUS) {
					m.kind = MsgKind.FOCUS;
					if (&self.model.on_focus) self.model.on_focus();
				} else if (pr.kind == MsgKind.BLUR) {
					m.kind = MsgKind.BLUR;
					if (&self.model.on_blur) self.model.on_blur();
				} else if (pr.kind == MsgKind.MOUSE) {
					m.kind = MsgKind.MOUSE;
					m.mouse = pr.mouse;
					if (self.mouse_pixels) {
						self.apply_mouse_pixels(&m.mouse);
					}
				} else {
					m.kind = MsgKind.KEY;
					m.key = pr.key;
				}
				if (dispatch(self, self.model, m)) return;
				dirty = true;
			}

			// ESC-hold: pending starts with an ambiguous lone ESC. Hold it
			// briefly so the rest of a split escape sequence can arrive;
			// on timeout, flush it as a real ESC key and re-parse the rest.
			// Only applies when not in paste mode (in paste mode, bytes are raw).
			if (!self.in_paste && stuck && self.pending_len > 0 && self.pending[0] == 0x1b) {
				now = time_ms();
				if (self.esc_deadline_ms == 0) self.esc_deadline_ms = now + ESC_HOLD_MS;
				// In test mode, exhausted injected input means nothing more
				// is ever coming — flush immediately to stay deterministic.
				bool flush = self.test_mode
					? self.inject_input_pos >= self.inject_input.len
					: now >= self.esc_deadline_ms;
				if (flush) {
					self.esc_deadline_ms = 0;
					for (sz i = 1; i < self.pending_len; i++) {
						self.pending[i - 1] = self.pending[i];
					}
					self.pending_len--;
					Msg em = { .kind = MsgKind.KEY, .key = { KeyCode.ESC, 0, false, false, false, KeyAction.KEY_PRESS } };
					if (dispatch(self, self.model, em)) return;
					dirty   = true;
					reparse = true;
				}
			} else if (!self.in_paste) {
				self.esc_deadline_ms = 0;
			}
		}

		if (dirty) {
			self.render_current_view();
		}


		// In test mode there is no reader thread and no wall-clock waiting, so
		// once the injected input is consumed, the pending buffer is drained
		// and no timer is armed, nothing can ever produce another message.
		// Without this the loop spins at 100% CPU forever whenever a model
		// under test doesn't return quit() — one bad test hangs the suite.
		if (self.test_mode && self.inject_input_pos >= self.inject_input.len && self.pending_len == 0
			&& !self.has_active_timer() && self.send_head == self.send_tail) {
			return;
		}

		// Stdin reached EOF (piped input exhausted, or the terminal went away)
		// and everything already received has been processed. No further input
		// can arrive, so blocking again would spin — input_queue_wait returns
		// immediately once the queue is closed. Timers still keep the program
		// alive, so an animation driven purely by tick() is unaffected.
		if (!self.test_mode && input_queue_is_closed(&g_input_queue) && self.pending_len == 0
			&& !self.has_active_timer() && self.send_head == self.send_tail) {
			return;
		}

		// Block until input arrives or the next timer fires — avoids busy-waiting.
		if (!self.test_mode && (self.pending_len == 0 || stuck)) {
			sz wait_ms = 1000;
			now = time_ms();
			for (sz i = 0; i < MAX_TIMERS; i++) {
				if (self.timers[i].active) {
					sz remaining = self.timers[i].deadline_ms > now ? self.timers[i].deadline_ms - now : 0;
					if (remaining < wait_ms) wait_ms = remaining;
				}
			}
			// Wake in time to flush a held lone ESC at its deadline
			if (self.esc_deadline_ms != 0) {
				sz remaining = self.esc_deadline_ms > now ? self.esc_deadline_ms - now : 0;
				if (remaining < wait_ms) wait_ms = remaining;
			}
			// When stuck on incomplete data, cap wait to avoid long hangs
			if (stuck && wait_ms > 100) wait_ms = 100;
			if (wait_ms > 0) {
				input_queue_wait(&g_input_queue, wait_ms);
			}
		}
	}
}

// has_active_timer reports whether any timer slot is armed.
fn bool Program.has_active_timer(Program* self) {
	for (sz i = 0; i < MAX_TIMERS; i++) {
		if (self.timers[i].active) return true;
	}
	return false;
}

// mouse_cursor_matches reports whether `name` is already the emitted OSC 22
// cursor shape. A name too long to cache never matches, so it re-emits each
// frame — correct, just not deduplicated.
fn bool Program.mouse_cursor_matches(Program* self, String name) {
	if (!self.last_mouse_cursor_valid) return false;
	if (name.len > MAX_MOUSE_CURSOR_LEN) return false;
	if (name.len != self.last_mouse_cursor_len) return false;
	for (sz i = 0; i < name.len; i++) {
		if (self.last_mouse_cursor_buf[i] != name[i]) return false;
	}
	return true;
}

// remember_mouse_cursor copies `name` into the owned buffer. Names longer than
// the buffer record a length of 0, so the next frame compares unequal and
// re-emits rather than matching a truncated prefix.
fn void Program.remember_mouse_cursor(Program* self, String name) {
	if (name.len > MAX_MOUSE_CURSOR_LEN) {
		self.last_mouse_cursor_valid = false;
		return;
	}
	for (sz i = 0; i < name.len; i++) {
		self.last_mouse_cursor_buf[i] = name[i];
	}
	self.last_mouse_cursor_len = name.len;
	self.last_mouse_cursor_valid = true;
}

// render_current_view renders the model's current view, handling
// alt-screen transitions and output routing (stdout vs capture buffer).
// In non-test mode, uses xray's differential renderer with synchronized output.
fn void Program.render_current_view(Program* self) {
	@pool() {
		View v = self.model.view();
		if (v.alt_screen && !self.in_alt_screen) {
			self.emit_sgr(SGR_ALT_ON);
			self.in_alt_screen = true;
		} else if (!v.alt_screen && self.in_alt_screen) {
			self.emit_sgr(SGR_ALT_OFF);
			self.in_alt_screen = false;
		}
		// Enable/disable mouse reporting when mouse_mode changes
		if (v.mouse_mode != self.mouse_mode) {
			if (v.mouse_mode == MOUSE_MODE_NONE) {
				disable_mouse(self.mouse_mode == MOUSE_MODE_ALL_MOTION);
				// Mouse reporting itself was just turned off — 1016 no longer
				// applies. Reset it so re-enabling mouse_mode later re-asserts
				// it explicitly rather than relying on terminal state.
				if (self.mouse_pixels) {
					disable_mouse_pixels();
				}
			} else {
				enable_mouse(v.mouse_mode == MOUSE_MODE_ALL_MOTION);
				// Re-assert pixel reporting: some terminals reset SGR-Pixels
				// mode (1016) when the base mouse tracking mode changes, so
				// if the view has pixel mode on, turn it back on here too.
				if (self.mouse_pixels) {
					enable_mouse_pixels();
				}
			}
			self.mouse_mode = v.mouse_mode;
		}
		// Enable/disable SGR-Pixels mouse reporting (DEC mode 1016) when
		// mouse_pixels changes. Only meaningful while mouse_mode is active;
		// still track the flag even if mouse_mode is currently NONE so it
		// gets asserted the moment mouse_mode turns on (handled above).
		if (v.mouse_pixels != self.mouse_pixels) {
			if (v.mouse_pixels) {
				if (v.mouse_mode != MOUSE_MODE_NONE) {
					enable_mouse_pixels();
				}
			} else {
				if (self.mouse_mode != MOUSE_MODE_NONE) {
					disable_mouse_pixels();
				}
			}
			self.mouse_pixels = v.mouse_pixels;
		}
		// Enable/disable kitty key event reporting (press/repeat/release) when
		// report_key_events changes. Pushed/popped as an extra enhancement layer
		// on top of the base disambiguate layer pushed at startup.
		if (v.report_key_events != self.report_key_events) {
			if (v.report_key_events) {
				enable_kitty_key_events();
			} else {
				disable_kitty_key_events();
			}
			self.report_key_events = v.report_key_events;
		}
		if (self.test_mode) {
			if (self.output_buf != null) {
				render_view_to(v, self.output_buf);
			}
		} else {
			// Use xray renderer for differential output
			xray::Renderer* r = self.renderer;
			if (r != null) {
				r.begin_frame();

				// Clear the screen buffer and write new content
				if (v.cells.ptr != null) {
					// Direct cell path — write cells straight into the screen buffer.
					// No string building, no CSI parsing. The diff engine handles the rest.
					// Skip clear() — set_cell() tracks dirty lines against previous frame.
					sz cols = v.cells_width;
					if (cols > r.screen.width) cols = r.screen.width;
					sz rows = v.cells_height;
					if (rows > r.screen.height) rows = r.screen.height;
					for (sz row = 0; row < rows; row++) {
						for (sz col = 0; col < cols; col++) {
							r.screen.set_cell(col, row, v.cells[row * v.cells_width + col]);
						}
					}
					self.last_content_rows = rows;
				} else {
					// String path — parse ANSI content into screen buffer.
					String content = v.content;
					r.screen.clear();
					sz cur_row   = 0;
					sz col       = 0;
					sz line_start = 0;
					for (sz i = 0; i <= content.len; i++) {
						if (i == content.len || content[i] == '\n') {
							sz line_len = i - line_start;
							if (line_len > 0) {
								String line = content[line_start:line_len];
								if (line.len > 0 && line[0] == '\r') {
									line = line[1..];
								}
								r.screen.render_ansi_string(col, cur_row, line, xray::default_style());
							}
							cur_row++;
							col = 0;
							line_start = i + 1;
						}
					}
					self.last_content_rows = cur_row;
				}

				// Render overlays
				for (int oi = 0; oi < v.overlay_count; oi++) {
					Overlay o = v.overlays[oi];

					// Render shadow before content so it appears underneath
					if (o.layer_style.shadow.enabled) {
						r.screen.render_shadow(o.x, o.y, o.w, o.h, o.layer_style.shadow);
					}

					if (o.alpha != 0 && o.alpha < 255) {
						// Alpha overlay: blend color over existing cells in-place,
						// preserving underlying characters.
						//
						// Reuse r.overlay_scratch to avoid a heap alloc+free per frame.
						// Lazily allocate on first use; grow (resize) when a larger overlay
						// arrives. The scratch may be wider/taller than this overlay — that
						// is fine because the blend loop indexes cells[cy * tmp.width + cx],
						// which uses the scratch's own stride, so rows stay correctly aligned.
						xray::ScreenBuffer* tmp = r.overlay_scratch;
						if (tmp == null) {
							// First alpha overlay ever seen — allocate the scratch.
							tmp = xray::new_screen_buffer((sz)o.w, (sz)o.h);
							r.overlay_scratch = tmp;
						} else if (tmp.width < (sz)o.w || tmp.height < (sz)o.h) {
							// Current scratch is too small in at least one dimension; grow it.
							// Use the larger of old and new for each axis so one resize
							// accommodates the largest overlay seen so far.
							sz new_w = tmp.width  < (sz)o.w ? (sz)o.w : tmp.width;
							sz new_h = tmp.height < (sz)o.h ? (sz)o.h : tmp.height;
							tmp.resize(new_w, new_h);
						}
						// Clear before each use so content from a previous frame's overlay
						// does not bleed into this overlay's cell region.
						tmp.clear();
						tmp.render_ansi_string(0, 0, o.content, xray::default_style());
						for (sz cy = 0; cy < (sz)o.h; cy++) {
							for (sz cx = 0; cx < (sz)o.w; cx++) {
								sz dx = (sz)o.x + cx;
								sz dy = (sz)o.y + cy;
								if (dx >= r.screen.width || dy >= r.screen.height) continue;
								xray::Cell src = tmp.cells[cy * tmp.width + cx];
								src.style.bg.a = o.alpha;
								src.style.fg.a = o.alpha;
								xray::Cell* dst = &r.screen.cells[dy * r.screen.width + dx];
								// Blend overlay color over existing cell colors, preserve content
								if (src.style.bg.kind == xray::ColorKind.TRUECOLOR) {
									dst.style.bg = src.style.bg.blend_over(dst.style.bg);
								}
								if (src.style.fg.kind == xray::ColorKind.TRUECOLOR) {
									dst.style.fg = src.style.fg.blend_over(dst.style.fg);
								}
								r.screen.dirty_lines[dy] = true;
							}
						}
						// tmp is owned by r.overlay_scratch; do NOT free it here.
					} else {
						r.screen.blit_ansi((sz)o.x, (sz)o.y, (sz)o.w, (sz)o.h, o.content, o.transparent);
					}

					if (o.layer_style.inner_shadow.enabled) {
						r.screen.render_inner_shadow(o.x, o.y, o.w, o.h, o.layer_style.inner_shadow);
					}
				}

				// Cursor positioning (CUP) is emitted after end_frame, below.
				r.end_frame();

				// Emit OSC 22 mouse cursor shape when it changes.
				if (!self.mouse_cursor_matches(v.mouse_cursor)) {
					if (v.mouse_cursor.len > 0) {
						write_stdout((char[])mouse_cursor_seq(v.mouse_cursor));
					} else {
						write_stdout((char[])OSC_MOUSE_CURSOR_RESET);
					}
					self.remember_mouse_cursor(v.mouse_cursor);
				}

				// Emit cursor positioning and shape after the diff frame
				if (v.has_cursor) {
					DString cursor_seq = dstring::temp();
					int term_row       = v.cursor.y + 1;
					int term_col       = v.cursor.x + 1;
					cursor_seq.append_string(cursor_to(term_row, term_col));
					// Set cursor color via OSC 12
					if (v.cursor.color.len > 0) {
						cursor_seq.append_string(cursor_color_seq(v.cursor.color));
					} else {
						cursor_seq.append_string(OSC_CURSOR_COLOR_RESET);
					}
					cursor_seq.append_string(cursor_style_seq(v.cursor.shape, v.cursor.blink));
					if (v.cursor.blink) {
						cursor_seq.append_string(SGR_CURSOR_BLINK_ON);
					} else {
						cursor_seq.append_string(SGR_CURSOR_BLINK_OFF);
					}
					cursor_seq.append_string(SGR_SHOW_CURSOR);
					write_stdout((char[])cursor_seq.str_view());
				} else if (v.alt_screen) {
					// Park the hidden cursor at top-left to prevent artifacts in some terminals
					write_stdout("\x1b[1;1H");
				}
			} else {
				// Fallback: no renderer (shouldn't happen in non-test mode)
				render_view(v);
			}
		}
	};
}

// drain_inject_input copies bytes from the injected input buffer into buf.
// Returns the number of bytes copied (0 when exhausted).
fn sz Program.drain_inject_input(Program* self, char[] buf) {
	sz remaining = self.inject_input.len - self.inject_input_pos;
	if (remaining == 0) return 0;
	sz n = remaining < buf.len ? remaining : buf.len;
	buf[:n] = self.inject_input[self.inject_input_pos:n];
	self.inject_input_pos += n;
	return n;
}

// run is a convenience wrapper that creates a Program and runs it.
fn void? run(Model model) {
	Program p = { .model = model };
	return p.run();
}