module milktea;

import std::core::dstring;
import std::thread;
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

// View represents a terminal view with content, optional cursor, and settings.
// This mirrors Go's tea.View struct.
struct View {
	String content;
	Cursor cursor;
	bool has_cursor;
	bool alt_screen;
	// Mouse mode — controls whether the terminal sends mouse events.
	MouseMode mouse_mode;
	// Optional direct cell grid — bypasses string parsing.
	// When cells is non-null, the renderer writes cells directly into
	// the screen buffer, skipping ANSI string → CSI parse → cells.
	xray::Cell[] cells;
	sz cells_width;
	sz cells_height;
	// OSC 22 mouse pointer shape. Empty = use terminal default.
	// Examples: "crosshair", "text", "pointer", "default".
	String mouse_cursor;
}

// new_view creates a View with the given content and default settings (no cursor, no alt screen).
fn View new_view(String content) {
	return { .content = content };
}

// new_alt_screen_view creates a View with alt screen enabled.
fn View new_alt_screen_view(String content) {
	return { .content = content, .alt_screen = true };
}

// new_cell_view creates a View backed by a direct cell grid.
// Bypasses string parsing — cells are written straight into the screen buffer.
fn View new_cell_view(xray::Cell[] cells, sz width, sz height) {
	return { .cells = cells, .cells_width = width, .cells_height = height };
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
	BATCH,
	QUIT,
	TICK,
	USER,
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

struct TimerEntry {
	bool active;
	sz deadline_ms;
	Cmd callback;
}

// Program holds all mutable runtime state for a running TUI.
// Replaces the previous global batch/timer state, enabling
// sequential multi-instance use and proper testability.
struct Program {
	Model model;
	Cmd[MAX_BATCH] batch_cmds;
	int batch_count;
	TimerEntry[MAX_TIMERS] timers;
	bool in_alt_screen;
	MouseMode mouse_mode;
	bool debug;
	char[512] pending;
	sz pending_len;

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

	// Threaded input reader
	thread::Thread reader_thread;

	// Xray renderer (differential rendering + sync output)
	xray::Renderer* renderer;

	// Last emitted OSC 22 mouse cursor name; avoids re-emitting every frame.
	String last_mouse_cursor;

	// Last rendered content height (rows), for clean exit in inline (non-alt-screen) mode.
	sz last_content_rows;
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
}

fn void? input_queue_init(InputQueue* q) {
	q.head = 0;
	q.tail = 0;
	q.closed = false;
	q.mu.init()!;
	q.cond.init()!;
}

fn void input_queue_destroy(InputQueue* q) {
	q.mu.lock();
	q.closed = true;
	q.cond.broadcast();
	q.mu.unlock();
	q.cond.destroy();
	q.mu.destroy();
}

fn void input_queue_push(InputQueue* q, char[] data) {
	q.mu.lock();
	for (sz i = 0; i < data.len; i++) {
		sz next = (q.head + 1) % INPUT_BUF_SIZE;
		if (next == q.tail) break; // full, drop remaining
		q.buf[q.head] = data[i];
		q.head = next;
	}
	q.cond.signal();
	q.mu.unlock();
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
		if (n <= 0) break;

		input_queue_push(q, tmp[:n]);
	}
	return 0;
}

// Global pointer to the currently running program.
// Set during Program.run(), cleared on exit.
// Safe because only one program can run at a time (one terminal).
Program* g_program = null;

fn Msg make_quit_msg() @local {
	return { .kind = MsgKind.QUIT };
}

fn Msg make_batch_msg() @local {
	return { .kind = MsgKind.BATCH };
}

// tick_msg creates a TICK message for animation/timers.
fn Msg tick_msg() {
	return { .kind = MsgKind.TICK };
}

// Common cursor characters.
const String CURSOR_BLOCK     = "\xe2\x96\x88"; // █
const String CURSOR_UNDERLINE = "\xe2\x96\x84"; // ▄
const String CURSOR_BAR       = "\xe2\x96\x82"; // ▂

// batch collects non-null Cmds and returns a Cmd that dispatches them concurrently.
// Uses the global program pointer to store the batch, which is safe because
// batch() is always called from within the event loop (during model.Update).
<*
 @require cmds.len > 0
 @require cmds.len <= MAX_BATCH
*>
fn Cmd batch(Cmd[] cmds) {
	Cmd[MAX_BATCH] filtered;
	int count = 0;
	for (sz i = 0; i < cmds.len && count < MAX_BATCH; i++) {
		if (cmds[i] != null) {
			filtered[count] = cmds[i];
			count++;
		}
	}
	if (count == 0) return null;
	if (count == 1) return filtered[0];
	if (g_program == null) return filtered[0];
	for (int i = 0; i < count; i++) {
		g_program.batch_cmds[g_program.batch_count++] = filtered[i];
	}
	return &make_batch_msg;
}

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
// Thread-safe for the single-producer case (call from any goroutine).
// In test mode, the message is placed in a ring buffer consumed by run().
fn void Program.send(Program* self, Msg msg) {
	int next = (self.send_head + 1) % (int)MAX_BATCH;
	if (next == self.send_tail) return; // full, drop
	self.send_queue[self.send_head] = msg;
	self.send_head = next;
}

// send_recv dequeues a previously sent message. Returns true if a message
// was available, false if the queue is empty.
fn bool Program.send_recv(Program* self, Msg* out) {
	if (self.send_tail == self.send_head) return false;
	*out = self.send_queue[self.send_tail];
	self.send_tail = (self.send_tail + 1) % (int)MAX_BATCH;
	return true;
}

// dispatch processes a message through the model, returning true if QUIT was seen.
fn bool dispatch(Program* self, Model model, Msg m) @local {
	if (m.kind == MsgKind.QUIT) return true;
	if (m.kind == MsgKind.BATCH) {
		Cmd[MAX_BATCH] cmds;
		int count = self.batch_count;
		for (sz i = 0; i < count; i++) cmds[i] = self.batch_cmds[i];
		self.batch_count = 0;
		for (int i = 0; i < count; i++) {
			Msg sub = cmds[i]();
			if (sub.kind != MsgKind.NONE) {
				if (dispatch(self, model, sub)) return true;
			}
		}
		return false;
	}
	Cmd c     = model.update(m);
	int chain = 0;
	while (c != null && chain < MAX_BATCH) {
		Msg next = c();
		if (next.kind == MsgKind.QUIT) return true;
		if (next.kind == MsgKind.NONE) break;
		if (next.kind == MsgKind.BATCH) {
			if (dispatch(self, model, next)) return true;
			break;
		}
		c = model.update(next);
		chain++;
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

// tick registers a timer that fires after delay_ms.
// Default: 16ms (~60fps) sending a TICK message.
fn Cmd tick(sz delay_ms = 16, Cmd callback = &tick_msg) {
	if (g_program == null) return null;
	sz deadline = time_ms() + delay_ms;
	for (sz i = 0; i < MAX_TIMERS; i++) {
		if (!g_program.timers[i].active) {
			g_program.timers[i].active = true;
			g_program.timers[i].deadline_ms = deadline;
			g_program.timers[i].callback = callback;
			break;
		}
	}
	return null;
}

// run executes the event loop for the program.
fn void? Program.run(Program* self) {
	g_program = self;
	self.batch_count = 0;
	self.pending_len = 0;
	self.in_alt_screen = false;
	self.send_head = 0;
	self.send_tail = 0;
	for (sz i = 0; i < MAX_TIMERS; i++) {
		self.timers[i] = { };
	}
	defer {
		g_program = null;
	}

	TtyState saved;
	if (!self.test_mode) {
		saved = raw_mode_enter()!;
		hide_cursor();
		enable_focus();
		setup_signals(saved, &self.in_alt_screen);

		// Start the reader thread so stdin reads never block the event loop.
		input_queue_init(&g_input_queue)!;
		thread::Thread.create(&self.reader_thread, &input_reader_fn, &g_input_queue)!!;
	}

	// Defers live at function scope so they run after the event loop exits,
	// not when the if-block above closes (C3 defer is block-scoped).
	defer {
		if (!self.test_mode) {
			if (self.renderer != null) {
				self.renderer.destroy();
				mem::free(self.renderer);
			}
			input_queue_destroy(&g_input_queue);
			disable_mouse();
			disable_focus();
			show_cursor();
			write_stdout((char[])OSC_CURSOR_COLOR_RESET);
			write_stdout((char[])OSC_MOUSE_CURSOR_RESET);
			// For inline (non-alt-screen) mode: move cursor below the last rendered
			// content so the shell prompt appears on a clean line after the app exits.
			if (!self.in_alt_screen && self.last_content_rows > 0) {
				write_stdout((char[])string::tformat("\x1b[%d;1H\x1b[m\r\n", self.last_content_rows));
			}
			raw_mode_restore(saved);
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
				self.timers[i].active = false;
				Msg m = cb();
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
		}

		// Drain Send()-injected messages
		Msg injected;
		while (self.send_recv(&injected)) {
			if (dispatch(self, self.model, injected)) return;
			dirty = true;
		}

		if (!self.test_mode && g_win_resized) {
			g_win_resized = false;
			WinSize ws = get_window_size();
			if (self.renderer != null) {
				self.renderer.resize((sz)ws.ws_col, (sz)ws.ws_row);
			}
			Msg wm = { .kind = MsgKind.WINDOW_SIZE, .window_size = { (int)ws.ws_col, (int)ws.ws_row } };
			if (dispatch(self, self.model, wm)) return;
			dirty = true;
		}

		if (n > 0) {
			for (sz i = 0; i < n && self.pending_len < self.pending.len; i++) {
				self.pending[self.pending_len++] = tmp[(sz)i];
			}
		}

		bool stuck = false;
		while (self.pending_len > 0) {
			ParseResult pr = parse_key(self.pending[:self.pending_len]);
			if (pr.consumed == 0) {
				stuck = true;
				break;
			}

			// Log raw input bytes and parsed result to stderr (TEA_DEBUG=1)
			if (self.debug) {
				io::eprintfn(
					"INPUT consumed=%d kind=%d key=%d rune='%c' mouse_btn=%d mouse_act=%d",
					(int)pr.consumed,
					(int)pr.kind,
					(int)pr.key.code,
					pr.key.rune,
					(int)pr.mouse.button,
					(int)pr.mouse.action
				);
				io::eprintf("  raw:");
				for (sz bi = 0; bi < pr.consumed && bi < self.pending_len; bi++) {
					io::eprintf(" %02x", (int)self.pending[bi]);
				}
				io::eprintf("\n");
			}

			for (sz i = pr.consumed; i < self.pending_len; i++) {
				self.pending[i - pr.consumed] = self.pending[i];
			}
			self.pending_len -= pr.consumed;

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
			} else {
				m.kind = MsgKind.KEY;
				m.key = pr.key;
			}
			if (dispatch(self, self.model, m)) return;
			dirty = true;
		}

		if (dirty) {
			self.render_current_view();
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
			// When stuck on incomplete data, cap wait to avoid long hangs
			if (stuck && wait_ms > 100) wait_ms = 100;
			if (wait_ms > 0) {
				input_queue_wait(&g_input_queue, wait_ms);
			}
		}
	}
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
				disable_mouse();
			} else {
				enable_mouse();
			}
			self.mouse_mode = v.mouse_mode;
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
					// String path — clear buffer then parse ANSI content line by line
					r.screen.clear();
					String content = v.content;
					sz row         = 0;
					sz col         = 0;
					sz line_start  = 0;
					for (sz i = 0; i <= content.len; i++) {
						if (i == content.len || content[i] == '\n') {
							sz line_len = i - line_start;
							if (line_len > 0) {
								String line = content[line_start:line_len];
								// Strip leading \r if present



								if (line.len > 0 && line[0] == '\r') {
									line = line[1..];
								}
								// Use ANSI parser to handle glaze SGR sequences
								r.screen.render_ansi_string(col, row, line, xray::default_style());
							}
							row++;
							col = 0;
							line_start = i + 1;
						}
					}
					self.last_content_rows = row;
				}

				// Handle cursor
				if (v.has_cursor) {
					// Cursor position is set via CUP after render,
					// so we mark the cursor cell in the screen buffer
					// (the renderer will emit CUP at end_frame)
				}

				r.end_frame();

				// Emit OSC 22 mouse cursor shape when it changes.
				if (v.mouse_cursor != self.last_mouse_cursor) {
					if (v.mouse_cursor.len > 0) {
						write_stdout((char[])mouse_cursor_seq(v.mouse_cursor));
					} else {
						write_stdout((char[])OSC_MOUSE_CURSOR_RESET);
					}
					self.last_mouse_cursor = v.mouse_cursor;
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