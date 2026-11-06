// milktea_gui runs any milktea Model in a window instead of a terminal: the
// same Model, the same view() tree, drawn on the GPU through sokol. A build
// opts in by adding gui/** to its sources (see the *-gui examples), so a
// terminal build links none of it.
//
// The window and its event loop belong to sokol_app, which calls back once
// per display refresh. Each call is one pass of milktea's loop (step):
// messages, timers, a new view if anything changed, then the last frame
// composited onto the window. A screenshot run does the same passes with no
// window at all, drawing offscreen and writing the first settled frame out.
module milktea_gui;

import milktea;
import xray;
import std::collections::list;
import std::core::mem;
import std::io;
import std::io::file;
import std::math;
import std::os::env;
import std::thread;
import std::time;

struct GuiOptions {
	String title;
	int cols;
	int rows;
	int cell_w;
	int cell_h;
	int font_size;
	float font_height_ratio; // ascent-to-descent height / em; 0 keeps pixel-height sizing
	bool undecorated; // no title bar or frame; corners as corner_radius says
	float corner_radius; // points; 0 = square corners. Implies undecorated.
	// When set, the first settled frame is written to this path as a PNG and
	// run() returns. It is drawn offscreen with no window, through the same
	// font and renderer, so a view can be inspected with nobody at the
	// keyboard.
	String screenshot_path;
	// chrome_rows puts the top N cell rows in place of the platform title
	// bar: the window keeps its buttons but loses the title bar, and a press
	// in those rows (or on a node marked window_drag) moves the window.
	int chrome_rows;
	// Height in points of the strip the window buttons are centred on, for a
	// top bar taller than its rows; 0 is chrome_rows rows. set_chrome_height
	// changes it while running.
	int chrome_height;
	// Takes the close/minimise/zoom buttons away along with the title bar,
	// for a window whose own top row offers its own. Only meaningful with
	// chrome_rows set.
	bool hide_window_buttons;
}

fn GuiOptions default_options() {
	return {
		.title = "milktea",
		.cols = 80, .rows = 24,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
	};
}

// Monospace fonts to try, in order, when MILKTEA_FONT is unset. A leading
// "~/" expands against $HOME. None is required: with none of them present
// the platform's own monospace font is used.
const String[*] FONT_PATHS = {
	"~/Library/Fonts/JetBrainsMono[wght].ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/Library/Fonts/JetBrainsMono-Regular.ttf",
};

// How far the window buttons reach from the window's left edge, in points:
// an estimate for an app that lays out before there is a window, replaced
// by the real edge as soon as the buttons have been placed.
const int CHROME_BUTTONS_RIGHT = 66;

// The state of the one GUI run. sokol's callbacks are plain functions, so it
// lives here rather than on run()'s stack.
struct Gui {
	milktea::Model m;
	GuiOptions opts;
	milktea::Program prog;
	bool headless;
	float scale;
	int fb_w;
	int fb_h;
	float win_w; // points
	float win_h;
	float font_ratio;
	String font_path;
	bool dirty;
	bool quit;
	// The last view's cells and paint stream, to tell an unchanged frame
	// from a new one without drawing it.
	xray::Cell[] prev_cells;
	xray::PaintOp[] prev_paint;
	bool drawn;
	// Pointer, in points; -1 when it is outside the window.
	float ptr_x;
	// The left button is down, and the cell the last motion message named,
	// for MOUSE_MODE_CELL_MOTION.
	bool button_down;
	sz motion_col;
	sz motion_row;
	float ptr_y;
	float wheel;
	// Requests from the app, picked up at the top of the next pass.
	bool size_request;
	int req_cell_w;
	int req_cell_h;
	int req_font_size;
	// MILKTEA_DEBUG_KEY_AT.
	milktea::KeyMsg test_key;
	long test_key_frame;
	bool test_key_armed;
	int buttons_right;
	List{xray::Rect} drag_regions;
}

Gui g @private = { .font_ratio = 1.0f, .buttons_right = CHROME_BUTTONS_RIGHT, .ptr_x = -1, .ptr_y = -1 };

// ---- app-facing API -------------------------------------------------------

// set_cell_size asks for a new cell size and point size from the next pass
// on. The window keeps its size; the model hears how many cells now fit
// through an ordinary WINDOW_SIZE message. Values below 1 are ignored.
fn void set_cell_size(int cell_w, int cell_h, int font_size) {
	if (cell_w < 1 || cell_h < 1 || font_size < 1) return;
	g.req_cell_w = cell_w;
	g.req_cell_h = cell_h;
	g.req_font_size = font_size;
	g.size_request = true;
}

// set_font switches to the font at path (or named path, on platforms that
// look fonts up by name) along with a new cell size. An empty path goes back
// to the default fonts.
fn void set_font(String path, int cell_w, int cell_h, int font_size, float height_ratio = 1.0f) {
	if (cell_w < 1 || cell_h < 1 || font_size < 1) return;
	String next = path.len ? path.copy(mem) : "";
	if (g.font_path.ptr) mem::free(g.font_path);
	g.font_path = next;
	g.font_ratio = height_ratio > 0 ? height_ratio : 1.0f;
	set_cell_size(cell_w, cell_h, font_size);
}

// chrome_inset_cells is how many cells of the first row the window buttons
// cover, so an app can start its own top bar after them.
fn int chrome_inset_cells(int cell_w) {
	if (cell_w < 1) return 0;
	return (g.buttons_right + cell_w - 1) / cell_w;
}

// set_chrome_height re-centres the window buttons on a top bar of this
// many points (0: chrome_rows rows), as an app does when its bar's height
// follows its text size.
fn void set_chrome_height(int points) {
	if (points == g.opts.chrome_height) return;
	g.opts.chrome_height = points;
	if (g.headless || g.opts.chrome_rows <= 0) return;
	int br = mt_window_inline_titlebar(chrome_row_height(), g.opts.hide_window_buttons ? 1 : 0);
	if (br >= 0) g.buttons_right = br;
}

fn int chrome_row_height() @private {
	return g.opts.chrome_height > 0 ? g.opts.chrome_height : g.opts.cell_h * g.opts.chrome_rows;
}

fn void minimize_window() {
	if (!g.headless) mt_window_minimize();
}

// toggle_zoom fills the screen with the window, or puts it back.
fn void toggle_zoom() {
	if (!g.headless) mt_window_zoom();
}

fn bool is_zoomed() => !g.headless && mt_window_is_zoomed() != 0;

// ---- fonts ----------------------------------------------------------------

fn String expand_home(String path) @private {
	if (!path.starts_with("~/")) return path;
	String? home = env::tget_var("HOME");
	if (catch home) return "";
	return string::tformat("%s%s", home, path[1..]);
}

// font_spec picks the font to load. MILKTEA_FONT, or a font the app set,
// wins outright even when it is a name rather than a file: someone who named
// a font wants that one. Otherwise the first of FONT_PATHS that exists.
fn String font_spec() @private {
	if (g.font_path.len) return expand_home(g.font_path);
	if (try want = env::tget_var("MILKTEA_FONT")) {
		if (want.len > 0) return expand_home(want);
	}
	foreach (p : FONT_PATHS) {
		String e = expand_home(p);
		if (e.len > 0 && file::exists(e)) return e;
	}
	return "";
}

// load_fonts opens the text face, and a face for box-drawing rules when the
// cell is taller than the text, at the current device scale, and works out
// where in a cell each one sits.
fn void load_fonts() @private {
	GuiOptions o = g.opts;
	float s = g.scale;
	bool smooth = false;
	if (try v = env::tget_var("MILKTEA_FONT_SMOOTH")) smooth = v == "1";
	ZString spec = font_spec().zstr_tcopy();
	float ratio = g.font_ratio;
	void* text = mt_font_open(spec, math::round(o.font_size * s * ratio), smooth ? 1 : 0);
	bool split = o.font_size != o.cell_h;
	void* rule = split ? mt_font_open(spec, o.cell_h * s, smooth ? 1 : 0) : text;
	if (text == null) io::eprintn("milktea-gui: no font could be loaded; text will not draw");
	atlas_set_faces(text, rule);
	g_paint.scale = s;
	g_paint.cell_w = o.cell_w;
	g_paint.cell_h = o.cell_h;
	g_paint.rule_split = split;
	g_paint.text_fit = cell_fit(Face.TEXT, o.font_size, ratio);
	g_paint.rule_fit = split ? cell_fit(Face.RULE, o.cell_h, 1.0f) : g_paint.text_fit;
}

fn CellFit cell_fit(Face face, int font_size, float ratio) @private {
	float advance = atlas_glyph(face, 'M').advance / g.scale;
	CellFit fit;
	fit.dx = (int)((g.opts.cell_w - advance) * 0.5f + 0.5f);
	fit.dy = (int)((g.opts.cell_h - font_size * ratio) * 0.5f);
	if (fit.dx < 0) fit.dx = 0;
	if (fit.dy < 0) fit.dy = 0;
	return fit;
}

// ---- milktea glue ---------------------------------------------------------

// dispatch sends msg to the model and runs the Cmd chain it returns, the
// way Program.run() does; this loop drives update() by hand. Returns true
// when the model asked to quit.
fn bool dispatch(milktea::Msg msg) @private {
	g.dirty = true;
	if (msg.kind == milktea::MsgKind.QUIT) return true;
	if (msg.kind == milktea::MsgKind.KEY && milktea::dispatch_focus_key(msg.key)) return false;
	milktea::g_program.stamp_now();
	milktea::Cmd c = g.m.update(msg);
	int chain = 0;
	while (c != null && chain < milktea::MAX_BATCH) {
		milktea::Msg next = c();
		if (next.kind == milktea::MsgKind.QUIT) return true;
		if (next.kind == milktea::MsgKind.NONE) break;
		milktea::g_program.stamp_now();
		c = g.m.update(next);
		chain++;
	}
	return false;
}

fn void send(milktea::Msg msg) @private {
	if (!g.quit && dispatch(msg)) g.quit = true;
}

fn void collect_drag_regions(xray::Node* root) @private {
	if (!g.drag_regions.is_initialized()) g.drag_regions.init(mem);
	g.drag_regions.clear();
	xray::collect_drag_regions(root, &g.drag_regions);
}

// pixel_area is the area draw() lays a tree out in: the whole window, or for
// an inline tree only as tall as its content, capped at the window.
fn xray::Rect pixel_area(xray::Node* root, bool alt) @private {
	milktea::Program* p = milktea::g_program;
	if (alt) return p.layout_area;
	root.set_layout_metrics(p.layout_metrics);
	sz height = root.natural_height(p.layout_area.w);
	if (height < 1) height = 1;
	if (height > p.layout_area.h) height = p.layout_area.h;
	return xray::new_rect(0, 0, p.layout_area.w, height);
}

// is_drag_point answers whether a press here (points) moves the window. A
// view that marked nodes window_drag decides entirely; otherwise the
// chrome rows do.
fn bool is_drag_point(float x, float y) @private {
	if (g.drag_regions.len() > 0) {
		foreach (r : g.drag_regions) {
			if (r.contains((sz)x, (sz)y)) return true;
		}
		return false;
	}
	return g.opts.chrome_rows > 0 && x >= 0 && y >= 0 && y < (float)(g.opts.chrome_rows * g.opts.cell_h);
}

fn void clipboard_write(String text) @private {
	mt_clipboard_write(text.ptr, text.len);
}

fn String? clipboard_read() @private {
	char* s = mt_clipboard_read();
	if (s == null) return milktea::NO_CLIPBOARD~;
	defer mt_free(s);
	return ((ZString)s).str_view().tcopy();
}

fn sz cell_of(float v, int unit) @private => v < 0 ? -1 : xray::floor_cell((sz)v, unit);

fn milktea::MouseMsg mouse_at(milktea::MouseButton b, milktea::MouseAction a) @private {
	return { .button = b, .action = a,
		.row = cell_of(g.ptr_y, g.opts.cell_h), .col = cell_of(g.ptr_x, g.opts.cell_w) };
}

// ---- keys -------------------------------------------------------------------

faultdef NO_KEY;

// sokol's key codes are GLFW's.
const int KEY_SPACE = 32;
const int KEY_0 = 48;
const int KEY_MINUS = 45;
const int KEY_EQUAL = 61;
const int KEY_A = 65;
const int KEY_Z = 90;
const int KEY_ESCAPE = 256;
const int KEY_ENTER = 257;
const int KEY_TAB = 258;
const int KEY_BACKSPACE = 259;
const int KEY_INSERT = 260;
const int KEY_DELETE = 261;
const int KEY_RIGHT = 262;
const int KEY_LEFT = 263;
const int KEY_DOWN = 264;
const int KEY_UP = 265;
const int KEY_PAGE_UP = 266;
const int KEY_PAGE_DOWN = 267;
const int KEY_HOME = 268;
const int KEY_END = 269;
const int KEY_F1 = 290;
const int KEY_F12 = 301;
const int KEY_KP_0 = 320;
const int KEY_KP_SUBTRACT = 333;
const int KEY_KP_ADD = 334;
const int KEY_KP_ENTER = 335;

const milktea::KeyCode[12] FKEYS = {
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
};

// translate_key maps a key press to a KeyMsg, or NO_KEY for one milktea has
// no code for. Letters normally arrive as text (CHAR events), which keeps
// typing right for every keyboard layout. With ctrl or super held they make
// no text, so they are made here as the RUNE the terminal path emits:
// lowercase, the modifier set, and plain ctrl+c narrowed to CTRL_C.
fn milktea::KeyMsg? translate_key(int key, uint mods) @private {
	milktea::KeyMsg k = {
		.ctrl = (mods & MOD_CTRL) != 0,
		.alt = (mods & MOD_ALT) != 0,
		.shift = (mods & MOD_SHIFT) != 0,
		.super = (mods & MOD_SUPER) != 0,
	};
	switch (key) {
		case KEY_ENTER:
		case KEY_KP_ENTER: k.code = ENTER;
		case KEY_BACKSPACE: k.code = BACKSPACE;
		case KEY_ESCAPE: k.code = ESC;
		case KEY_TAB: k.code = TAB;
		case KEY_UP: k.code = UP;
		case KEY_DOWN: k.code = DOWN;
		case KEY_LEFT: k.code = LEFT;
		case KEY_RIGHT: k.code = RIGHT;
		case KEY_HOME: k.code = HOME;
		case KEY_END: k.code = END;
		case KEY_DELETE: k.code = DELETE;
		case KEY_INSERT: k.code = INSERT;
		case KEY_PAGE_UP: k.code = PAGE_UP;
		case KEY_PAGE_DOWN: k.code = PAGE_DOWN;
		default:
			if (key >= KEY_F1 && key <= KEY_F12) {
				k.code = FKEYS[key - KEY_F1];
				return k;
			}
			if (!k.ctrl && !k.super) return NO_KEY~;
			// The punctuation an app is likeliest to want a chord on. Keypad
			// and main row give the same rune, the way a terminal does.
			uint punct = 0;
			switch (key) {
				case KEY_MINUS:
				case KEY_KP_SUBTRACT: punct = '-';
				case KEY_EQUAL:
				case KEY_KP_ADD: punct = '=';
				case KEY_0:
				case KEY_KP_0: punct = '0';
				case KEY_SPACE: punct = ' ';
				default:
			}
			if (punct != 0) {
				k.code = RUNE;
				k.rune = punct;
				return k;
			}
			if (key >= KEY_A && key <= KEY_Z) {
				uint lower = (uint)(key - KEY_A) + 'a';
				if (lower == 'c' && k.ctrl && !k.alt && !k.shift && !k.super) {
					k.code = CTRL_C;
					return k;
				}
				k.code = RUNE;
				k.rune = lower;
				return k;
			}
			return NO_KEY~;
	}
	return k;
}

// ---- events ---------------------------------------------------------------

fn void on_event(MtEvent* e) @private {
	if (g.quit) return;
	switch (e.type) {
		case KEY_DOWN:
			if (try k = translate_key(e.key, e.mods)) send({ .kind = milktea::MsgKind.KEY, .key = k });
		case CHAR:
			// ctrl and super chords are made from the key itself above.
			if ((e.mods & (MOD_CTRL | MOD_SUPER)) != 0) return;
			if (e.ch < 32 || e.ch == 127) return;
			// Shift is already in the character ('A' against 'a'); reporting
			// it again would make every capital look modified.
			milktea::KeyMsg k = { .code = RUNE, .rune = e.ch, .alt = (e.mods & MOD_ALT) != 0 };
			send({ .kind = milktea::MsgKind.KEY, .key = k });
		case MOUSE_MOVE:
			pointer_to(e.x, e.y);
		case MOUSE_LEAVE:
			pointer_to(-1, -1);
		case MOUSE_DOWN:
			pointer_to(e.x, e.y);
			if (e.button != 0) return;
			g.button_down = true;
			g.motion_col = cell_of(g.ptr_x, g.opts.cell_w);
			g.motion_row = cell_of(g.ptr_y, g.opts.cell_h);
			// Same order as the terminal loop: the press settles hover, the
			// click reaches its target against the last frame's layout, and
			// then the model gets the raw message.
			milktea::dispatch_click((sz)g.ptr_x, (sz)g.ptr_y);
			milktea::dispatch_hover((sz)g.ptr_x, (sz)g.ptr_y);
			send({ .kind = milktea::MsgKind.MOUSE, .mouse = mouse_at(MOUSE_LEFT, MOUSE_PRESS) });
			if (!g.quit && !g.headless && is_drag_point(g.ptr_x, g.ptr_y)) {
				// AppKit moves the window until the button comes up and eats
				// the release, so it is sent here instead.
				mt_window_drag();
				g.button_down = false;
				send({ .kind = milktea::MsgKind.MOUSE, .mouse = mouse_at(MOUSE_LEFT, MOUSE_RELEASE) });
			}
		case MOUSE_UP:
			pointer_to(e.x, e.y);
			if (e.button == 0) g.button_down = false;
			if (e.button == 0) send({ .kind = milktea::MsgKind.MOUSE, .mouse = mouse_at(MOUSE_LEFT, MOUSE_RELEASE) });
		case SCROLL:
			g.wheel += e.scroll_y;
		case RESIZED:
		case FOCUSED:
		case UNFOCUSED:
			g.dirty = true;
		case QUIT_REQUESTED:
			g.quit = true;
		default:
	}
}

// pointer_to moves the pointer. A move redraws only when something under
// it reacts — a hover style or hover callback going in or out — and reaches
// the model only if it asked for motion, as in a terminal: every move with
// MOUSE_MODE_ALL_MOTION, moves to another cell with a button held with
// MOUSE_MODE_CELL_MOTION, none otherwise.
fn void pointer_to(float x, float y) @private {
	if (x == g.ptr_x && y == g.ptr_y) return;
	g.ptr_x = x;
	g.ptr_y = y;
	if (milktea::dispatch_hover(x < 0 ? -1 : (sz)x, y < 0 ? -1 : (sz)y)) g.dirty = true;
	if (x < 0 || y < 0) return;
	milktea::MouseMsg mm = mouse_at(g.button_down ? MOUSE_LEFT : MOUSE_NONE, MOUSE_MOTION);
	milktea::MouseMode mode = milktea::g_program.want_mouse_mode;
	if (mode == MOUSE_MODE_NONE) return;
	if (mode == MOUSE_MODE_CELL_MOTION) {
		if (!g.button_down || (mm.col == g.motion_col && mm.row == g.motion_row)) return;
	}
	g.motion_col = mm.col;
	g.motion_row = mm.row;
	send({ .kind = milktea::MsgKind.MOUSE, .mouse = mm });
}

// ---- the loop -------------------------------------------------------------

// shot_owed reports a screenshot run whose scheduled test events have all
// fired, so the frame it has is the one to keep.
fn bool shot_owed() @private {
	return g.headless && g.drawn && !milktea::g_program.test_click_armed
		&& !milktea::g_program.test_pointer_armed && !g.test_key_armed;
}

fn void measure_window() @private {
	if (g.headless) {
		g.win_w = (float)g.opts.cols * g.opts.cell_w;
		g.win_h = (float)g.opts.rows * g.opts.cell_h;
		g.fb_w = (int)math::round(g.win_w * g.scale);
		g.fb_h = (int)math::round(g.win_h * g.scale);
		return;
	}
	g.fb_w = mt_fb_width();
	g.fb_h = mt_fb_height();
	g.win_w = g.fb_w / g.scale;
	g.win_h = g.fb_h / g.scale;
}

// step runs one pass of the loop. It returns false when the run is over.
fn bool step() @private {
	milktea::Program* p = &g.prog;
	// Messages from outside the loop: milktea::send from another thread, or
	// request_quit() from a callback with no Cmd to return.
	milktea::Msg sent;
	while (!g.quit && p.send_recv(&sent)) {
		if (sent.kind != milktea::MsgKind.NONE) send(sent);
	}
	if (g.quit) return false;

	sz now = milktea::time_ms();
	for (sz i = 0; i < milktea::MAX_TIMERS && !g.quit; i++) {
		if (p.timers[i].active && now >= p.timers[i].deadline_ms) {
			milktea::Cmd cb = p.timers[i].callback;
			void* owner = p.timers[i].owner;
			p.timers[i].active = false;
			g.dirty = true;
			milktea::Msg tmsg = cb();
			tmsg.owner = owner;
			if (tmsg.kind != milktea::MsgKind.NONE) send(tmsg);
			now = milktea::time_ms();
		}
	}
	if (g.quit) return false;

	// A cell size request and a resize answer the same question, how many
	// cells fit, so the request only swaps the fonts and cell size and lets
	// the size check below do the rest.
	bool regrid = false;
	if (g.size_request) {
		g.size_request = false;
		g.opts.cell_w = g.req_cell_w;
		g.opts.cell_h = g.req_cell_h;
		g.opts.font_size = g.req_font_size;
		load_fonts();
		if (!g.headless && g.opts.chrome_rows > 0) {
			int br = mt_window_inline_titlebar(chrome_row_height(), g.opts.hide_window_buttons ? 1 : 0);
			if (br >= 0) g.buttons_right = br;
		}
		regrid = true;
	}

	int old_fb_w = g.fb_w;
	int old_fb_h = g.fb_h;
	measure_window();
	p.layout_metrics = xray::pixel_metrics(g.opts.cell_w, g.opts.cell_h);
	p.layout_area = { .w = (sz)g.win_w, .h = (sz)g.win_h };
	if (regrid || g.fb_w != old_fb_w || g.fb_h != old_fb_h) {
		g.dirty = true;
		int cols = math::max((int)g.win_w / g.opts.cell_w, 1);
		int rows = math::max((int)g.win_h / g.opts.cell_h, 1);
		if (regrid || cols != g.opts.cols || rows != g.opts.rows) {
			g.opts.cols = cols;
			g.opts.rows = rows;
			p.cached_ws.ws_col = (ushort)cols;
			p.cached_ws.ws_row = (ushort)rows;
			send({ .kind = milktea::MsgKind.WINDOW_SIZE, .window_size = { cols, rows } });
			if (g.quit) return false;
		}
	}

	if (g.wheel != 0) {
		milktea::MouseButton b = g.wheel > 0 ? MOUSE_WHEEL_UP : MOUSE_WHEEL_DOWN;
		g.wheel = 0;
		send({ .kind = milktea::MsgKind.MOUSE, .mouse = mouse_at(b, MOUSE_PRESS) });
	}

	// Test events count passes of the loop, not frames drawn: a script asks
	// for "frame N" to mean N passes in, which an idle loop still makes.
	p.frame_no++;
	if (p.test_click_armed && p.frame_no >= p.test_pending_click_frame) {
		sz tc = p.test_pending_click_col;
		sz tr = p.test_pending_click_row;
		p.test_click_armed = false;
		io::eprintfn("[test] frame %d: click col=%d row=%d, %d targets", p.frame_no, tc, tr, p.click_targets.len());
		milktea::dispatch_click(tc * g.opts.cell_w, tr * g.opts.cell_h);
		send({ .kind = milktea::MsgKind.MOUSE, .mouse = { .button = MOUSE_LEFT, .action = MOUSE_PRESS, .row = tr, .col = tc } });
	}
	if (p.test_pointer_armed && p.frame_no >= p.test_pending_pointer_frame) {
		sz pc = p.test_pending_pointer_col;
		sz pr = p.test_pending_pointer_row;
		p.test_pointer_armed = false;
		io::eprintfn("[test] frame %d: pointer col=%d row=%d", p.frame_no, pc, pr);
		milktea::dispatch_hover(pc * g.opts.cell_w, pr * g.opts.cell_h);
		send({ .kind = milktea::MsgKind.MOUSE, .mouse = { .button = MOUSE_NONE, .action = MOUSE_MOTION, .row = pr, .col = pc } });
	}
	if (g.test_key_armed && p.frame_no >= g.test_key_frame) {
		g.test_key_armed = false;
		io::eprintfn("[test] frame %d: key code=%d rune=%d", p.frame_no, (int)g.test_key.code, (int)g.test_key.rune);
		send({ .kind = milktea::MsgKind.KEY, .key = g.test_key });
	}
	if (g.quit) return false;

	if (g.dirty) {
		g.dirty = false;
		p.stamp_now();
		milktea::View v = milktea::draw(g.m.view());
		p.schedule_repaint(v.repaint_ms);
		if (!unchanged(v)) {
			remember(v);
			g_paint.paint_view(v);
			g_paint.submit(g.fb_w, g.fb_h);
			g.drawn = true;
			if (g.headless) mt_commit();
		}
	}
	if (shot_owed()) {
		if (mt_write_png(g.opts.screenshot_path.zstr_tcopy()) != 0) {
			io::eprintfn("milktea-gui: could not write %s", g.opts.screenshot_path);
		}
		return false;
	}
	return true;
}

fn bool unchanged(milktea::View v) @private {
	if (!g.drawn) return false;
	sz count = v.cells.ptr != null ? v.cells_width * v.cells_height : 0;
	if (g.prev_paint.len != v.paint_ops.len || !mem::equals(g.prev_paint, v.paint_ops)) return false;
	if (count != g.prev_cells.len) return false;
	return count == 0 || mem::equals(g.prev_cells, v.cells[:count]);
}

fn void remember(milktea::View v) @private {
	sz count = v.cells.ptr != null ? v.cells_width * v.cells_height : 0;
	if (g.prev_cells.len != count) {
		if (g.prev_cells.ptr) mem::free(g.prev_cells);
		g.prev_cells = count > 0 ? mem::new_array(xray::Cell, count) : {};
	}
	if (count > 0) g.prev_cells[..] = v.cells[:count];
	if (g.prev_paint.len != v.paint_ops.len) {
		if (g.prev_paint.ptr) mem::free(g.prev_paint);
		g.prev_paint = v.paint_ops.len > 0 ? mem::new_array(xray::PaintOp, v.paint_ops.len) : {};
	}
	if (v.paint_ops.len > 0) g.prev_paint[..] = v.paint_ops[..];
}

// ---- start and stop -------------------------------------------------------

// start sets the program up once there is somewhere to draw, and runs the
// model's init. Returns false if the model quit before its first frame.
fn bool start() @private {
	milktea::Program* p = &g.prog;
	xray::enable_paint_recording();
	p.record_paint = true;
	p.on_draw = &collect_drag_regions;
	p.pixel_area = &pixel_area;
	p.cached_ws.ws_col = (ushort)g.opts.cols;
	p.cached_ws.ws_row = (ushort)g.opts.rows;
	milktea::g_program = p;
	// The send queue, armed the way Program.run() arms it: the mutex before
	// the flag, so a sender that sees the flag sees a working mutex.
	p.send_head = 0;
	p.send_tail = 0;
	p.send_mu.init()!!;
	p.send_accepting.store(true);
	milktea::use_clipboard(&clipboard_write, &clipboard_read);
	if (g.opts.font_height_ratio > 0) g.font_ratio = g.opts.font_height_ratio;

	if (!g.headless) {
		// macOS rounds the corners of any titled window, title bar hidden or
		// not, so a borderless one is also made transparent: its corners are
		// then whatever the frame draws, square at corner_radius 0.
		bool borderless = g.opts.undecorated || g.opts.corner_radius > 0;
		mt_window_setup(borderless ? 1 : 0, borderless ? 1 : 0,
			g.opts.cell_w * 4, g.opts.cell_h * 4);
		if (g.opts.chrome_rows > 0) {
			int br = mt_window_inline_titlebar(chrome_row_height(), g.opts.hide_window_buttons ? 1 : 0);
			if (br >= 0) g.buttons_right = br;
		}
	}
	load_fonts();
	measure_window();
	p.layout_metrics = xray::pixel_metrics(g.opts.cell_w, g.opts.cell_h);
	p.layout_area = { .w = (sz)g.win_w, .h = (sz)g.win_h };
	read_debug_env();

	p.stamp_now();
	milktea::Cmd c = g.m.init();
	int chain = 0;
	while (c != null && chain < milktea::MAX_BATCH) {
		milktea::Msg next = c();
		if (next.kind == milktea::MsgKind.QUIT) return false;
		if (next.kind == milktea::MsgKind.NONE) break;
		p.stamp_now();
		c = g.m.update(next);
		chain++;
	}
	// Program.run() tells the model its size before the first frame; a model
	// that caches it in init() would otherwise lay out for the wrong window.
	int cols = math::max((int)g.win_w / g.opts.cell_w, 1);
	int rows = math::max((int)g.win_h / g.opts.cell_h, 1);
	g.opts.cols = cols;
	g.opts.rows = rows;
	p.cached_ws.ws_col = (ushort)cols;
	p.cached_ws.ws_row = (ushort)rows;
	send({ .kind = milktea::MsgKind.WINDOW_SIZE, .window_size = { cols, rows } });
	g.dirty = true;
	return !g.quit;
}

fn void stop() @private {
	milktea::Program* p = &g.prog;
	if (g.prev_cells.ptr) mem::free(g.prev_cells);
	if (g.prev_paint.ptr) mem::free(g.prev_paint);
	g.prev_cells = {};
	g.prev_paint = {};
	if (p.draw_buf != null && p.draw_buf.paint_ops.is_initialized()) p.draw_buf.paint_ops.free();
	p.click_targets.free();
	if (g.drag_regions.is_initialized()) g.drag_regions.free();
	g_paint.free();
	atlas_free();
	if (g.font_path.ptr) mem::free(g.font_path);
	g.font_path = "";
	// The mirror of Program.run()'s teardown: stop accepting, wait for
	// senders already past their check, then destroy the mutex.
	p.send_accepting.store(false);
	while (p.send_inflight.load() > 0) thread::yield();
	p.send_mu.destroy();
	if (p.send_queue.len > 0) {
		alloc::free(&allocators::LIBC_ALLOCATOR, p.send_queue.ptr);
		p.send_queue = {};
	}
	milktea::g_program = null;
}

fn void app_init() @private {
	g.scale = mt_dpi_scale();
	if (g.scale <= 0) g.scale = 1;
	if (!start()) {
		g.quit = true;
		mt_quit();
	}
}

fn void app_frame() @private {
	if (!g.quit && !step()) g.quit = true;
	if (g.quit) {
		mt_quit();
		return;
	}
	mt_present(g.opts.corner_radius * g.scale);
}

fn void app_cleanup() @private {
	stop();
}

// run drives m in a window until the window closes or the model quits. With
// a screenshot_path it draws offscreen instead, writes the first settled
// frame, and returns.
//
// On macOS a windowed run ends the process when the window closes, the way
// an app does, so run() does not return to its caller.
fn void run(milktea::Model m, GuiOptions opts = default_options()) {
	g.m = m;
	g.opts = opts;
	g.quit = false;
	g.dirty = true;
	// MILKTEA_GUI_SHOT=<path> takes a screenshot of any GUI app, the way
	// screenshot_path does, without the app asking for one.
	if (opts.screenshot_path.len == 0) {
		if (try shot = env::tget_var("MILKTEA_GUI_SHOT")) g.opts.screenshot_path = shot;
	}
	if (g.opts.screenshot_path.len > 0) {
		run_headless();
		return;
	}
	g.headless = false;
	mt_run(opts.title.zstr_tcopy(), opts.cols * opts.cell_w, opts.rows * opts.cell_h,
		&app_init, &app_frame, &on_event, &app_cleanup);
}

// The most passes a screenshot run makes before it writes what it has: a
// view that never settles (an animation, a timer that keeps re-arming)
// still gets a picture.
const int SHOT_MAX_PASSES = 600;

fn void run_headless() @private {
	g.headless = true;
	if (mt_headless_begin() != 0) {
		io::eprintn("milktea-gui: no Metal device for an offscreen run");
		return;
	}
	g.scale = mt_screen_scale();
	if (g.scale < 1) g.scale = 1;
	if (start()) {
		for (int i = 0; i < SHOT_MAX_PASSES; i++) {
			if (!step()) break;
			thread::sleep_ms(4);
			if (i == SHOT_MAX_PASSES - 1 && g.drawn) {
				mt_write_png(g.opts.screenshot_path.zstr_tcopy());
			}
		}
	}
	stop();
	mt_headless_end();
	g.headless = false;
}

// ---- debug ------------------------------------------------------------------

// read_debug_env honours the MILKTEA_DEBUG_* variables. Tests prefer the
// programmatic API (milktea::test_click and friends); these are the shortest
// way to ask a running app from the shell what a click or key does.
fn void read_debug_env() @private {
	if (try dbg = env::tget_var("MILKTEA_DEBUG_MOUSE")) milktea::set_debug_mouse(dbg.len > 0);
	if (try at = env::tget_var("MILKTEA_DEBUG_CLICK_AT")) {
		sz col; sz row; long delay;
		if (parse_at(at, &col, &row, &delay)) milktea::test_click(col, row, delay);
	}
	if (try at = env::tget_var("MILKTEA_DEBUG_POINTER_AT")) {
		sz col; sz row; long delay;
		if (parse_at(at, &col, &row, &delay)) milktea::test_pointer(col, row, delay);
	}
	// "<key>,<frame>": a name (up/down/left/right/enter/esc/tab/backspace/
	// space) or one character, which arrives as a rune.
	if (try at = env::tget_var("MILKTEA_DEBUG_KEY_AT")) {
		sz comma = 0;
		foreach (i, ch : at) {
			if (ch == ',') {
				comma = i;
				break;
			}
		}
		String name = comma > 0 ? at[:comma] : at;
		long frame = comma > 0 ? (at[comma + 1..].to_int() ?? 2) : 2;
		milktea::KeyMsg k = {};
		switch (name) {
			case "up": k.code = UP;
			case "down": k.code = DOWN;
			case "left": k.code = LEFT;
			case "right": k.code = RIGHT;
			case "enter": k.code = ENTER;
			case "esc": k.code = ESC;
			case "tab": k.code = TAB;
			case "backspace": k.code = BACKSPACE;
			case "space":
				k.code = RUNE;
				k.rune = ' ';
			default:
				if (name.len == 1) {
					k.code = RUNE;
					k.rune = (uint)name[0];
				} else {
					io::eprintfn("[test] MILKTEA_DEBUG_KEY_AT: unknown key \"%s\"", name);
				}
		}
		if (k.code != NONE) {
			g.test_key = k;
			g.test_key_frame = frame;
			g.test_key_armed = true;
		}
	}
}

// parse_at reads "col,row[,frame]".
fn bool parse_at(String at, sz* col, sz* row, long* frame) @private {
	sz c1 = 0;
	sz c2 = 0;
	foreach (i, ch : at) {
		if (ch != ',') continue;
		if (c1 == 0) {
			c1 = i;
		} else {
			c2 = i;
		}
	}
	if (c1 == 0) return false;
	*col = at[:c1].to_int() ?? 0;
	*row = (c2 > 0 ? at[c1 + 1 : c2 - c1 - 1] : at[c1 + 1..]).to_int() ?? 0;
	*frame = c2 > 0 ? (at[c2 + 1..].to_int() ?? 2) : 2;
	return true;
}
