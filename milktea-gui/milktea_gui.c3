// milktea_gui runs any milktea Model in a raylib window instead of a
// terminal: same Model, same view() tree, same Cell[] grid xray::draw()
// produces — only the "terminal" changes. Opt in per build with:
//
//   c3c build examples/myapp -D MILKTEA_GUI --lib raylib6
//
// so a normal terminal build never links raylib. Apps call gui::run()
// from main() only inside a $if $feat(MILKTEA_GUI): branch — see
// examples/dos-app/dos.c3 for the pattern.
module milktea_gui;

import milktea;
import xray;
import raylib6::rl;
import std::io::file;

struct GuiOptions {
	String title;
	int cols;
	int rows;
	int cell_w;
	int cell_h;
	int font_size;
}

fn GuiOptions default_options() {
	return {
		.title = "milktea",
		.cols = 80, .rows = 24,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
	};
}

const String[*] FONT_PATHS = {
	"/Users/rtomasi/Library/Fonts/JetBrainsMono[wght].ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
};

// Glyphs a milktea app is likely to draw beyond plain ASCII: box-drawing
// (single and double line — U+2500-U+257F covers both), arrows, the
// "enter" glyph and a common bullet triangle. Apps drawing other Unicode
// (e.g. block-shading gradients, emoji) will need a wider set — this
// covers the widgets in boba/glaze out of the box.
fn int[] build_codepoints() {
	int[] cps = mem::new_array(int, (95) + (0x257f - 0x2500 + 1) + 6);
	int n = 0;
	for (int c = 32; c <= 126; c++) { cps[n++] = c; }
	for (int c = 0x2500; c <= 0x257f; c++) { cps[n++] = c; }
	int[6] extra = { 0x2190, 0x2191, 0x2192, 0x2193, 0x21b5, 0x25b8 }; // ← ↑ → ↓ ↵ ▸
	foreach (e : extra) { cps[n++] = e; }
	return cps[:n];
}

// to_rl resolves a cell's background/foreground color for drawing. NONE
// (the terminal-default color) renders as black — a real terminal would
// leave its own background showing, and black is the closest a GUI window
// has to that without tracking a separate "terminal background" concept.
fn RLColor to_rl(xray::Color c) {
	if (c.kind == xray::ColorKind.TRUECOLOR) {
		return { c.r, c.g, c.b, 255 };
	}
	if (c.kind == xray::ColorKind.NONE) return rl::BLACK;
	// ANSI/256 fallback: apps that rely on the 16/256-color palette instead
	// of truecolor will look flat here — this backend only really resolves
	// truecolor styles.
	return rl::WHITE;
}

faultdef NO_KEY;

fn milktea::KeyMsg? translate_key(rl::RLKeyboardKey key, bool ctrl) {
	milktea::KeyMsg k;
	k.ctrl = ctrl;
	switch (key) {
		case rl::RLKeyboardKey.ENTER: k.code = milktea::KeyCode.ENTER;
		case rl::RLKeyboardKey.BACKSPACE: k.code = milktea::KeyCode.BACKSPACE;
		case rl::RLKeyboardKey.ESCAPE: k.code = milktea::KeyCode.ESC;
		case rl::RLKeyboardKey.TAB: k.code = milktea::KeyCode.TAB;
		case rl::RLKeyboardKey.UP: k.code = milktea::KeyCode.UP;
		case rl::RLKeyboardKey.DOWN: k.code = milktea::KeyCode.DOWN;
		case rl::RLKeyboardKey.LEFT: k.code = milktea::KeyCode.LEFT;
		case rl::RLKeyboardKey.RIGHT: k.code = milktea::KeyCode.RIGHT;
		case rl::RLKeyboardKey.HOME: k.code = milktea::KeyCode.HOME;
		case rl::RLKeyboardKey.END: k.code = milktea::KeyCode.END;
		case rl::RLKeyboardKey.DELETE: k.code = milktea::KeyCode.DELETE;
		case rl::RLKeyboardKey.PAGE_UP: k.code = milktea::KeyCode.PAGE_UP;
		case rl::RLKeyboardKey.PAGE_DOWN: k.code = milktea::KeyCode.PAGE_DOWN;
		case rl::RLKeyboardKey.C:
			if (ctrl) { k.code = milktea::KeyCode.CTRL_C; }
			else { return NO_KEY~; }
		default: return NO_KEY~;
	}
	return k;
}

// load_mono_font rasterizes the atlas at the display's actual pixel density
// (2x on retina) so glyphs stay crisp when raylib's HighDPI backbuffer
// scales drawing coordinates back up — same trick as @2x image assets.
fn rl::RLFont load_mono_font(int font_size) {
	float dpi_scale = rl::get_window_scale_dpi().x;
	if (dpi_scale < 1.0f) dpi_scale = 1.0f;
	int atlas_size = (int)((float)font_size * dpi_scale);

	int[] cps = build_codepoints();
	foreach (path : FONT_PATHS) {
		if (file::exists(path)) {
			rl::RLFont f = rl::load_font_ex((ZString)path.zstr_tcopy(), atlas_size, cps.ptr, (int)cps.len);
			if (f.glyph_count > 0) {
				f.texture.set_filter(rl::RLTextureFilter.BILINEAR);
				return f;
			}
		}
	}
	// GetFontDefault() is bitmap-only and ASCII-only, but it always exists.
	return rl::get_font_default();
}

// run drives `m` through a raylib window until it's closed or the model
// quits. `m` must already be initialized (init() called) by the caller,
// mirroring milktea::Program.run()'s contract for consistency — actually,
// for simplicity this calls init() itself, same as milktea::@run does.
fn void run(milktea::Model m, GuiOptions opts = default_options()) {
	rl::set_config_flags(rl::RLConfigFlag.WINDOW_HIGHDPI);
	rl::init_window(opts.cols * opts.cell_w, opts.rows * opts.cell_h, (ZString)opts.title.zstr_tcopy());
	rl::set_target_fps(60);
	rl::RLFont font = load_mono_font(opts.font_size);

	// draw() needs a live g_program only for its scratch buffers and to
	// answer screen_width()/screen_height(); nothing else about Program is
	// used since the loop below drives init/update/view by hand instead of
	// Program.run() (which assumes a real or test-mode TTY).
	milktea::Program prog;
	prog.cached_ws.ws_col = (ushort)opts.cols;
	prog.cached_ws.ws_row = (ushort)opts.rows;
	milktea::g_program = &prog;

	m.init();

	while (!rl::window_should_close()) {
		bool ctrl = rl::is_key_down(rl::RLKeyboardKey.LEFT_CONTROL) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_CONTROL);

		// Runes first (letters/digits/punctuation), then non-printable keys —
		// raylib queues both independently per frame.
		int ch;
		while ((ch = rl::get_char_pressed()) != 0) {
			milktea::KeyMsg k = { .code = milktea::KeyCode.RUNE, .rune = (uint)ch };
			m.update({ .kind = milktea::MsgKind.KEY, .key = k });
		}
		rl::RLKeyboardKey key;
		while ((key = rl::get_key_pressed()) != rl::RLKeyboardKey.NONE) {
			if (try k = translate_key(key, ctrl)) {
				m.update({ .kind = milktea::MsgKind.KEY, .key = k });
			}
		}

		int mcol = rl::get_mouse_x() / opts.cell_w;
		int mrow = rl::get_mouse_y() / opts.cell_h;
		if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT)) {
			milktea::MouseMsg mm = { .button = milktea::MouseButton.MOUSE_LEFT, .action = milktea::MouseAction.MOUSE_PRESS, .row = mrow, .col = mcol };
			// Fires on_click/on_click_outside against last frame's layout
			// before the raw MouseMsg reaches update() — same order as the
			// terminal event loop's dispatch().
			milktea::dispatch_click(mcol, mrow);
			m.update({ .kind = milktea::MsgKind.MOUSE, .mouse = mm });
		}
		if (rl::is_mouse_button_released(rl::RLMouseButton.LEFT)) {
			milktea::MouseMsg mm = { .button = milktea::MouseButton.MOUSE_LEFT, .action = milktea::MouseAction.MOUSE_RELEASE, .row = mrow, .col = mcol };
			m.update({ .kind = milktea::MsgKind.MOUSE, .mouse = mm });
		}
		float wheel = rl::get_mouse_wheel_move();
		if (wheel != 0.0f) {
			milktea::MouseMsg mm = {
				.button = wheel > 0 ? milktea::MouseButton.MOUSE_WHEEL_UP : milktea::MouseButton.MOUSE_WHEEL_DOWN,
				.action = milktea::MouseAction.MOUSE_PRESS, .row = mrow, .col = mcol,
			};
			m.update({ .kind = milktea::MsgKind.MOUSE, .mouse = mm });
		}

		milktea::View v = m.view();

		rl::begin_drawing();

		if (v.cells.ptr != null) {
			// Every cell paints its own background — including an unset one,
			// which renders as plain black — rather than clearing the whole
			// window first. xray's cell grid already covers every cell each
			// frame (ScreenBuffer.clear() fills it before painting), so a
			// window-wide clear here would only be masking a cell this loop
			// failed to draw, not providing real transparency: a NONE bg
			// means "terminal default", not "see through to whatever's
			// behind" — that's what ColorKind.TRANSPARENT is for, and xray's
			// own compositing (set_cell) already resolves it before the
			// grid ever reaches here.
			for (sz row = 0; row < v.cells_height; row++) {
				for (sz col = 0; col < v.cells_width; col++) {
					xray::Cell cell = v.cells[row * v.cells_width + col];
					int px = (int)col * opts.cell_w;
					int py = (int)row * opts.cell_h;

					rl::draw_rectangle(px, py, opts.cell_w, opts.cell_h, to_rl(cell.style.bg));
					if (cell.content_len > 0 && cell.content[0] != ' ') {
						char[9] buf;
						mem::copy(&buf, &cell.content, cell.content_len);
						buf[cell.content_len] = 0;
						RLColor fg = cell.style.fg.is_none() ? rl::WHITE : to_rl(cell.style.fg);
						rl::draw_text_ex(font, (ZString)&buf[0], { (float)px, (float)py }, (float)opts.font_size, 0, fg);
					}
				}
			}
		}

		rl::end_drawing();
	}

	rl::close_window();
}
