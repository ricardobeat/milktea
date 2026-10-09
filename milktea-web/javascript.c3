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
	if (border == 4) s = s.with_border(glaze::THICK);
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

fn dye::Color js_rgb(int rgb) @private => dye::color_rgb((char)(rgb >> 16), (char)(rgb >> 8), (char)rgb);

// Keep animated borders in the normal string render path so xray's alpha
// compositor still blends the whole layer, including the border.
struct JavaScriptAnimatedText (xray::Content) { StyledText* text; }
fn ScreenBuffer* js_temp_buffer(sz w, sz h) @private {
	ScreenBuffer* b = mem::tnew(ScreenBuffer);
	b.width = w; b.height = h;
	b.cells = mem::temp_array(Cell, w * h);
	b.dirty_lines = mem::temp_array(bool, h);
	b.clear();
	return b;
}
fn String JavaScriptAnimatedText.render(&self, Rect r) @dynamic {
	if (r.w < 2 || r.h < 2) return self.text.render(r);
	ScreenBuffer* body = js_temp_buffer(r.w, r.h);
	ScreenBuffer* edge = js_temp_buffer(r.w, r.h);
	body.render_ansi_string(0, 0, self.text.render(r), xray::default_style(), r.h, r.w);
	glaze::Style s = self.text.style;
	String border = s.border.wrap_animated(r.w - 2, r.h - 2, s.border_animation, s, frame_ms());
	edge.render_ansi_string(0, 0, border, xray::default_style(), r.h, r.w);
	for (sz y = 0; y < r.h; y++) {
		for (sz x = 0; x < r.w; x++) {
			if (x == 0 || x == r.w - 1 || y == 0 || y == r.h - 1) {
				body.cells[y * r.w + x].style.fg = edge.cells[y * r.w + x].style.fg;
			}
		}
	}
	return body.render_ansi();
}
fn sz JavaScriptAnimatedText.measure(&self, sz width) @dynamic => self.text.measure(width);
fn sz JavaScriptAnimatedText.measure_width(&self, sz height) @dynamic => self.text.measure_width(height);
fn void js_style_options(Node* n, int border_fg, int corner_fg, int gradient, int border_anim, sz speed,
	sz top, sz right, sz bottom, sz left, int align_h, int align_v) @wasm("mt_js_style_options") {
	StyledText* st = (StyledText*)n.content;
	if (border_fg >= 0) st.style = st.style.border_fg(js_rgb(border_fg));
	if (corner_fg >= 0) st.style = st.style.corner_fg(js_rgb(corner_fg));
	if (gradient >= 0) st.style.bg_gradient = js_rgb(gradient);
	st.style = st.style.padding(top, right, bottom, left)
		.align((glaze::Position)align_h, (glaze::Position)align_v)
		.border_anim((glaze::BorderAnimation)border_anim).border_anim_speed(speed);
	st.plain = false;
	if (border_anim > 0) {
		JavaScriptAnimatedText* content = mem::tnew(JavaScriptAnimatedText);
		content.text = st;
		n.content = content;
		n.animate(30);
	}
}
fn void js_size(Node* n, bool vertical, int kind, sz value) @wasm("mt_js_size") {
	Constraint c;
	switch (kind) {
		case 1: c = fill(value);
		case 2: c = percent(value);
		case 3: c = fit();
		case 4: c = min(value);
		case 5: c = max(value);
		default: c = cells(value);
	}
	if (vertical) { n.height(c); } else { n.width(c); }
}
fn void js_layer(Node* n, bool pinned, sz x, sz y, sz dx, sz dy, int alpha, sz fps, int justify, int align) @wasm("mt_js_layer") {
	if (pinned) n.at(x, y);
	n.offset(dx, dy).alpha((char)alpha);
	if (fps > 0) n.animate(fps);
	if (justify >= 0) n.with_justify((xray::JustifyContent)justify);
	if (align >= 0) n.with_align((xray::AlignItems)align);
}
fn void js_shadow(Node* n, sz x, sz y, int opacity, sz blur, int rgb, bool half_blocks) @wasm("mt_js_shadow") {
	n.shadow(shadow(x, y, (char)opacity, blur, half_blocks).with_color(js_rgb(rgb)));
}
fn Tween* js_tween(double value, sz duration, int easing) @wasm("mt_js_tween") {
	Tween* t = mem::new(Tween);
	*t = tween(value, duration, (Easing)easing);
	return t;
}
fn void js_tween_update(Tween* t, double target) @wasm("mt_js_tween_update") { t.update(target); }
fn void js_tween_set(Tween* t, double value) @wasm("mt_js_tween_set") { t.set(value); }
fn double js_tween_value(Tween* t) @wasm("mt_js_tween_value") => t.value();
fn double js_tween_target(Tween* t) @wasm("mt_js_tween_target") => t.target;
fn bool js_tween_moving(Tween* t) @wasm("mt_js_tween_moving") => t.moving();
fn sz js_tween_lerp(Tween* t, sz from, sz to) @wasm("mt_js_tween_lerp") => t.lerp(from, to);
fn int js_tween_alpha(Tween* t) @wasm("mt_js_tween_alpha") => t.alpha();
fn void js_transition(Node* n, Tween* t, sz dx, sz dy, bool fade) @wasm("mt_js_transition") {
	n.transition({ .from_dx = dx, .from_dy = dy, .fades = fade }, *t);
}
