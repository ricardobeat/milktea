module taro;
import milktea;
import xray;
import glaze;
import std::io;
import std::io::file;
import std::core::mem;
import std::core::dstring;

struct JsModel {
	Runtime rt;
	void* js_model_obj;
	int term_w;
	int term_h;
	bool mem_profile;
	long frame_count;
	io::File profile_file;
	bool profile_file_open;
	xray::ScreenBuffer* screen;
}

// ── Native debug event log ─────────────────────────────────────────────────
// Active when globalThis.__debug = true (set via --debug CLI flag).
// Records the last N events for display in a debug panel at screen bottom.

const int DEBUG_MAX_EVENTS = 32;

struct DebugEvent {
	long seq;
	milktea::MsgKind kind;
	// Key fields
	milktea::KeyCode key_code;
	char key_rune;
	bool key_ctrl;
	bool key_alt;
	bool key_shift;
	// Mouse fields
	milktea::MouseButton mouse_button;
	milktea::MouseAction mouse_action;
	int mouse_row;
	int mouse_col;
}

struct DebugLog {
	bool enabled;
	DebugEvent[DEBUG_MAX_EVENTS] events;
	int count;
	long seq;
}

DebugLog g_debug_log = { };

// ── Timing stats ring buffer (5s window) ───────────────────────────────────
const int TIMING_MAX = 512;

struct TimingSample {
	long js_ms;
	long vnode_ms;
}

struct TimingStats {
	TimingSample[TIMING_MAX] buf;
	int head;
	int count;
}

TimingStats g_timing = { };

fn void timing_push(long js_ms, long vnode_ms) {
	TimingSample s = { .js_ms = js_ms, .vnode_ms = vnode_ms };
	g_timing.buf[g_timing.head] = s;
	g_timing.head = (g_timing.head + 1) % TIMING_MAX;
	if (g_timing.count < TIMING_MAX) g_timing.count++;
}

struct TimingAgg {
	long avg_js;
	long avg_vnode;
	long peak_js;
	long peak_vnode;
	int n;
}

fn TimingAgg timing_agg() {
	long sum_js = 0;
	long sum_vn = 0;
	long peak_js = 0;
	long peak_vn = 0;
	int n = g_timing.count;
	int start = n >= TIMING_MAX ? g_timing.head : 0;
	for (int i = 0; i < n; i++) {
		TimingSample s = g_timing.buf[(start + i) % TIMING_MAX];
		sum_js += s.js_ms;
		sum_vn += s.vnode_ms;
		if (s.js_ms > peak_js) peak_js = s.js_ms;
		if (s.vnode_ms > peak_vn) peak_vn = s.vnode_ms;
	}
	return {
		.avg_js = n > 0 ? sum_js / n : 0,
		.avg_vnode = n > 0 ? sum_vn / n : 0,
		.peak_js = peak_js,
		.peak_vnode = peak_vn,
		.n = n,
	};
}

fn void debug_log_init() {
	g_debug_log.enabled = false;
	g_debug_log.count = 0;
	g_debug_log.seq = 0;
}

fn void debug_log_event(milktea::Msg msg) {
	if (!g_debug_log.enabled) return;
	if (msg.kind == milktea::MsgKind.TICK) return;
	DebugEvent e = { };
	e.seq = g_debug_log.seq++;
	e.kind = msg.kind;
	if (msg.kind == milktea::MsgKind.KEY) {
		e.key_code = msg.key.code;
		e.key_rune = msg.key.rune;
		e.key_ctrl = msg.key.ctrl;
		e.key_alt = msg.key.alt;
		e.key_shift = msg.key.shift;
	}
	if (msg.kind == milktea::MsgKind.MOUSE) {
		e.mouse_button = msg.mouse.button;
		e.mouse_action = msg.mouse.action;
		e.mouse_row = msg.mouse.row;
		e.mouse_col = msg.mouse.col;
	}
	if (g_debug_log.count < DEBUG_MAX_EVENTS) {
		g_debug_log.events[g_debug_log.count++] = e;
	} else {
		// Shift left
		for (int i = 0; i < DEBUG_MAX_EVENTS - 1; i++) {
			g_debug_log.events[i] = g_debug_log.events[i + 1];
		}
		g_debug_log.events[DEBUG_MAX_EVENTS - 1] = e;
	}
}

fn String msgkind_str(milktea::MsgKind k) {
	switch (k) {
		case milktea::MsgKind.KEY: return "KEY";
		case milktea::MsgKind.MOUSE: return "MOUSE";
		case milktea::MsgKind.TICK: return "TICK";
		case milktea::MsgKind.WINDOW_SIZE: return "WSIZE";
		case milktea::MsgKind.QUIT: return "QUIT";
		case milktea::MsgKind.FOCUS: return "FOCUS";
		case milktea::MsgKind.BLUR: return "BLUR";
		case milktea::MsgKind.NONE: return "NONE";
		default: return "???";
	}
}

fn String debug_event_str(DebugEvent* e) {
	DString ds = dstring::temp();
	ds.append_string(msgkind_str(e.kind));
	if (e.kind == milktea::MsgKind.KEY) {
		ds.append_char(' ');
		switch (e.key_code) {
			case milktea::KeyCode.UP: ds.append_string("UP");
			case milktea::KeyCode.DOWN: ds.append_string("DOWN");
			case milktea::KeyCode.LEFT: ds.append_string("LEFT");
			case milktea::KeyCode.RIGHT: ds.append_string("RIGHT");
			case milktea::KeyCode.ENTER: ds.append_string("ENTER");
			case milktea::KeyCode.TAB: ds.append_string("TAB");
			case milktea::KeyCode.ESC: ds.append_string("ESC");
			case milktea::KeyCode.BACKSPACE: ds.append_string("BS");
			case milktea::KeyCode.DELETE: ds.append_string("DEL");
			case milktea::KeyCode.HOME: ds.append_string("HOME");
			case milktea::KeyCode.END: ds.append_string("END");
			case milktea::KeyCode.PAGE_UP: ds.append_string("PGUP");
			case milktea::KeyCode.PAGE_DOWN: ds.append_string("PGDN");
			case milktea::KeyCode.INSERT: ds.append_string("INS");
			case milktea::KeyCode.F1: ds.append_string("F1");
			case milktea::KeyCode.F2: ds.append_string("F2");
			case milktea::KeyCode.F3: ds.append_string("F3");
			case milktea::KeyCode.F4: ds.append_string("F4");
			case milktea::KeyCode.F5: ds.append_string("F5");
			case milktea::KeyCode.F6: ds.append_string("F6");
			case milktea::KeyCode.F7: ds.append_string("F7");
			case milktea::KeyCode.F8: ds.append_string("F8");
			case milktea::KeyCode.F9: ds.append_string("F9");
			case milktea::KeyCode.F10: ds.append_string("F10");
			case milktea::KeyCode.F11: ds.append_string("F11");
			case milktea::KeyCode.F12: ds.append_string("F12");
			case milktea::KeyCode.CTRL_C: ds.append_string("C-c");
			case milktea::KeyCode.RUNE:
				if (e.key_rune == ' ') {
					ds.append_string("SPACE");
				} else {
					ds.append_char(e.key_rune);
				}
			default: ds.append_string("??");
		}
		if (e.key_ctrl) ds.append_string(" C");
		if (e.key_alt) ds.append_string(" A");
		if (e.key_shift) ds.append_string(" S");
	}
	if (e.kind == milktea::MsgKind.MOUSE) {
		ds.append_char(' ');
		switch (e.mouse_button) {
			case milktea::MouseButton.MOUSE_LEFT: ds.append_string("L");
			case milktea::MouseButton.MOUSE_MIDDLE: ds.append_string("M");
			case milktea::MouseButton.MOUSE_RIGHT: ds.append_string("R");
			default: ds.append_string("-");
		}
		ds.append_char(' ');
		switch (e.mouse_action) {
			case milktea::MouseAction.MOUSE_PRESS: ds.append_string("press");
			case milktea::MouseAction.MOUSE_RELEASE: ds.append_string("rel");
			case milktea::MouseAction.MOUSE_MOTION: ds.append_string("motion");
			default: ds.append_string("??");
		}
		ds.append_char(' ');
		ds.append_string(string::tformat("%d,%d", e.mouse_row, e.mouse_col));
	}
	return ds.str_view();
}

// Render the debug event log as an overlay at the bottom of the screen.
fn void render_debug_overlay(xray::ScreenBuffer* screen, int screen_w, int screen_h) {
	if (!g_debug_log.enabled) return;

	TimingAgg agg = timing_agg();

	// Build panel content
	DString body = dstring::temp();
	body.append_string(string::tformat("js  avg=%d pk=%d", (int)agg.avg_js, (int)agg.peak_js));
	body.append_string("\n");
	body.append_string(string::tformat("vn  avg=%d pk=%d", (int)agg.avg_vnode, (int)agg.peak_vnode));
	body.append_string("\n");
	body.append_string(string::tformat("frames=%d", agg.n));

	// Show last 6 non-tick events
	int show = 6;
	int ev_start = g_debug_log.count > show ? g_debug_log.count - show : 0;
	for (int i = ev_start; i < g_debug_log.count; i++) {
		DebugEvent* e = &g_debug_log.events[i];
		body.append_string("\n");
		body.append_string(debug_event_str(e));
	}

	String content = body.str_view();
	glaze::Style panel = glaze::new_style()
		.set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#444444"))
		.foreground(glaze::color_hex("#aaaaaa"))
		.set_width(26);
	String rendered = panel.render(content);

	// Count rendered lines to size the overlay
	int lines = 1;
	for (sz i = 0; i < rendered.len; i++) {
		if (rendered[i] == '\n') lines++;
	}

	sz px = screen_w >= 28 ? (sz)(screen_w - 28) : 0;
	sz py = 0;
	screen.blit_ansi(px, py, 26, (sz)lines + 2, rendered, false);
}

// Requested tick delay from the last render pass. -1 means no tick requested.
// Components call request_render_tick() during render_vnode to register a wakeup.
long g_render_tick_ms = -1;

fn void request_render_tick(long delay_ms) {
	if (g_render_tick_ms < 0 || delay_ms < g_render_tick_ms) {
		g_render_tick_ms = delay_ms;
	}
}

fn milktea::Cmd JsModel.init(&self) @dynamic {
	// Check if --debug flag was set via globalThis.__debug
	void* debug_val = self.rt.get_global_prop("__debug");
	if (debug_val != null && !self.rt.is_null(debug_val)) {
		g_debug_log.enabled = true;
	}
	if (debug_val != null) self.rt.free_value(debug_val);

	// Check if HW_MEMPROFILE env var is set
	if (taro_memprofile_enabled()) self.mem_profile = true;

	if (self.mem_profile) {
		if (try f = file::open("profile.log", "w")) {
			self.profile_file = f;
			self.profile_file_open = true;
			io::fprintfn(&self.profile_file, "frame,qjs_used,qjs_obj,qjs_str,shim_allocs,shim_frees,shim_bytes,process_rss_kb");
		} else {
			io::eprintfn("Warning: could not open profile.log for writing");
			self.mem_profile = false;
		}
	}

	void* fn_val = self.rt.get_prop(self.js_model_obj, "init");
	if (fn_val != null) {
		if (self.rt.is_function(fn_val)) {
			void* result = self.rt.call0(fn_val, self.js_model_obj);
			self.rt.execute_jobs();
			if (result != null) self.rt.free_value(result);
		}
		self.rt.free_value(fn_val);
	}
	return self.js_tick_cmd();
}

fn milktea::Cmd JsModel.update(&self, milktea::Msg msg) @dynamic {
	// Debug: log every event
	debug_log_event(msg);

	// Forward mouse scroll events to native viewports before JS
	if (msg.kind == milktea::MsgKind.MOUSE) {
		String button = "";
		String action = "";
		switch (msg.mouse.button) {
			case milktea::MouseButton.MOUSE_LEFT: button = "left";
			case milktea::MouseButton.MOUSE_MIDDLE: button = "middle";
			case milktea::MouseButton.MOUSE_RIGHT: button = "right";
			case milktea::MouseButton.MOUSE_WHEEL_UP: button = "wheel_up";
			case milktea::MouseButton.MOUSE_WHEEL_DOWN: button = "wheel_down";
			default: button = "none";
		}
		switch (msg.mouse.action) {
			case milktea::MouseAction.MOUSE_PRESS: action = "press";
			case milktea::MouseAction.MOUSE_RELEASE: action = "release";
			case milktea::MouseAction.MOUSE_MOTION: action = "motion";
			default: action = "press";
		}
		if (viewport_dispatch_mouse(msg.mouse.row, msg.mouse.col, button, action)) {
			return self.js_tick_cmd();
		}
	}

	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.term_w = msg.window_size.width;
		self.term_h = msg.window_size.height;
	}

	// On every tick, run timers and drain fetch responses
	if (msg.kind == milktea::MsgKind.TICK) {
		self.rt.run_timers();
		self.rt.drain_fetch();
		// If a timer/fetch callback called milktea.quit(), honor it
		void* quit_flag  = self.rt.get_global_prop("__taro_quit");
		bool should_quit = quit_flag != null && !self.rt.is_null(quit_flag) && self.rt.to_string(quit_flag) == "true";
		if (quit_flag != null) self.rt.free_value(quit_flag);
		if (should_quit) return milktea::quit();
	}

	// If there's a pending JS error, only allow esc/q to quit (clears error and quits)
	ZString pending_err = taro_last_error();
	if (pending_err) {
		if (msg.kind == milktea::MsgKind.KEY) {
			milktea::KeyMsg k = msg.key;
			bool is_quit  = k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'q');
			if (is_quit) {
				taro_clear_error();
				return milktea::quit();
			}
		}
		return self.js_tick_cmd();
	}

	void* fn_val = self.rt.get_prop(self.js_model_obj, "update");
	if (fn_val == null || !self.rt.is_function(fn_val)) {
		if (fn_val != null) self.rt.free_value(fn_val);
		return self.js_tick_cmd();
	}

	void* js_msg = msg_to_js(&self.rt, msg);
	void* result = self.rt.call1(fn_val, self.js_model_obj, js_msg);
	self.rt.free_value(fn_val);
	self.rt.free_value(js_msg);
	self.rt.execute_jobs();

	milktea::Cmd cmd = js_value_to_cmd(&self.rt, result);
	if (cmd != null) return cmd;
	return self.js_tick_cmd();
}

// js_tick_cmd schedules the next tick based on JS runtime state and render requests.
// Returns null (idle) when nothing needs a wakeup.
fn milktea::Cmd JsModel.js_tick_cmd(&self) @inline {
	if (self.rt.is_job_pending()) return milktea::tick(1);
	if (self.rt.has_pending_fetch()) return milktea::tick(1);
	long next_ms = self.rt.next_timer_ms();
	// Take the minimum of JS timer deadline and render-requested tick



	if (g_render_tick_ms >= 0) {
		if (next_ms < 0 || g_render_tick_ms < next_ms) next_ms = g_render_tick_ms;
	}
	if (next_ms < 0) return null;
	sz delay = next_ms < 1 ? 1 : (sz)next_ms;
	return milktea::tick(delay);
}

fn milktea::View JsModel.view(&self) @dynamic {
	int w = self.term_w > 0 ? self.term_w : 80;
	int h = self.term_h > 0 ? self.term_h : 24;

	long t_js_start = taro_now_ms();
	void* fn_val = self.rt.get_prop(self.js_model_obj, "view");
	void* result = null;
	if (fn_val != null && self.rt.is_function(fn_val)) {
		result = self.rt.call0(fn_val, self.js_model_obj);
		self.rt.free_value(fn_val);
	} else {
		if (fn_val != null) self.rt.free_value(fn_val);
	}
	long t_js_ms = taro_now_ms() - t_js_start;

	// vnode path: walk the tree, fill a ScreenBuffer, return cell view
	// Always use screen buffer so we can overlay errors on top
	// Reuse persistent screen buffer to avoid dangling pointers (the View's
	// cells slice must outlive this function call — the renderer reads it
	// after view() returns).
	if (self.screen == null) {
		self.screen = xray::new_screen_buffer((sz)w, (sz)h);
	} else if ((int)self.screen.width != w || (int)self.screen.height != h) {
		self.screen.resize((sz)w, (sz)h);
	}
	self.screen.clear();
	xray::Rect area = xray::new_rect(0, 0, w, h);

	if (result != null && is_vnode(&self.rt, result)) {
		g_render_tick_ms = -1;
		reset_focused_cursor();
		long t_vnode_start = taro_now_ms();
		render_vnode(&self.rt, result, self.screen, area);
		long t_vnode_ms = taro_now_ms() - t_vnode_start;
		if (g_debug_log.enabled) {
			timing_push(t_js_ms, t_vnode_ms);
		}
		self.rt.free_value(result);
	} else if (result != null) {
		// string path (legacy): render as text into screen buffer
		ZString cstr = taro_to_cstring(self.rt.ctx, result);
		self.rt.free_value(result);
		if (cstr) {
			String content = string::tformat("%s", cstr.str_view());
			taro_free_cstring(self.rt.ctx, cstr);
			self.screen.render_ansi_string(0, 0, content, xray::default_style());
		}
	}

	// Error overlay: always render last JS error as a red bordered box at the bottom
	ZString err = taro_last_error();
	if (err) {
		String err_str = err.str_view();
		glaze::Style err_style = glaze::new_style().set_border(glaze::rounded_border())
			.set_border_fg(glaze::color_hex("#ff0000"))
			.foreground(glaze::color_hex("#ff6666"))
			.set_width(w - 2);
		String rendered = err_style.render(err_str);
		int line_count  = 1;
		for (sz i = 0; i < rendered.len; i++) {
			if (rendered[i] == '\n') line_count++;
		}
		int overlay_y = h - line_count;
		if (overlay_y < 0) overlay_y = 0;
		self.screen.render_ansi_string(1, (sz)overlay_y, rendered, xray::default_style());
	}

	// Debug event log overlay
	if (g_debug_log.enabled) {
		render_debug_overlay(self.screen, w, h);
	}

	milktea::View view = milktea::new_alt_cell_view(self.screen.cells[0:self.screen.width * self.screen.height], self.screen.width, self.screen.height);
	view.mouse_mode = milktea::MouseMode.MOUSE_MODE_CELL_MOTION;

	int cx, cy;
	String cursor_color;
	bool suppress_native;
	if (get_focused_cursor(&cx, &cy, &cursor_color, &suppress_native) && !suppress_native) {
		view = view.set_cursor_shape(cx, cy, milktea::CursorShape.CURSOR_BLOCK, true);
		if (cursor_color.len > 0) {
			view = view.set_cursor_color(cursor_color);
		}
	}



	// Memory profiling: log per-frame stats to profile.log
	if (self.mem_profile && self.profile_file_open) {
		MemStats ms = self.rt.mem_stats();
		long rss = taro_rss_kb();
		self.frame_count++;
		io::fprintfn(&self.profile_file, "%d,%d,%d,%d,%d,%d,%d,%d",
			self.frame_count,
			ms.qjs_memory_used,
			ms.qjs_obj_count,
			ms.qjs_str_count,
			ms.shim_malloc_count,
			ms.shim_free_count,
			ms.shim_malloc_bytes,
			rss);
	}

	return view;
}

fn void JsModel.on_destroy(&self) @dynamic {
	if (self.profile_file_open) {
		self.profile_file.close();
	}
	if (self.screen != null) {
		self.screen.destroy();
		mem::free(self.screen);
	}
	self.rt.free_value(self.js_model_obj);
	self.rt.free();
}

fn JsModel? load_js_model(String js_src, String filename = "<input>") {
	Runtime rt = taro::new_runtime()!;

	taro_fetch_init();
	rt.register_globals();

	// Always evaluate milktea.js as a global script first — sets up globalThis.tea,
	// globalThis.h, console, setInterval, etc. The "milktea" ES module re-exports
	// these same objects, so both script and module users share one instance.
	String stdlib_str = (String)$embed("milktea.js");
	if (!rt.eval(stdlib_str)) {
		rt.free();
		return JS_ERROR~;
	}

	bool ok;
	if (rt.is_module(js_src)) {
		ok = rt.eval_module(js_src, filename);
	} else {
		ok = rt.eval(js_src);
	}
	if (!ok) {
		rt.free();
		return JS_ERROR~;
	}

	// Module-mode scripts call milktea.run(model) which sets globalThis.__taro_model,
	// same as script mode — the global object is shared.
	void* model_obj = rt.get_global_prop("__taro_model");
	if (model_obj == null || rt.is_null(model_obj)) {
		if (model_obj != null) rt.free_value(model_obj);
		io::eprintfn("taro: script did not call milktea.run(model)");
		rt.free();
		return JS_ERROR~;
	}

	return { .rt = rt, .js_model_obj = model_obj };
}