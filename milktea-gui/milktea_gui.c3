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
import std::io;
import std::os::env;
import std::thread;

struct GuiOptions {
	String title;
	int cols;
	int rows;
	int cell_w;
	int cell_h;
	int font_size;
	bool undecorated;
	float corner_radius; // pixels; 0 = square corners (default). Implies undecorated + a transparent framebuffer.
	// When set, the first painted frame is written to this path as a PNG and
	// the loop exits. It renders the same cells the terminal would receive,
	// through the same font, so a view can be inspected as an image with
	// nobody at the keyboard.
	String screenshot_path;
	// chrome_rows puts the top N cell rows in place of the platform title
	// bar: where the platform allows it the window keeps its buttons but
	// loses the title bar text, and a drag starting in those rows moves the
	// window. Zero keeps the ordinary window chrome.
	int chrome_rows;
	// Takes the close/minimise/zoom buttons away along with the title bar,
	// for a window whose own top row already offers whatever it wants to
	// offer. Only meaningful with chrome_rows set, since the buttons are the
	// platform's to draw until the title bar goes. The window can still be
	// closed from the menu bar and its keyboard equivalents.
	bool hide_window_buttons;
}

// Window chrome, implemented in macos_window.c. See that file for what it
// does and why it is not done here.
extern fn int milktea_macos_inline_titlebar(int row_height, int hide_buttons)
	@cname("milktea_macos_inline_titlebar") @feat(DARWIN);
extern fn double milktea_macos_content_height()
	@cname("milktea_macos_content_height") @feat(DARWIN);
extern fn int milktea_macos_cursor_window(double* x, double* y)
	@cname("milktea_macos_cursor_window") @feat(DARWIN);
extern fn int milktea_macos_cursor_screen(double* x, double* y)
	@cname("milktea_macos_cursor_screen") @feat(DARWIN);

// cursor_screen_pos reports the pointer in screen space, which is the only
// frame of reference a window drag can use: a window-relative position moves
// as much when the window moves as when the pointer does, so feeding it back
// into the window's position makes the window chase itself.
//
// The value is an offset, not a coordinate — AppKit measures y upward from
// the bottom of the primary screen, and the sign flip here only lines its
// axis up with the window's. Both are constant, so a difference between two
// readings is exact; a single reading means nothing on its own.
//
// Returns false where there is no way to ask, and the drag falls back to
// window-relative tracking.
fn bool cursor_screen_pos(int* x, int* y) @local {
	$if env::DARWIN:
		double cx;
		double cy;
		if (milktea_macos_cursor_screen(&cx, &cy) != 0) {
			*x = (int)cx;
			*y = (int)-cy;
			return true;
		}
	$endif
	return false;
}

// CHROME_BUTTONS_RIGHT is how far the window buttons reach from the window's
// left edge, in points: the sum of the layout constants in macos_window.c.
// It is only an estimate, for an app that has to lay out before there is a
// window to measure; g_chrome_buttons_right replaces it with the real edge as
// soon as run() has one.
const int CHROME_BUTTONS_RIGHT = 66;
int g_chrome_buttons_right @local = CHROME_BUTTONS_RIGHT;

// chrome_inset_cells reports how many cells of the first row the window
// buttons occupy, so an app can start its own top bar after them instead of
// under them. Zero when the platform keeps its own title bar.
fn int chrome_inset_cells(int cell_w) {
	$if env::DARWIN:
		if (cell_w > 0) return (g_chrome_buttons_right + cell_w - 1) / cell_w;
	$endif
	return 0;
}

// A model cannot reach run()'s options once the loop has them, so a request
// to re-size the grid is left here and picked up at the top of the next
// frame. The cell size is the app's to decide — it is the one that knows its
// font's advance and line box — so this takes the answer rather than a point
// size to derive it from.
int g_req_cell_w @local;
int g_req_cell_h @local;
int g_req_font_size @local;
bool g_size_request @local;
// Last pointer position seen at the GUI loop, in cell coordinates. The
// hover-dispatch path only fires when it actually moves, so this doubles as
// the "did the pointer change" bit — the alternative is reading the global
// mouse position twice per frame and diffing.
int g_prev_mcol @local = -1;
int g_prev_mrow @local = -1;
// Last pointer position reported by the debug trace below, in window pixels,
// so a disagreement between the live reading and raylib's is logged once per
// movement rather than once per frame.
int g_trace_x @local = -1;
int g_trace_y @local = -1;
// The one key MILKTEA_DEBUG_KEY_AT asks the loop to send, and the frame to
// send it on (see the parsing in run()).
milktea::KeyMsg g_key_msg @local;
long g_key_frame @local;
bool g_key_armed @local;

// set_cell_size asks the loop to redraw at a new cell size and point size,
// taking effect on the next frame. The window keeps the pixels it has; what
// changes is how many cells fit in them, so the model is told its new size
// through an ordinary WINDOW_SIZE message and lays out as it would for any
// other resize. Values below 1 are ignored.
fn void set_cell_size(int cell_w, int cell_h, int font_size) {
	if (cell_w < 1 || cell_h < 1 || font_size < 1) return;
	g_req_cell_w = cell_w;
	g_req_cell_h = cell_h;
	g_req_font_size = font_size;
	g_size_request = true;
}

// How far the pointer has to travel in the title strip before a press turns
// into a window drag, in screen pixels. Enough to swallow the wobble of a
// click, small enough that a deliberate drag starts at once.
const int DRAG_SLOP = 3;

// pointer_cell reports the pointer's cell in the grid, preferring a live
// reading of the pointer over raylib's cached one.
//
// raylib only learns where the pointer is from motion events: GLFW's mouse
// button handlers carry a button, not a location, so a press is reported at
// wherever the pointer was on its last move over the window. That is usually
// where it still is — but not when no such move has happened since the window
// opened, and not while the window is not key, because AppKit delivers
// mouse-moved events to the key window only. A press in either case is
// hit-tested against a cell the pointer left long ago, so it opens the wrong
// thing or, more often, nothing: the click that only works after the pointer
// has been wobbled. Asking the window directly answers with where the pointer
// is now, whatever the event queue did or did not deliver.
//
// A pointer outside the window answers (-1, -1), which no layout rect
// contains, so hover clears and a press finds no target instead of being
// rounded into the first row or column. Only the live reading can report
// that: raylib's cached position cannot leave the window it was last seen in.
fn void pointer_cell(GuiOptions opts, int* col, int* row) @local {
	int x = rl::get_mouse_x();
	int y = rl::get_mouse_y();
	$if env::DARWIN:
		double live_x;
		double live_y;
		// A miniaturised window has no place on screen to be measured
		// against, so the reading would be an offset from a window in the
		// Dock and could land inside the grid by accident. raylib's cached
		// position is stale but harmless, and nothing can be pressed there
		// anyway.
		if (!rl::is_window_minimized() && milktea_macos_cursor_window(&live_x, &live_y) != 0) {
			x = (int)live_x;
			y = (int)live_y;
			// The two disagreeing is exactly what a press that lands in the
			// wrong place looks like from inside, so the trace says so when
			// it happens — once per pointer movement, not once per frame.
			if (milktea::debug_mouse()
				&& (x != rl::get_mouse_x() || y != rl::get_mouse_y())
				&& (x != g_trace_x || y != g_trace_y)) {
				g_trace_x = x;
				g_trace_y = y;
				io::eprintfn("[mouse] pointer at %d,%d; raylib last moved at %d,%d",
					x, y, rl::get_mouse_x(), rl::get_mouse_y());
			}
		}
	$endif
	int w = rl::get_screen_width();
	int h = rl::get_screen_height();
	if (w < 1 || h < 1 || x < 0 || y < 0 || x >= w || y >= h) {
		*col = -1;
		*row = -1;
		return;
	}
	*col = x / opts.cell_w;
	*row = y / opts.cell_h;
}

// is_drag_point answers whether a press at this cell should be able to drag
// the window. A view that marked nodes with xray::Node.window_drag decides
// it entirely — those rects move with the layout, so a title bar that is
// indented, split around the window buttons, or absent on some screens
// behaves correctly without the app restating its geometry here. chrome_rows
// is the fallback for a view that marked nothing: the top N rows, all of
// them, which is what a window with no title bar needs to stay movable.
fn bool is_drag_point(GuiOptions opts, int col, int row) @local {
	xray::Rect[] regions = milktea::drag_regions();
	if (regions.len > 0) {
		foreach (r : regions) {
			if (r.contains(col, row)) return true;
		}
		return false;
	}
	return opts.chrome_rows > 0 && row < opts.chrome_rows;
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
			// With ctrl held the char queue is skipped (see the caller), so
			// the punctuation an app is likeliest to want a ctrl chord on
			// has to be named here or it never arrives. Keypad and main row
			// report the same rune, the way a terminal does.
			if (mods.ctrl) {
				uint punct = 0;
				switch (key) {
					case rl::RLKeyboardKey.MINUS:
					case rl::RLKeyboardKey.KP_SUBTRACT: punct = '-';
					case rl::RLKeyboardKey.EQUAL:
					case rl::RLKeyboardKey.KP_ADD: punct = '=';
					case rl::RLKeyboardKey.ZERO:
					case rl::RLKeyboardKey.KP_0: punct = '0';
					default:
				}
				if (punct != 0) {
					k.code = milktea::KeyCode.RUNE;
					k.rune = punct;
					return k;
				}
			}
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
// Box drawing. These glyphs are meant to meet across cells, so they are the
// ones that have to be drawn at the cell's own size rather than the text's:
// a rule scaled to a 16 pt line box inside a 20 pt row stops an ascender
// short of the row below and the border comes out dashed. Block elements are
// not listed because draw_block_glyph paints them as rects already, which is
// exact at any size.
fn bool is_rule_glyph(uint cp) @local => cp >= 0x2500 && cp <= 0x257F;

// CellFit is where inside its cell a glyph from a given font is drawn. The
// advance is measured rather than assumed: milktea does not know the font it
// ended up with, and the app's cell is only ever as close to it as whole
// points allow. Splitting the slack puts the text in the middle of the cell
// instead of hard against its top-left corner, which is what a terminal does
// and what makes an off-ladder point size look deliberate rather than loose.
struct CellFit {
	int dx;
	int dy;
}

fn CellFit cell_fit(rl::RLFont f, int font_size, int cell_w, int cell_h) @local {
	rl::RLVector2 m = rl::measure_text_ex(f, (ZString)"M", (float)font_size, 0);
	CellFit fit;
	fit.dx = (int)(((float)cell_w - m.x) * 0.5f + 0.5f);
	fit.dy = (cell_h - font_size) / 2;
	if (fit.dx < 0) fit.dx = 0;
	if (fit.dy < 0) fit.dy = 0;
	return fit;
}

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

// write_screenshot captures the frame that was just drawn and writes it to
// opts.screenshot_path as a PNG. On a HiDPI display the readback covers more
// than the window's render area, with the frame in a corner of it, so the
// image is cropped to that area first. Without the crop most of the file is
// empty and the UI sits in a quarter of it.
// A screenshot is read back from the texture the frame was drawn into, not
// from the window. The window is hidden on a screenshot run, and what a
// hidden window hands back is the platform's business rather than raylib's —
// on macOS it comes back the wrong size. The texture is the app's own
// framebuffer, exactly the grid and nothing else, whoever is or is not
// looking at the window.
fn void write_screenshot(GuiOptions opts, rl::RLRenderTexture2D from) @local {
	rl::RLImage img = rl::load_image_from_texture(from.texture);
	// Render textures are stored bottom-up.
	rl::image_flip_vertical(&img);
	rl::export_image(img, (ZString)opts.screenshot_path.zstr_tcopy());
	rl::unload_image(img);
}

fn void run(milktea::Model m, GuiOptions opts = default_options()) {
	bool rounded = opts.corner_radius > 0.0f;

	uint config_flags = (uint)rl::RLConfigFlag.WINDOW_HIGHDPI | (uint)rl::RLConfigFlag.WINDOW_RESIZABLE;
	// A screenshot run still needs a window — that is where the GL context
	// and the framebuffer it renders into come from — but nobody has to see
	// it. Hidden, it renders its one frame, is read back and closed, so a
	// shot taken from a script does not steal focus or flash on screen.
	if (opts.screenshot_path.len > 0) config_flags |= (uint)rl::RLConfigFlag.WINDOW_HIDDEN;
	if (opts.undecorated || rounded) config_flags |= (uint)rl::RLConfigFlag.WINDOW_UNDECORATED;
	if (rounded) config_flags |= (uint)rl::RLConfigFlag.WINDOW_TRANSPARENT;
	rl::set_config_flags((rl::RLConfigFlag)config_flags);
	rl::init_window(opts.cols * opts.cell_w, opts.rows * opts.cell_h, (ZString)opts.title.zstr_tcopy());
	// A window that could not be created leaves raylib half-initialised, and
	// every call after it — font loading, the first draw — walks into that:
	// the no-monitor case (all displays asleep, a display-less session) ends
	// in a segfault rather than a message. Stopping here turns it into one
	// line on stderr and an ordinary exit, which is what a caller can act on.
	if (!rl::is_window_ready()) {
		io::eprintfn("milktea-gui: could not create a window (no display?) — nothing to run on");
		return;
	}
	rl::set_window_min_size(opts.cell_w * 4, opts.cell_h * 4);
	rl::set_target_fps(60);
	// raylib closes the window on ESC unless told otherwise, which is wrong
	// for anything built on this loop: ESC is a key the model gets to read
	// like any other, and a view that uses it to leave a menu or a dialog
	// would instead quit the app. Nothing here ever decides on its own that
	// the program should end — a quit comes from the model, through Cmd.
	rl::set_exit_key(rl::RLKeyboardKey.NONE);
	rl::RLFont font = load_mono_font(opts.font_size);
	// A point size the app could not fit to its cell exactly leaves the rules
	// to a second atlas at the cell's height. When the two agree — the usual
	// case — there is nothing to load and both names point at one font.
	bool split_atlas = opts.font_size != opts.cell_h;
	rl::RLFont rule_font = split_atlas ? load_mono_font(opts.cell_h) : font;
	CellFit text_fit = cell_fit(font, opts.font_size, opts.cell_w, opts.cell_h);
	CellFit rule_fit = split_atlas
		? cell_fit(rule_font, opts.cell_h, opts.cell_w, opts.cell_h)
		: text_fit;

	$if env::DARWIN:
		if (opts.chrome_rows > 0) {
			int buttons_right = milktea_macos_inline_titlebar(
				opts.cell_h, opts.hide_window_buttons ? 1 : 0);
			// Zero is a real answer (the buttons are hidden and cover no part
			// of the first row); only -1 means nothing happened.
			if (buttons_right >= 0) {
				g_chrome_buttons_right = buttons_right;
				// Giving the content view the title bar's height changed the
				// window's size behind GLFW's back. Asking for the original
				// size again puts GLFW and the framebuffer raylib draws into
				// back in agreement.
				rl::set_window_size(opts.cols * opts.cell_w, opts.rows * opts.cell_h);
			}
		}
	$endif

	// Rounded corners need real per-pixel transparency at the window's
	// edges — something no raylib/GLFW window flag provides (undecorated
	// just removes the OS chrome; the framebuffer itself stays a plain
	// rectangle). So the scene is drawn into an offscreen RenderTexture
	// first, then composited onto the (transparent) window through a
	// shader that zeroes alpha outside a rounded-rect SDF — the actual
	// corner cut comes from that alpha, not from any window shape API.
	// The shot target is sized in pixels, not points, so a screenshot keeps
	// the resolution the display would have given it; the scene is drawn into
	// it through a camera at the same zoom, leaving every drawing coordinate
	// below in points as usual.
	bool shot = opts.screenshot_path.len > 0;
	rl::RLRenderTexture2D shot_target;
	rl::RLCamera2D shot_cam;
	if (shot) {
		float s = rl::get_window_scale_dpi().x;
		if (s < 1.0f) s = 1.0f;
		shot_target = rl::load_render_texture(
			(int)((float)(opts.cols * opts.cell_w) * s),
			(int)((float)(opts.rows * opts.cell_h) * s));
		shot_cam.zoom = s;
	}

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

	// Arm the send queue the way Program.run() does, so milktea::send and
	// milktea::request_quit work in a GUI app too: a click handler is a void
	// function with no Cmd to return, and asking the loop to stop (or to hand
	// the model any other message) has to go somewhere. Initialising the
	// mutex before marking the program as accepting is the same ordering
	// run() uses, so a sender that sees the flag sees a valid mutex.
	prog.send_head = 0;
	prog.send_tail = 0;
	prog.send_mu.init()!!;
	prog.send_accepting.store(true);

	// Honour the MILKTEA_DEBUG_MOUSE / MILKTEA_DEBUG_CLICK_AT /
	// MILKTEA_DEBUG_POINTER_AT env vars at startup for convenience — tests
	// prefer the programmatic API (milktea::set_debug_mouse /
	// milktea::test_click / milktea::test_pointer) but a one-liner from the
	// shell is still the shortest way to ask the running app "what did that
	// click hit?" or "what does that row look like hovered?".
	if (try dbg = env::tget_var("MILKTEA_DEBUG_MOUSE")) milktea::set_debug_mouse(dbg.len > 0);
	if (try at = env::tget_var("MILKTEA_DEBUG_CLICK_AT")) {
		sz c1 = 0; sz c2 = 0;
		foreach (i, ch : at) { if (ch == ',') { if (c1 == 0) { c1 = i; } else { c2 = i; } } }
		if (c1 > 0) {
			// c3 string slices are length-based in the [a:b] form: at[c1+1:c2-c1-1]
			// takes (c2-c1-1) characters starting at index c1+1. That covers
			// exactly the substring between the two commas, with neither one
			// included.
			int col = at[:c1].to_int() ?? 0;
			int row = (c2 > 0 ? at[c1+1:c2-c1-1] : at[c1+1..]).to_int() ?? 0;
			long delay = c2 > 0 ? (at[c2+1..].to_int() ?? 2) : 2;
			milktea::test_click(col, row, delay);
		}
	}
	if (try at = env::tget_var("MILKTEA_DEBUG_POINTER_AT")) {
		sz c1 = 0; sz c2 = 0;
		foreach (i, ch : at) { if (ch == ',') { if (c1 == 0) { c1 = i; } else { c2 = i; } } }
		if (c1 > 0) {
			int col = at[:c1].to_int() ?? 0;
			int row = (c2 > 0 ? at[c1+1:c2-c1-1] : at[c1+1..]).to_int() ?? 0;
			long delay = c2 > 0 ? (at[c2+1..].to_int() ?? 2) : 2;
			milktea::test_pointer(col, row, delay);
		}
	}
	$if env::DARWIN:
		if (milktea::debug_mouse()) {
			io::eprintfn("[mouse] raylib screen h=%d, real content h=%.1f",
				rl::get_screen_height(), milktea_macos_content_height());
		}
	$endif
	// MILKTEA_DEBUG_KEY_AT="<key>,<frame>" sends one key through the same
	// dispatch a real keypress takes, the way _CLICK_AT does for the mouse:
	// the shortest way to ask the running app what a keystroke does to its
	// view, and the only one that works without a hand on the keyboard. The
	// key is a name (up/down/left/right/enter/esc/tab/backspace/space) or a
	// single character, which arrives as a rune.
	if (try at = env::tget_var("MILKTEA_DEBUG_KEY_AT")) {
		sz comma = 0;
		foreach (i, ch : at) { if (ch == ',') { comma = i; break; } }
		String name = comma > 0 ? at[:comma] : at;
		long frame = comma > 0 ? (at[comma+1..].to_int() ?? 2) : 2;
		milktea::KeyMsg k = { };
		if (name == "up") { k.code = milktea::KeyCode.UP; }
		else if (name == "down") { k.code = milktea::KeyCode.DOWN; }
		else if (name == "left") { k.code = milktea::KeyCode.LEFT; }
		else if (name == "right") { k.code = milktea::KeyCode.RIGHT; }
		else if (name == "enter") { k.code = milktea::KeyCode.ENTER; }
		else if (name == "esc") { k.code = milktea::KeyCode.ESC; }
		else if (name == "tab") { k.code = milktea::KeyCode.TAB; }
		else if (name == "backspace") { k.code = milktea::KeyCode.BACKSPACE; }
		else if (name == "space") {
			k.code = milktea::KeyCode.RUNE;
			k.rune = ' ';
		} else if (name.len == 1) {
			k.code = milktea::KeyCode.RUNE;
			k.rune = (uint)name[0];
		} else {
			io::eprintfn("[test] MILKTEA_DEBUG_KEY_AT: unknown key \"%s\"", name);
		}
		if (k.code != milktea::KeyCode.NONE) {
			g_key_msg = k;
			g_key_frame = frame;
			g_key_armed = true;
		}
	}

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

	// Program.run() tells the model its initial size through a WINDOW_SIZE
	// message; this loop stands in for it, so it has to do the same. Without
	// it a model that caches the size in init() keeps that default for every
	// later frame and lays out anything derived from it (a text field's width,
	// the rows a list shows) for the wrong window.
	milktea::Msg init_size = {
		.kind = milktea::MsgKind.WINDOW_SIZE,
		.window_size = { opts.cols, opts.rows },
	};
	if (dispatch_gui(m, init_size)) return;

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

	// Dragging: a press in the title strip only becomes a drag once the
	// pointer has moved, so a click there still reaches the app and opens a
	// menu. Pointer and window positions are kept in screen coordinates,
	// because window-relative ones stop changing as soon as the window
	// starts following the pointer.
	bool drag_pending = false;
	bool drag_active = false;
	bool drag_abs = false;
	int drag_win_x = 0;
	int drag_win_y = 0;
	int drag_ptr_x = 0;
	int drag_ptr_y = 0;

	while (!should_quit && !rl::window_should_close()) {
		// Messages handed to the program from outside the loop — milktea::send
		// from another thread, or request_quit() from a callback that had no
		// Cmd to return. Same drain Program.run() does, and it runs before
		// everything else so a request made during the previous turn (a click
		// handler asking to close the window, say) takes effect at once.
		milktea::Msg sent;
		while (prog.send_recv(&sent)) {
			if (sent.kind != milktea::MsgKind.NONE && dispatch_gui(m, sent)) {
				should_quit = true;
				break;
			}
		}
		if (should_quit) break;

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

		// A size request and a window resize answer the same question — how
		// many cells fit — so the request only swaps the font and the cell
		// size, and lets the resize path below work out the rest. Forcing
		// that path to run is what makes the new grid reach the model: the
		// window itself did not change, so is_window_resized() is false.
		bool size_changed = false;
		if (g_size_request) {
			g_size_request = false;
			if (split_atlas) rl::unload_font(rule_font);
			rl::unload_font(font);
			opts.cell_w = g_req_cell_w;
			opts.cell_h = g_req_cell_h;
			opts.font_size = g_req_font_size;
			font = load_mono_font(opts.font_size);
			split_atlas = opts.font_size != opts.cell_h;
			rule_font = split_atlas ? load_mono_font(opts.cell_h) : font;
			text_fit = cell_fit(font, opts.font_size, opts.cell_w, opts.cell_h);
			rule_fit = split_atlas
				? cell_fit(rule_font, opts.cell_h, opts.cell_w, opts.cell_h)
				: text_fit;
			rl::set_window_min_size(opts.cell_w * 4, opts.cell_h * 4);
			$if env::DARWIN:
				// The inline title bar is cell_h tall, so it has to be told
				// too or the app's top row and the strip stop agreeing.
				if (opts.chrome_rows > 0) {
					int br = milktea_macos_inline_titlebar(
						opts.cell_h, opts.hide_window_buttons ? 1 : 0);
					if (br >= 0) g_chrome_buttons_right = br;
				}
			$endif
			size_changed = true;
			g_dirty = true;
		}

		if (rl::is_window_resized() || size_changed) {
			int new_cols = rl::get_screen_width() / opts.cell_w;
			int new_rows = rl::get_screen_height() / opts.cell_h;
			if (new_cols < 1) new_cols = 1;
			if (new_rows < 1) new_rows = 1;
			if (new_cols != opts.cols || new_rows != opts.rows || size_changed) {
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

		if (drag_pending) {
			if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT)) {
				drag_pending = false;
				drag_active = false;
			} else {
				// Both branches answer the same question — how far has the
				// pointer travelled since the press — and the window is then
				// placed at its press position plus that, so each frame is
				// computed from the press rather than from the frame before
				// it and nothing accumulates.
				int px;
				int py;
				int dx;
				int dy;
				if (drag_abs && cursor_screen_pos(&px, &py)) {
					dx = px - drag_ptr_x;
					dy = py - drag_ptr_y;
				} else {
					// Window-relative fallback. It reads the pointer through
					// the window that is being moved, so it is a frame behind
					// whenever the window moved last frame.
					rl::RLVector2 wp = rl::get_window_position();
					dx = (int)wp.x + rl::get_mouse_x() - drag_ptr_x;
					dy = (int)wp.y + rl::get_mouse_y() - drag_ptr_y;
				}
				if (!drag_active && (dx > DRAG_SLOP || dx < -DRAG_SLOP
					|| dy > DRAG_SLOP || dy < -DRAG_SLOP)) {
					drag_active = true;
				}
				if (drag_active) {
					rl::set_window_position(drag_win_x + dx, drag_win_y + dy);
				}
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

		// frame_no counts every iteration of the GUI loop, not just the ones
		// that actually rendered: test scripts schedule events at "frame
		// N" and want that to mean "after N ticks of the input pump", not
		// "after N renders" (which would be indeterminate during idle).
		milktea::g_program.frame_no++;

		// Pending synthetic click / pointer: the test API parks them here and
		// the GUI backend fires them through the same dispatch path a real
		// mouse uses, so target lookup, id forwarding, hover bookkeeping and
		// the resulting on_click / on_hover_in chains behave exactly as in
		// a live session — only the raylib input poll is skipped.
		if (milktea::g_program.test_click_armed
				&& milktea::g_program.frame_no >= milktea::g_program.test_pending_click_frame) {
			int tc = milktea::g_program.test_pending_click_col;
			int tr = milktea::g_program.test_pending_click_row;
			milktea::g_program.test_click_armed = false;
			io::eprintfn("[test] frame %d: click col=%d row=%d, %d targets",
				milktea::g_program.frame_no, tc, tr,
				milktea::g_program.click_target_count);
			milktea::dispatch_click(tc, tr);
			milktea::MouseMsg fm = { .button = milktea::MouseButton.MOUSE_LEFT,
				.action = milktea::MouseAction.MOUSE_PRESS, .row = tr, .col = tc };
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = fm })) { should_quit = true; break; }
		}
		if (milktea::g_program.test_pointer_armed
				&& milktea::g_program.frame_no >= milktea::g_program.test_pending_pointer_frame) {
			int pc = milktea::g_program.test_pending_pointer_col;
			int pr = milktea::g_program.test_pending_pointer_row;
			milktea::g_program.test_pointer_armed = false;
			io::eprintfn("[test] frame %d: pointer col=%d row=%d",
				milktea::g_program.frame_no, pc, pr);
			milktea::dispatch_hover(pc, pr);
			milktea::MouseMsg hm = { .button = milktea::MouseButton.MOUSE_NONE,
				.action = milktea::MouseAction.MOUSE_MOTION, .row = pr, .col = pc };
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = hm })) { should_quit = true; }
		}
		// The MILKTEA_DEBUG_KEY_AT key, if one was armed and its frame has
		// arrived. It goes through dispatch_gui exactly as a keystroke read
		// from the keyboard does, so a shell run sees the same result.
		if (g_key_armed && milktea::g_program.frame_no >= g_key_frame) {
			g_key_armed = false;
			io::eprintfn("[test] frame %d: key code=%d rune=%d",
				milktea::g_program.frame_no, (int)g_key_msg.code, (int)g_key_msg.rune);
			if (dispatch_gui(m, { .kind = milktea::MsgKind.KEY, .key = g_key_msg })) { should_quit = true; break; }
		}
		int mcol;
		int mrow;
		pointer_cell(opts, &mcol, &mrow);
		if (mcol != g_prev_mcol || mrow != g_prev_mrow) {
			// Hover is an edge event: walking every target each frame would
			// be a no-op while the pointer stays put, but the edge crossing
			// is what tells a node "you are now hovered" / "you are no
			// longer". Same dispatch path the terminal loop uses on a real
			// MOUSE_MOTION, kept in sync so a model written against either
			// backend sees identical behaviour.
			milktea::dispatch_hover(mcol, mrow);
			milktea::MouseMsg hm = { .button = milktea::MouseButton.MOUSE_NONE,
				.action = milktea::MouseAction.MOUSE_MOTION, .row = mrow, .col = mcol };
			if (dispatch_gui(m, { .kind = milktea::MsgKind.MOUSE, .mouse = hm })) { should_quit = true; }
			g_prev_mcol = mcol;
			g_prev_mrow = mrow;
		}
		if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT)) {
			if (milktea::debug_mouse()) {
				io::eprintfn("[mouse] press at px=%d,%d -> col=%d row=%d (cell %dx%d) drag=%s",
					rl::get_mouse_x(), rl::get_mouse_y(), mcol, mrow,
					opts.cell_w, opts.cell_h, is_drag_point(opts, mcol, mrow));
			}
			if (is_drag_point(opts, mcol, mrow)) {
				rl::RLVector2 wp = rl::get_window_position();
				drag_pending = true;
				drag_active = false;
				drag_win_x = (int)wp.x;
				drag_win_y = (int)wp.y;
				drag_abs = cursor_screen_pos(&drag_ptr_x, &drag_ptr_y);
				if (!drag_abs) {
					drag_ptr_x = drag_win_x + rl::get_mouse_x();
					drag_ptr_y = drag_win_y + rl::get_mouse_y();
				}
			}
			milktea::MouseMsg mm = { .button = milktea::MouseButton.MOUSE_LEFT, .action = milktea::MouseAction.MOUSE_PRESS, .row = mrow, .col = mcol };
			// Fires on_click/on_click_outside against last frame's layout
			// before the raw MouseMsg reaches update() — same order as the
			// terminal event loop's dispatch(): a press counts as a pointer
			// move, so it settles hover first and then delivers the press.
			milktea::dispatch_click(mcol, mrow);
			milktea::dispatch_hover(mcol, mrow);
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
		if (shot) {
			rl::begin_texture_mode(shot_target);
			rl::begin_mode2d(shot_cam);
		} else if (rounded) {
			rl::begin_texture_mode(target);
		}

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
							bool rule = split_atlas && is_rule_glyph(cp);
							rl::RLFont gf = rule ? rule_font : font;
							CellFit fit = rule ? rule_fit : text_fit;
							int gsize = rule ? opts.cell_h : opts.font_size;
							rl::draw_text_ex(gf, (ZString)&buf[0],
								{ (float)(px + fit.dx), (float)(py + fit.dy) },
								(float)gsize, 0, fg);
						}
					}
				}
			}
		}

		if (shot) {
			rl::end_mode2d();
			rl::end_texture_mode();
		} else if (rounded) {
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
		// A screenshot has to run before the swap below (after it, the back
		// buffer holds an older frame) and it has to flush raylib's pending
		// draw batch first, or the readback misses whatever was drawn last and
		// those cells come out empty.
		//
		// A scheduled test event holds the shot back: MILKTEA_DEBUG_CLICK_AT,
		// _POINTER_AT and _KEY_AT all fire some frames in, and a shot taken
		// before them would be a picture of the state they were meant to
		// change.
		if (shot && !milktea::g_program.test_click_armed
			&& !milktea::g_program.test_pointer_armed && !g_key_armed) {
			rl::gl_draw_render_batch_active();
			write_screenshot(opts, shot_target);
			rl::unload_render_texture(shot_target);
			rl::end_drawing();
			break;
		}

		rl::end_drawing();
	}

	if (prev_cells.ptr != null) mem::free(prev_cells);
	if (rounded) {
		rl::unload_shader(round_shader);
		rl::unload_render_texture(target);
	}
	rl::close_window();

	// Mirror image of Program.run()'s teardown of the send queue: stop
	// accepting, wait for senders already past their check, then destroy the
	// mutex they would have locked. Without this a sender from another thread
	// could push into a queue whose mutex is gone.
	prog.send_accepting.store(false);
	while (prog.send_inflight.load() > 0) {
		thread::yield();
	}
	prog.send_mu.destroy();
	milktea::g_program = null;
}
