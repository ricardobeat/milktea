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

// to_rl resolves a cell color for drawing. `fallback` is what a NONE or
// TRANSPARENT color becomes — the caller supplies it because "terminal
// default" means black for a background but white for a foreground, and
// this function has no way to tell which role it is resolving.
//
// TRANSPARENT reaching here means xray had nothing to composite against,
// so it resolves to the same default as NONE rather than to a real alpha:
// the cell grid is already flattened by the time it arrives.
fn RLColor to_rl(xray::Color c, RLColor fallback) {
	switch (c.kind) {
		case xray::ColorKind.TRUECOLOR:
			// effective_alpha() maps xray's a == 0 ("opaque", for backwards
			// compatibility) onto a real 255 rather than a transparent 0.
			return { c.r, c.g, c.b, c.effective_alpha() };
		case xray::ColorKind.ANSI:
			// ANSI carries a 0-15 index, but clamp rather than trust it:
			// an out-of-range index would read past ANSI16.
			Rgb p = ANSI16[c.index & 0x0f];
			return { p.r, p.g, p.b, 255 };
		case xray::ColorKind.ANSI256:
			Rgb p = ansi256_rgb(c.index);
			return { p.r, p.g, p.b, 255 };
		default:
			return fallback;
	}
}

faultdef NO_KEY;

// Mods carries the modifier state raylib reports as held this frame.
// raylib has no per-event modifier record — get_key_pressed() returns a bare
// keycode — so these are sampled once per frame and applied to every key
// dequeued in it. A modifier pressed or released mid-frame (within ~16ms of
// the keypress) can therefore attach to the wrong event; the terminal path,
// which reads modifiers out of the escape sequence itself, has no such race.
struct Mods {
	bool ctrl;
	bool alt;
	bool shift;
}

fn Mods read_mods() {
	return {
		.ctrl = rl::is_key_down(rl::RLKeyboardKey.LEFT_CONTROL) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_CONTROL),
		.alt = rl::is_key_down(rl::RLKeyboardKey.LEFT_ALT) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_ALT),
		.shift = rl::is_key_down(rl::RLKeyboardKey.LEFT_SHIFT) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_SHIFT),
	};
}

// translate_key maps a raylib keycode to a milktea KeyMsg, or NO_KEY for a
// key milktea has no code for (the modifier keys themselves included —
// they're state, not events).
//
// Letters are the subtle case. Unmodified, they arrive as text through
// get_char_pressed() and are skipped here, so that typing stays
// layout-correct. With ctrl held they produce no text at all, so this
// synthesizes the RUNE milktea's terminal path emits for ctrl+letter:
// lowercase codepoint, ctrl set — with ctrl+c narrowed to KeyCode.CTRL_C,
// matching input.c3's kitty-protocol branch exactly so a model sees the
// same message on both backends.
fn milktea::KeyMsg? translate_key(rl::RLKeyboardKey key, Mods mods) {
	milktea::KeyMsg k;
	k.ctrl = mods.ctrl;
	k.alt = mods.alt;
	k.shift = mods.shift;

	switch (key) {
		case rl::RLKeyboardKey.ENTER:
		case rl::RLKeyboardKey.KP_ENTER:
			k.code = milktea::KeyCode.ENTER;
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
		case rl::RLKeyboardKey.INSERT: k.code = milktea::KeyCode.INSERT;
		case rl::RLKeyboardKey.PAGE_UP: k.code = milktea::KeyCode.PAGE_UP;
		case rl::RLKeyboardKey.PAGE_DOWN: k.code = milktea::KeyCode.PAGE_DOWN;
		case rl::RLKeyboardKey.F1: k.code = milktea::KeyCode.F1;
		case rl::RLKeyboardKey.F2: k.code = milktea::KeyCode.F2;
		case rl::RLKeyboardKey.F3: k.code = milktea::KeyCode.F3;
		case rl::RLKeyboardKey.F4: k.code = milktea::KeyCode.F4;
		case rl::RLKeyboardKey.F5: k.code = milktea::KeyCode.F5;
		case rl::RLKeyboardKey.F6: k.code = milktea::KeyCode.F6;
		case rl::RLKeyboardKey.F7: k.code = milktea::KeyCode.F7;
		case rl::RLKeyboardKey.F8: k.code = milktea::KeyCode.F8;
		case rl::RLKeyboardKey.F9: k.code = milktea::KeyCode.F9;
		case rl::RLKeyboardKey.F10: k.code = milktea::KeyCode.F10;
		case rl::RLKeyboardKey.F11: k.code = milktea::KeyCode.F11;
		case rl::RLKeyboardKey.F12: k.code = milktea::KeyCode.F12;
		default:
			// A-Z are contiguous from 65 in raylib's table.
			if (mods.ctrl && key >= rl::RLKeyboardKey.A && key <= rl::RLKeyboardKey.Z) {
				uint lower = (uint)((int)key - (int)rl::RLKeyboardKey.A) + 'a';
				// Narrow, like input.c3: extra modifiers stay RUNE so
				// ctrl+shift+c remains distinguishable from a quit.
				if (lower == 'c' && !mods.alt && !mods.shift) {
					k.code = milktea::KeyCode.CTRL_C;
					return k;
				}
				k.code = milktea::KeyCode.RUNE;
				k.rune = lower;
				return k;
			}
			return NO_KEY~;
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
		Mods mods = read_mods();

		// Runes first (letters/digits/punctuation), then non-printable keys —
		// raylib queues both independently per frame.
		//
		// ctrl+letter is deliberately skipped here and synthesized in
		// translate_key() instead: platforms disagree on whether it produces
		// text at all, and letting both paths fire would deliver the keypress
		// twice. Shift is left off runes because it is already baked into the
		// character ('A' vs 'a'); reporting it again would make a model
		// testing `shift` see every capital as modified.
		int ch;
		while ((ch = rl::get_char_pressed()) != 0) {
			if (mods.ctrl) continue;
			milktea::KeyMsg k = { .code = milktea::KeyCode.RUNE, .rune = (uint)ch, .alt = mods.alt };
			m.update({ .kind = milktea::MsgKind.KEY, .key = k });
		}
		rl::RLKeyboardKey key;
		while ((key = rl::get_key_pressed()) != rl::RLKeyboardKey.NONE) {
			if (try k = translate_key(key, mods)) {
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

					rl::draw_rectangle(px, py, opts.cell_w, opts.cell_h, to_rl(cell.style.bg, rl::BLACK));
					if (cell.content_len > 0 && cell.content[0] != ' ') {
						char[9] buf;
						mem::copy(&buf, &cell.content, cell.content_len);
						buf[cell.content_len] = 0;
						RLColor fg = to_rl(cell.style.fg, rl::WHITE);
						rl::draw_text_ex(font, (ZString)&buf[0], { (float)px, (float)py }, (float)opts.font_size, 0, fg);
					}
				}
			}
		}

		rl::end_drawing();
	}

	rl::close_window();
}
