module taro;
import milktea;
import xray;
import glaze;
import std::io;
import std::core::mem;
import std::core::dstring;

struct JsModel {
	Runtime rt;
	void* js_model_obj;
	int term_w;
	int term_h;
	bool mem_profile;
	long frame_count;
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

fn void debug_log_init() {
	g_debug_log.enabled = false;
	g_debug_log.count = 0;
	g_debug_log.seq = 0;
}

fn void debug_log_event(milktea::Msg msg) {
	if (!g_debug_log.enabled) return;
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

	glaze::Style header_style = glaze::new_style().foreground(glaze::color_hex("#888888")).set_width(screen_w);
	String header = header_style.render(
		"── debug events ──────────────────────────────────────────"
	);
	screen.render_ansi_string(0, 0, header, xray::default_style());

	int max_lines = screen_h - 1;
	int start     = 0;
	if (g_debug_log.count > max_lines) start = g_debug_log.count - max_lines;
	int row = 1;
	for (int i = start; i < g_debug_log.count && row < screen_h; i++, row++) {
		DebugEvent* e = &g_debug_log.events[i];
		DString line  = dstring::temp();
		String num    = string::tformat("%4d ", (int)e.seq);
		line.append_string(num);
		line.append_string(debug_event_str(e));

		glaze::Style s = glaze::new_style().foreground(glaze::color_hex("#aaaaaa")).set_width(screen_w);
		screen.render_ansi_string(0, (sz)row, s.render(line.str_view()), xray::default_style());
	}
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

	// Check if --memprofile flag was set via globalThis.__memprofile or HW_MEMPROFILE env
	if (taro_memprofile_enabled()) self.mem_profile = true;
	void* memprofile_val = self.rt.get_global_prop("__memprofile");
	if (memprofile_val != null && !self.rt.is_null(memprofile_val)) {
		self.mem_profile = true;
	}
	if (memprofile_val != null) self.rt.free_value(memprofile_val);

	if (self.mem_profile) {
		io::eprintfn("MEMPROFILE:frame,qjs_used,qjs_obj,qjs_str,shim_allocs,shim_frees,shim_bytes,process_rss_kb");
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
	if (g_debug_log.enabled) io::eprintfn("DEBUG update: kind=%d", (int)msg.kind);

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
	if (g_debug_log.enabled) io::eprintfn("DEBUG update: calling JS update");
	void* result = self.rt.call1(fn_val, self.js_model_obj, js_msg);
	if (g_debug_log.enabled) io::eprintfn("DEBUG update: JS update done");
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
	if (g_debug_log.enabled) io::eprintfn("DEBUG view: start");
	int w = self.term_w > 0 ? self.term_w : 80;
	int h = self.term_h > 0 ? self.term_h : 24;

	if (g_debug_log.enabled) io::eprintfn("DEBUG view: calling JS view");
	void* fn_val = self.rt.get_prop(self.js_model_obj, "view");
	void* result = null;
	if (fn_val != null && self.rt.is_function(fn_val)) {
		result = self.rt.call0(fn_val, self.js_model_obj);
		self.rt.free_value(fn_val);
	} else {
		if (fn_val != null) self.rt.free_value(fn_val);
	}
	if (g_debug_log.enabled) io::eprintfn("DEBUG view: JS view done");

	// vnode path: walk the tree, fill a ScreenBuffer, return cell view
	// Always use screen buffer so we can overlay errors on top
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);
	xray::Rect area            = xray::new_rect(0, 0, w, h);

	if (result != null && is_vnode(&self.rt, result)) {
		g_render_tick_ms = -1;
		reset_focused_cursor();
		if (g_debug_log.enabled) io::eprintfn("DEBUG view: render_vnode start");
		render_vnode(&self.rt, result, screen, area);
		if (g_debug_log.enabled) io::eprintfn("DEBUG view: render_vnode done");
		self.rt.free_value(result);
	} else if (result != null) {
		// string path (legacy): render as text into screen buffer
		ZString cstr = taro_to_cstring(self.rt.ctx, result);
		self.rt.free_value(result);
		if (cstr) {
			String content = string::tformat("%s", cstr.str_view());
			taro_free_cstring(self.rt.ctx, cstr);
			screen.render_ansi_string(0, 0, content, xray::default_style());
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
		screen.render_ansi_string(1, (sz)overlay_y, rendered, xray::default_style());
	}

	// Debug event log overlay
	if (g_debug_log.enabled) {
		render_debug_overlay(screen, w, h);
	}

	milktea::View view = milktea::new_alt_cell_view(screen.cells[0:screen.width * screen.height], screen.width, screen.height);
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

	screen.destroy();
	mem::free(screen);

	// Memory profiling: log per-frame stats to stderr
	if (self.mem_profile) {
		MemStats ms = self.rt.mem_stats();
		long rss = taro_rss_kb();
		self.frame_count++;
		io::eprintfn("MEMPROFILE:%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld",
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