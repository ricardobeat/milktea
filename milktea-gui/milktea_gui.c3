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
	bool undecorated;
	float corner_radius; // pixels; 0 = square corners (default). Implies undecorated + a transparent framebuffer.
}

fn GuiOptions default_options() {
	return {
		.title = "milktea",
		.cols = 80, .rows = 24,
		.cell_w = 10, .cell_h = 19,
		.font_size = 17,
	};
}

// ROUND_CORNERS_FS composites a texture onto a transparent-window
// framebuffer, cutting the four corners to a rounded rect by zeroing
// alpha outside the radius (signed-distance test against the nearest
// corner center). `size` is the destination rect in pixels, `radius`
// the corner radius in the same units — both set per-frame since the
// window (and so the texture) can be resized live.
const String ROUND_CORNERS_FS = `
#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec2 size;
uniform float radius;
void main() {
	vec4 c = texture(texture0, fragTexCoord);
	vec2 p = fragTexCoord * size;
	vec2 corner = clamp(p, vec2(radius), size - vec2(radius));
	float d = length(p - corner);
	c.a *= 1.0 - smoothstep(radius - 1.0, radius + 1.0, d);
	finalColor = c;
}
`;

extern fn char* getenv(char* name);

// Monospace fonts to try, in order, when MILKTEA_FONT is unset. A leading
// "~/" expands against $HOME. These are candidates, not requirements —
// every one is allowed to be missing, and load_mono_font() falls back to
// raylib's built-in bitmap font if none resolve.
const String[*] FONT_PATHS = {
	"~/Library/Fonts/JetBrainsMono[wght].ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/Library/Fonts/JetBrainsMono-Regular.ttf",
	// Common Linux locations, so a GUI build is not macOS-only.
	"/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
};

// expand_home rewrites a leading "~/" to $HOME. Returns the path unchanged
// if it has no tilde, and skips it (empty) if $HOME is unset — an
// unexpanded "~" would otherwise be probed as a literal directory name.
fn String expand_home(String path) {
	if (!path.starts_with("~/")) return path;
	char* home = getenv("HOME");
	if (home == null) return "";
	return string::tformat("%s%s", ((ZString)home).str_view(), path[1..]);
}

// font_candidates returns the paths to try in order. MILKTEA_FONT, when
// set, wins outright and is the only candidate: someone who named a font
// explicitly wants to know it failed, not to silently get a different one.
fn String[] font_candidates() {
	char* override = getenv("MILKTEA_FONT");
	if (override != null) {
		String p = ((ZString)override).str_view();
		if (p.len > 0) {
			String[] one = mem::new_array(String, 1);
			one[0] = expand_home(p);
			return one;
		}
	}
	String[] out = mem::new_array(String, FONT_PATHS.len);
	int n = 0;
	foreach (p : FONT_PATHS) {
		String e = expand_home(p);
		if (e.len > 0) out[n++] = e;
	}
	return out[:n];
}

// Contiguous codepoint ranges to rasterize into the font atlas, beyond
// plain ASCII. Chosen by surveying what boba, glaze and examples/ actually
// draw — every range here is in real use:
//
//   Latin-1 punctuation  ° ± · × and accented letters
//   general punctuation  – — • (em-dash alone appears ~380 times)
//   arrows               ← ↑ → ↓ and the diagonals the spinners cycle
//   box-drawing          single and double line borders
//   BLOCK ELEMENTS       █ ░ ▒ ▓ ▀ ▄ ▌ and the eighth-width bars — the
//                        single biggest gap before this: doom-fire, paint,
//                        voxel-renderer, nanobots, progress bars and
//                        cursors are all built out of them
//   geometric shapes     ■ □ ● ◆ ◉ ▸
//   braille              the ⠋⠙⠹ spinner frames
//
// Emoji and CJK are deliberately left out: they need a color/fallback font
// and are wide glyphs this fixed-cell renderer would misalign anyway.
struct CpRange {
	int lo;
	int hi;
}

const CpRange[*] CP_RANGES = {
	{ 0x0020, 0x007e }, // printable ASCII
	{ 0x00a0, 0x00ff }, // Latin-1 supplement: ° ± ² · × and accented letters
	{ 0x2010, 0x203a }, // general punctuation: – — ' ' " " •
	{ 0x2190, 0x21bb }, // arrows, including ↵ and the diagonal spinner frames
	{ 0x2217, 0x2219 }, // ∗ ∘ ∙ — the spinners' dot frames
	{ 0x2248, 0x2248 }, // ≈
	{ 0x2500, 0x257f }, // box-drawing, single and double line
	{ 0x2580, 0x259f }, // block elements
	{ 0x25a0, 0x25ff }, // geometric shapes
	{ 0x2713, 0x2727 }, // check marks and sparkles: ✓ ✛ ✦ ✧
	// Braille, kept to the 2x4-dot subset boba's spinners cycle rather than
	// the whole 256-glyph block: most monospace fonts (JetBrains Mono
	// included) carry no braille at all, and raylib rasterizes nothing for
	// a codepoint the font lacks.
	{ 0x2807, 0x283c },
};

fn int[] build_codepoints() {
	int total = 0;
	foreach (r : CP_RANGES) { total += r.hi - r.lo + 1; }

	int[] cps = mem::new_array(int, total);
	int n = 0;
	foreach (r : CP_RANGES) {
		for (int c = r.lo; c <= r.hi; c++) { cps[n++] = c; }
	}
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

// draw_block_glyph paints U+2580-block-element codepoints as filled rects
// instead of going through font rendering. These glyphs are meant to tile
// pixel-perfectly against their neighbors (doom-fire's ▀ half-blocks rely
// on this), but a font's own bearing/advance metrics rarely put the glyph
// flush with the cell box — leaving visible seams or an offset grid, as
// seen with JetBrains Mono. Drawing the shapes ourselves sidesteps font
// metrics entirely. Returns true if it handled the codepoint (caller
// should skip the text draw), false for anything else (falls through to
// normal glyph rendering).
fn bool draw_block_glyph(uint cp, int px, int py, int cw, int ch, RLColor fg, RLColor bg) {
	switch (cp) {
		case 0x2588: // █ full block
			rl::draw_rectangle(px, py, cw, ch, fg);
			return true;
		case 0x2580: // ▀ upper half
			rl::draw_rectangle(px, py, cw, ch / 2, fg);
			return true;
		case 0x2584: // ▄ lower half
			rl::draw_rectangle(px, py + ch / 2, cw, ch - ch / 2, fg);
			return true;
		case 0x258c: // ▌ left half
			rl::draw_rectangle(px, py, cw / 2, ch, fg);
			return true;
		case 0x2590: // ▐ right half
			rl::draw_rectangle(px + cw / 2, py, cw - cw / 2, ch, fg);
			return true;
		case 0x2591: // ░ light shade (25%)
			rl::draw_rectangle(px, py, cw, ch, shade_blend(fg, bg, 0.25f));
			return true;
		case 0x2592: // ▒ medium shade (50%)
			rl::draw_rectangle(px, py, cw, ch, shade_blend(fg, bg, 0.5f));
			return true;
		case 0x2593: // ▓ dark shade (75%)
			rl::draw_rectangle(px, py, cw, ch, shade_blend(fg, bg, 0.75f));
			return true;
		case 0x2596: // ▖ quadrant lower-left
			rl::draw_rectangle(px, py + ch / 2, cw / 2, ch - ch / 2, fg);
			return true;
		case 0x2597: // ▗ quadrant lower-right
			rl::draw_rectangle(px + cw / 2, py + ch / 2, cw - cw / 2, ch - ch / 2, fg);
			return true;
		case 0x2598: // ▘ quadrant upper-left
			rl::draw_rectangle(px, py, cw / 2, ch / 2, fg);
			return true;
		case 0x259d: // ▝ quadrant upper-right
			rl::draw_rectangle(px + cw / 2, py, cw - cw / 2, ch / 2, fg);
			return true;
		default:
			return false;
	}
}

// shade_blend mixes fg toward bg by `amount` (0 = fg, 1 = bg) — used for
// the ░▒▓ shade glyphs, which are visually a translucency over whatever
// sits behind them rather than a distinct solid color.
fn RLColor shade_blend(RLColor fg, RLColor bg, float amount) @local {
	return {
		(char)((float)fg.r + ((float)bg.r - (float)fg.r) * amount),
		(char)((float)fg.g + ((float)bg.g - (float)fg.g) * amount),
		(char)((float)fg.b + ((float)bg.b - (float)fg.b) * amount),
		255,
	};
}

// load_mono_font rasterizes the atlas at the display's actual pixel density
// (2x on retina) so glyphs stay crisp when raylib's HighDPI backbuffer
// scales drawing coordinates back up — same trick as @2x image assets.
fn rl::RLFont load_mono_font(int font_size) {
	float dpi_scale = rl::get_window_scale_dpi().x;
	if (dpi_scale < 1.0f) dpi_scale = 1.0f;
	int atlas_size = (int)((float)font_size * dpi_scale);

	int[] cps = build_codepoints();
	foreach (path : font_candidates()) {
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
// dispatch_gui sends msg to the model and runs any Cmd chain it returns,
// mirroring milktea::Program's dispatch() — the GUI loop drives update()
// by hand instead of going through Program.run(), so it needs its own
// copy of the same Cmd-chaining and QUIT handling.
// Set by dispatch_gui whenever a msg reaches the model; run()'s loop
// consumes it to decide whether this frame needs a new view() at all.
bool g_dirty = true;

fn bool dispatch_gui(milktea::Model m, milktea::Msg msg) {
	g_dirty = true;
	if (msg.kind == milktea::MsgKind.QUIT) return true;
	milktea::Cmd c = m.update(msg);
	int chain = 0;
	while (c != null && chain < milktea::MAX_BATCH) {
		milktea::Msg next = c();
		if (next.kind == milktea::MsgKind.QUIT) return true;
		if (next.kind == milktea::MsgKind.NONE) break;
		c = m.update(next);
		chain++;
	}
	return false;
}

fn void run(milktea::Model m, GuiOptions opts = default_options()) {
	bool rounded = opts.corner_radius > 0.0f;

	uint config_flags = (uint)rl::RLConfigFlag.WINDOW_HIGHDPI | (uint)rl::RLConfigFlag.WINDOW_RESIZABLE;
	if (opts.undecorated || rounded) config_flags |= (uint)rl::RLConfigFlag.WINDOW_UNDECORATED;
	if (rounded) config_flags |= (uint)rl::RLConfigFlag.WINDOW_TRANSPARENT;
	rl::set_config_flags((rl::RLConfigFlag)config_flags);
	rl::init_window(opts.cols * opts.cell_w, opts.rows * opts.cell_h, (ZString)opts.title.zstr_tcopy());
	rl::set_window_min_size(opts.cell_w * 4, opts.cell_h * 4);
	rl::set_target_fps(60);
	rl::RLFont font = load_mono_font(opts.font_size);

	// Rounded corners need real per-pixel transparency at the window's
	// edges — something no raylib/GLFW window flag provides (undecorated
	// just removes the OS chrome; the framebuffer itself stays a plain
	// rectangle). So the scene is drawn into an offscreen RenderTexture
	// first, then composited onto the (transparent) window through a
	// shader that zeroes alpha outside a rounded-rect SDF — the actual
	// corner cut comes from that alpha, not from any window shape API.
	rl::RLRenderTexture2D target;
	rl::RLShader round_shader;
	int round_radius_loc, round_size_loc;
	if (rounded) {
		target = rl::load_render_texture(opts.cols * opts.cell_w, opts.rows * opts.cell_h);
		round_shader = rl::load_shader_from_memory(null, (ZString)ROUND_CORNERS_FS);
		round_radius_loc = round_shader.get_location("radius");
		round_size_loc = round_shader.get_location("size");
	}

	// draw() needs a live g_program only for its scratch buffers and to
	// answer screen_width()/screen_height(); nothing else about Program is
	// used since the loop below drives init/update/view by hand instead of
	// Program.run() (which assumes a real or test-mode TTY).
	milktea::Program prog;
	prog.cached_ws.ws_col = (ushort)opts.cols;
	prog.cached_ws.ws_row = (ushort)opts.rows;
	milktea::g_program = &prog;

	milktea::Cmd init_cmd = m.init();
	{
		int chain = 0;
		milktea::Cmd c = init_cmd;
		while (c != null && chain < milktea::MAX_BATCH) {
			milktea::Msg next = c();
			if (next.kind == milktea::MsgKind.QUIT) return;
			if (next.kind == milktea::MsgKind.NONE) break;
			c = m.update(next);
			chain++;
		}
	}

	// Nothing about a milktea view changes between frames unless a msg
	// (key, mouse, timer, resize) moved the model, so the drawn grid is
	// compared against the previous frame's copy and an identical one
	// skips the whole GPU path: no cell rects, no swap. The window keeps
	// showing the front buffer that is already correct. Idle apps then
	// cost a poll and a sleep per frame instead of cols*rows draw calls.
	xray::Cell[] prev_cells;
	sz prev_count = 0;
	bool prev_valid = false;
	// A model only ever moves through update(), and every update() on this
	// loop goes through dispatch_gui, so a frame that dispatched nothing
	// cannot have produced a different view — skip view() too, not just
	// the draw. g_dirty starts true so the first frame always renders.
	g_dirty = true;

	bool should_quit = false;
	while (!should_quit && !rl::window_should_close()) {
		// Fire expired timers registered via milktea::tick()/every() —
		// mirrors Program.run()'s timer loop, since this GUI loop bypasses
		// Program.run() entirely and drives update() by hand.
		sz now = milktea::time_ms();
		for (sz i = 0; i < milktea::MAX_TIMERS; i++) {
			if (prog.timers[i].active && now >= prog.timers[i].deadline_ms) {
				milktea::Cmd cb = prog.timers[i].callback;
				void* owner = prog.timers[i].owner;
				prog.timers[i].active = false;
				milktea::Msg tmsg = cb();
				tmsg.owner = owner;
				if (tmsg.kind != milktea::MsgKind.NONE && dispatch_gui(m, tmsg)) {
					should_quit = true;
					break;
				}
				now = milktea::time_ms();
			}
		}
		if (should_quit) break;

		if (rl::is_window_resized()) {
			int new_cols = rl::get_screen_width() / opts.cell_w;
			int new_rows = rl::get_screen_height() / opts.cell_h;
			if (new_cols < 1) new_cols = 1;
			if (new_rows < 1) new_rows = 1;
			if (new_cols != opts.cols || new_rows != opts.rows) {
				opts.cols = new_cols;
				opts.rows = new_rows;
				prog.cached_ws.ws_col = (ushort)new_cols;
				prog.cached_ws.ws_row = (ushort)new_rows;
				milktea::Msg wm = { .kind = milktea::MsgKind.WINDOW_SIZE, .window_size = { new_cols, new_rows } };
				if (rounded) {
					rl::unload_render_texture(target);
					target = rl::load_render_texture(new_cols * opts.cell_w, new_rows * opts.cell_h);
				}
				if (dispatch_gui(m, wm)) { should_quit = true; break; }
			}
		}

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
			if (dispatch_gui(m, { .kind = milktea::MsgKind.KEY, .key = k })) { should_quit = true; }
		}
		rl::RLKeyboardKey key;
		while ((key = rl::get_key_pressed()) != rl::RLKeyboardKey.NONE) {
			if (try k = translate_key(key, mods)) {
				if (dispatch_gui(m, { .kind = milktea::MsgKind.KEY, .key = k })) { should_quit = true; }
			}
		}
		if (should_quit) break;

		int mcol = rl::get_mouse_x() / opts.cell_w;
		int mrow = rl::get_mouse_y() / opts.cell_h;
		if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT)) {
			milktea::MouseMsg mm = { .button = milktea::MouseButton.MOUSE_LEFT, .action = milktea::MouseAction.MOUSE_PRESS, .row = mrow, .col = mcol };
			// Fires on_click/on_click_outside against last frame's layout
			// before the raw MouseMsg reaches update() — same order as the
			// terminal event loop's dispatch().
			milktea::dispatch_click(mcol, mrow);
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = mm })) { should_quit = true; }
		}
		if (rl::is_mouse_button_released(rl::RLMouseButton.LEFT)) {
			milktea::MouseMsg mm = { .button = milktea::MouseButton.MOUSE_LEFT, .action = milktea::MouseAction.MOUSE_RELEASE, .row = mrow, .col = mcol };
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = mm })) { should_quit = true; }
		}
		float wheel = rl::get_mouse_wheel_move();
		if (wheel != 0.0f) {
			milktea::MouseMsg mm = {
				.button = wheel > 0 ? milktea::MouseButton.MOUSE_WHEEL_UP : milktea::MouseButton.MOUSE_WHEEL_DOWN,
				.action = milktea::MouseAction.MOUSE_PRESS, .row = mrow, .col = mcol,
			};
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = mm })) { should_quit = true; }
		}
		if (should_quit) break;

		if (!g_dirty) {
			rl::poll_input_events();
			rl::wait_time(1.0 / 60.0);
			continue;
		}
		g_dirty = false;

		milktea::View v = m.view();

		sz cell_count = v.cells.ptr != null ? v.cells_width * v.cells_height : 0;
		bool unchanged = prev_valid && cell_count == prev_count &&
			(cell_count == 0 || mem::equals(prev_cells, v.cells[:cell_count]));
		if (unchanged) {
			// begin/end_drawing normally does this for us; standing in for
			// it keeps input flowing and the frame rate capped while idle.
			rl::poll_input_events();
			rl::wait_time(1.0 / 60.0);
			continue;
		}
		if (cell_count != prev_count) {
			if (prev_cells.ptr != null) mem::free(prev_cells);
			prev_cells = cell_count > 0 ? mem::new_array(xray::Cell, cell_count) : {};
			prev_count = cell_count;
		}
		if (cell_count > 0) prev_cells[..] = v.cells[:cell_count];
		prev_valid = true;

		rl::begin_drawing();
		if (rounded) rl::begin_texture_mode(target);

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

					RLColor bg = to_rl(cell.style.bg, rl::BLACK);
					rl::draw_rectangle(px, py, opts.cell_w, opts.cell_h, bg);
					if (cell.content_len > 0 && cell.content[0] != ' ') {
						RLColor fg = to_rl(cell.style.fg, rl::WHITE);
						uint cp;
						xray::utf8_decode(cell.content_str(), &cp);
						if (!draw_block_glyph(cp, px, py, opts.cell_w, opts.cell_h, fg, bg)) {
							char[9] buf;
							mem::copy(&buf, &cell.content, cell.content_len);
							buf[cell.content_len] = 0;
							rl::draw_text_ex(font, (ZString)&buf[0], { (float)px, (float)py }, (float)opts.font_size, 0, fg);
						}
					}
				}
			}
		}

		if (rounded) {
			rl::end_texture_mode();
			rl::clear_background(rl::BLANK);
			float[2] tex_size = { (float)target.texture.width, (float)target.texture.height };
			round_shader.set_value(round_size_loc, &tex_size, rl::RLShaderUniformDataType.VEC2);
			round_shader.set_value(round_radius_loc, &opts.corner_radius, rl::RLShaderUniformDataType.FLOAT);
			rl::begin_shader_mode(round_shader);
			// Render textures are stored bottom-up; flip the source rect's
			// height negative to draw them right-side up, same trick raylib's
			// own examples use.
			rl::draw_texture_rec(
				target.texture,
				{ 0, 0, (float)target.texture.width, -(float)target.texture.height },
				{ 0, 0 }, rl::WHITE);
			rl::end_shader_mode();
		}
		rl::end_drawing();
	}

	if (prev_cells.ptr != null) mem::free(prev_cells);
	if (rounded) {
		rl::unload_shader(round_shader);
		rl::unload_render_texture(target);
	}
	rl::close_window();
}
