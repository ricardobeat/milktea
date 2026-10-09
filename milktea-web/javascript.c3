module milktea @feat(MILKTEA_JS);

import std::core::mem;
import std::core::string;
import glaze;
import dye;
import xray;

// Scalars and opaque node handles avoid exposing C3 struct layouts to JS.
extern fn bool js_init() @wasm("milktea_js", "init");
extern fn bool js_update(int kind, int a, int b, int c, int d, int e, int f, int g) @wasm("milktea_js", "update");
extern fn Node* js_view() @wasm("milktea_js", "view");
extern fn void js_destroy() @wasm("milktea_js", "destroy");

struct JavaScriptModel { int unused; }
fn Cmd JavaScriptModel.init(&self) @dynamic => js_init() ? quit() : null;
fn Cmd JavaScriptModel.update(&self, Msg msg) @dynamic {
	bool stop;
	switch (msg.kind) {
		case KEY:
			KeyMsg k = msg.key;
			stop = js_update(msg.kind.ordinal, k.code.ordinal, (int)k.rune,
				(k.ctrl ? 1 : 0) | (k.alt ? 2 : 0) | (k.shift ? 4 : 0), k.action.ordinal, 0, 0, 0);
		case WINDOW_SIZE:
			stop = js_update(msg.kind.ordinal, (int)msg.window_size.width, (int)msg.window_size.height, 0, 0, 0, 0, 0);
		case MOUSE:
			MouseMsg m = msg.mouse;
			stop = js_update(msg.kind.ordinal, m.button.ordinal, m.action.ordinal, (int)m.col, (int)m.row,
				(int)m.px, (int)m.py, (m.ctrl ? 1 : 0) | (m.alt ? 2 : 0) | (m.shift ? 4 : 0));
		case PASTE:
			stop = js_update(msg.kind.ordinal, (int)(usz)msg.paste.ptr, (int)msg.paste.len, 0, 0, 0, 0, 0);
		default:
			stop = js_update(msg.kind.ordinal, msg.tag, 0, 0, 0, 0, 0, 0);
	}
	return stop ? quit() : null;
}
fn Node* JavaScriptModel.view(&self) @dynamic => js_view();
fn void JavaScriptModel.on_destroy(&self) @dynamic { js_destroy(); }

fn void js_boot() @wasm("mt_boot") {
	@pool() {
		JavaScriptModel model;
		Program p = @program(&model, { .alt_screen = true, .mouse_mode = MOUSE_MODE_ALL_MOTION, .mouse_pixels = true });
		p.run()!!;
	};
}
fn void js_tick(sz ms) @wasm("mt_js_tick") { (void)tick(ms); }
fn void js_send(int tag) @wasm("mt_js_send") {
	if (g_program) g_program.send({ .kind = USER, .tag = tag });
}
fn void js_free(void* ptr) @wasm("mt_js_free") { mem::free(ptr); }

fn Node* js_text(char* ptr, sz len, int fg, int bg, int flags, int border, sz padding) @wasm("mt_js_text") {
	String content = string::tformat("%s", (String)ptr[:len]);
	mem::free(ptr);
	glaze::Style s;
	if (fg >= 0) s = s.foreground(dye::color_rgb((char)(fg >> 16), (char)(fg >> 8), (char)fg));
	if (bg >= 0) s = s.background(dye::color_rgb((char)(bg >> 16), (char)(bg >> 8), (char)bg));
	s = s.with_bold((flags & 1) != 0).with_italic((flags & 2) != 0).with_underline((flags & 4) != 0);
	if (border == 1) s = s.with_border(glaze::ROUNDED);
	if (border == 2) s = s.with_border(glaze::NORMAL);
	if (border == 3) s = s.with_border(glaze::DOUBLE);
	if (padding > 0) s = s.padding(padding, padding, padding, padding);
	return text(content, s);
}
fn Node* js_container(int direction) @wasm("mt_js_container") {
	switch (direction) { case 1: return hstack(); case 2: return zstack(); default: return vstack(); }
}
fn void js_add(Node* parent, Node* child) @wasm("mt_js_add") { parent.add(child); }
fn void js_click(void* ctx, sz col, sz row) @private {
	g_program.send({ .kind = USER, .tag = (int)(usz)ctx });
}
fn void js_node_options(Node* n, sz width, sz height, sz weight, sz gap, sz padding, bool centered, int click) @wasm("mt_js_node_options") {
	if (width >= 0) n.width(cells(width));
	if (height >= 0) n.height(cells(height));
	if (weight > 0) n.fill(weight);
	if (gap > 0) n.with_gap(gap);
	if (padding > 0) n.with_padding(padding, padding, padding, padding);
	if (centered) n.center();
	if (click) n.on_click(&js_click, (void*)(usz)click);
}

fn sz js_screen_width() @wasm("mt_screen_width") => web_cols;
fn sz js_screen_height() @wasm("mt_screen_height") => web_rows;
fn sz js_time() @wasm("mt_js_time") => frame_ms();
