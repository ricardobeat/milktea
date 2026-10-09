module milktea @feat(MILKTEA_WEB);

import std::core::mem;
import xray;

bool web_running;
bool web_dirty;
View web_view;
sz web_cols = 80;
sz web_rows = 24;

fn void? Program.run(&self) {
	assert(g_program == null, "Only one browser program per WASM instance");
	g_program = mem::@clone(*self);
	Program* p = g_program;
	p.cached_ws = { .ws_col = (ushort)web_cols, .ws_row = (ushort)web_rows,
		.cell_w_px = (ushort)g_cell_w_px, .cell_h_px = (ushort)g_cell_h_px, .cell_px_known = true };
	p.in_alt_screen = p.options.alt_screen;
	p.want_mouse_mode = p.options.mouse_mode;
	p.want_mouse_pixels = p.options.mouse_pixels;
	p.want_report_key_events = p.options.report_key_events;
	set_mouse_cursor(p.options.mouse_cursor);
	web_running = true;
	web_dirty = true;
	p.stamp_now();
	Cmd cmd = p.model.init();
	if (cmd) { Msg msg = cmd(); if (msg.kind != NONE) web_dispatch(msg); }
	if (web_running && &p.model.on_mount) { p.stamp_now(); p.model.on_mount(); }
	if (web_running) web_dispatch({ .kind = WINDOW_SIZE, .window_size = { web_cols, web_rows } });
}

fn void Program.send(&self, Msg msg) {
	sz next = (self.send_head + 1) % MAX_BATCH;
	if (next == self.send_tail) return;
	self.send_queue[self.send_head] = msg;
	self.send_head = next;
}

fn void web_dispatch(Msg msg) @private {
	if (!web_running) return;
	if (msg.kind == FOCUS && &g_program.model.on_focus) g_program.model.on_focus();
	if (msg.kind == BLUR && &g_program.model.on_blur) g_program.model.on_blur();
	if (dispatch(g_program, g_program.model, msg)) web_running = false;
	web_dirty = true;
}

// Called once per animation frame. Timer callbacks run inside the same pool
// as update/view; pixels live in Program.draw_buf after the pool is released.
fn int web_frame() @wasm("mt_frame") {
	if (!web_running) return 0;
	@pool() {
		Program* p = g_program;
		// Paint startup before zero-delay timers, matching the terminal loop.
		if (web_view.cells.ptr == null) {
			p.stamp_now();
			web_view = draw(p.model.view());
			p.schedule_repaint(web_view.repaint_ms);
			web_dirty = false;
			return 2;
		}
		// Snapshot due timers so callbacks rearming a slot cannot fire twice.
		bool[MAX_TIMERS] due;
		sz now = time_ms();
		for (sz i = 0; i < MAX_TIMERS; i++) due[i] = p.timers[i].active && p.timers[i].deadline_ms <= now;
		for (sz i = 0; i < MAX_TIMERS && web_running; i++) {
			if (!due[i] || !p.timers[i].active || p.timers[i].deadline_ms > now) continue;
			TimerEntry t = p.timers[i];
			p.timers[i].active = false;
			Msg m = t.callback();
			m.owner = t.owner;
			if (m.kind != NONE) web_dispatch(m);
			web_dirty = true;
		}
		for (sz n = 0; n < MAX_BATCH && web_running && p.send_tail != p.send_head; n++) {
			Msg m = p.send_queue[p.send_tail];
			p.send_tail = (p.send_tail + 1) % MAX_BATCH;
			web_dispatch(m);
		}
		if (!web_running) return 0;
		if (web_dirty) {
			p.stamp_now();
			web_view = draw(p.model.view());
			p.schedule_repaint(web_view.repaint_ms);
			web_dirty = false;
			return 2;
		}
	};
	return 1;
}

fn void web_stop() @wasm("mt_stop") {
	if (!g_program) return;
	web_running = false;
	@pool() {
		if (&g_program.model.on_destroy) g_program.model.on_destroy();
		if (web_cleanup) web_cleanup();
	};
	if (g_program.draw_buf) { g_program.draw_buf.destroy(); mem::free(g_program.draw_buf); }
	if (g_program.draw_scratch) { g_program.draw_scratch.destroy(); mem::free(g_program.draw_scratch); }
	mem::free((void*)g_program.model);
	mem::free(g_program);
	g_program = null;
	web_view = {};
}

fn void web_resize(sz cols, sz rows, sz cw, sz ch) @wasm("mt_resize") {
	web_cols = cols < 1 ? 1 : (cols > 512 ? 512 : cols);
	web_rows = rows < 1 ? 1 : (rows > 256 ? 256 : rows);
	g_cell_w_px = cw; g_cell_h_px = ch;
	if (!web_running) return;
	g_program.cached_ws = { .ws_col = (ushort)web_cols, .ws_row = (ushort)web_rows,
		.cell_w_px = (ushort)cw, .cell_h_px = (ushort)ch, .cell_px_known = true };
	@pool() { web_dispatch({ .kind = WINDOW_SIZE, .window_size = { web_cols, web_rows } }); };
}
fn void web_key(int code, uint rune, int mods, int action) @wasm("mt_key") {
	if (!web_running || code < 0 || code > KeyCode.CTRL_C.ordinal || action < 0 || action > 2) return;
	if (!g_program.want_report_key_events && action == 2) return;
	@pool() { web_dispatch({ .kind = KEY, .key = { .code = (KeyCode)code, .rune = rune,
		.ctrl = (mods & 1) != 0, .alt = (mods & 2) != 0, .shift = (mods & 4) != 0,
		.action = g_program.want_report_key_events ? (KeyAction)action : KEY_PRESS } }); };
}
fn void web_mouse(int button, int action, sz col, sz row, sz px, sz py, int mods) @wasm("mt_mouse") {
	if (!web_running || button < 0 || button > 5 || action < 0 || action > 2) return;
	MouseMode mode = g_program.want_mouse_mode;
	// Click handlers work without requiring raw mouse messages.
	if (mode == MOUSE_MODE_NONE) {
		if (action == 0 && button == 0) { @pool() { dispatch_click(col, row); }; web_dirty = true; }
		return;
	}
	if (action == 2 && button == 3 && mode != MOUSE_MODE_ALL_MOTION) return;
	@pool() { web_dispatch({ .kind = MOUSE, .mouse = {
		.button = (MouseButton)button, .action = (MouseAction)action, .col = col, .row = row,
		.px = g_program.want_mouse_pixels ? px : 0, .py = g_program.want_mouse_pixels ? py : 0,
		.ctrl = (mods & 1) != 0, .alt = (mods & 2) != 0, .shift = (mods & 4) != 0 } }); };
}
fn void web_focus(bool focused) @wasm("mt_focus") {
	@pool() { web_dispatch({ .kind = focused ? FOCUS : BLUR }); };
}
fn char* web_alloc(sz len) @wasm("mt_alloc") => mem::new_array(char, len);
fn void web_paste(char* ptr, sz len) @wasm("mt_paste") {
	@pool() { web_dispatch({ .kind = PASTE, .paste = (String)ptr[:len] }); };
	mem::free(ptr);
}

// Explicit accessors keep JS independent of C3's struct padding.
fn Cell* web_cells() @wasm("mt_cells") => web_view.cells.ptr;
fn sz web_width() @wasm("mt_width") => web_view.cells_width;
fn sz web_height() @wasm("mt_height") => web_view.cells_height;
fn sz web_cell_size() @wasm("mt_cell_size") => Cell::size;
fn sz web_style_offset() @wasm("mt_style_offset") { Cell c; return (sz)((char*)&c.style - (char*)&c); }
fn sz web_attrs_offset() @wasm("mt_attrs_offset") { Style s; return (sz)((char*)&s.attrs - (char*)&s); }
fn sz web_color_size() @wasm("mt_color_size") => Color::size;
fn int web_cursor_x() @wasm("mt_cursor_x") => web_view.has_cursor ? (int)web_view.cursor.x : -1;
fn int web_cursor_y() @wasm("mt_cursor_y") => (int)web_view.cursor.y;
fn int web_cursor_shape() @wasm("mt_cursor_shape") => web_view.cursor.shape.ordinal;
fn bool web_cursor_blink() @wasm("mt_cursor_blink") => web_view.cursor.blink;
fn char* web_mouse_cursor() @wasm("mt_mouse_cursor") => &g_program.want_mouse_cursor_buf[0];
fn sz web_mouse_cursor_len() @wasm("mt_mouse_cursor_len") => g_program.want_mouse_cursor_len;
