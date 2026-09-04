module nineslice;

// Nine-slice rounded boxes drawn with kitty graphics, laid out in a 3x3 grid.
//
// The whole box is rasterized once into an RGBA surface, sliced on the cell
// grid, and only the distinct ring tiles are transmitted; the interior is
// ordinary text cells. Because the geometry lives in surface space, the fill
// gradient, the inset border and the drop shadow all ride the same signed
// distance field and stay concentric with the corner arc at any radius.
//
// Layout: xray's flex tree solves the 3x3 grid, but only for its RECTS. The
// boxes are then emitted as absolutely-positioned strings rather than as tree
// content, because the node painter composes through a cell grid that drops
// the U+10EEEE placeholder codepoints (verified: a run painted through the
// tree comes out with zero placeholder cells). So the tree does geometry and
// the placeholders go straight to the terminal.
//
// `t` toggles kitty graphics off, falling back to pure box-drawing output --
// the same layout rendered entirely with text, for comparison on terminals
// with graphics and without.

import milktea;
import glaze;
import tgp;
import xray;
import std::core::dstring;
import std::core::string;
import std::core::mem;

const int COLS = 3;
const int ROWS = 3;
const int BOX_COUNT = COLS * ROWS;
const int BODY_ROWS = 3;
const int GRID_GAP = 1;

// The drop shadow darkens whatever is under it, so it is invisible on a black
// terminal. Paint a lighter backdrop behind everything.
const String SCREEN_BG = "#2a2a33";

struct BoxDef {
	String name;
	String bg;
	String bg2;    // gradient end; same as bg means flat
	String line;
	String fg;
	String sample;
	int stroke;
	float line_w;
	float inset;
	bool shadow;
	// Interior drawn as a scaled placement under the text instead of tiles,
	// so the ramp shows through the glyphs.
	bool grad_fill;
}

// Nine boxes: flat and gradient fills, hairline through heavy borders, and
// one with a drop shadow. Backgrounds are lifted off pure black so the
// shadow has something to darken.
const BoxDef[BOX_COUNT] BOX_DEFS = {
	{ .name = "Indigo", .bg = "#312e81", .bg2 = "#312e81", .line = "#a5b4fc", .fg = "#e0e7ff",
	  .sample = "plain fill", .stroke = STROKE_NONE, .line_w = 0.0f, .inset = 0.0f, .shadow = false },
	{ .name = "Ember", .bg = "#7c2d12", .bg2 = "#7c2d12", .line = "#fdba74", .fg = "#ffedd5",
	  .sample = "2px, inset 6px", .stroke = STROKE_INSET, .line_w = 2.0f, .inset = 6.0f, .shadow = false },
	{ .name = "Moss", .bg = "#14532d", .bg2 = "#14532d", .line = "#86efac", .fg = "#dcfce7",
	  .sample = "1px hairline", .stroke = STROKE_INSET, .line_w = 1.0f, .inset = 0.0f, .shadow = false },

	{ .name = "Plum", .bg = "#4c1d95", .bg2 = "#9d174d", .line = "#f0abfc", .fg = "#fae8ff",
	  .sample = "gradient fill", .stroke = STROKE_NONE, .line_w = 0.0f, .inset = 0.0f, .shadow = false, .grad_fill = true },
	{ .name = "Slate", .bg = "#334155", .bg2 = "#334155", .line = "#e2e8f0", .fg = "#f1f5f9",
	  .sample = "4px heavy", .stroke = STROKE_INSET, .line_w = 4.0f, .inset = 3.0f, .shadow = false },
	{ .name = "Teal", .bg = "#134e4a", .bg2 = "#0e7490", .line = "#5eead4", .fg = "#ccfbf1",
	  .sample = "gradient + 2px", .stroke = STROKE_INSET, .line_w = 2.0f, .inset = 4.0f, .shadow = false, .grad_fill = true },

	{ .name = "Amber", .bg = "#78350f", .bg2 = "#b45309", .line = "#fcd34d", .fg = "#fef3c7",
	  .sample = "gradient + 3px", .stroke = STROKE_INSET, .line_w = 3.0f, .inset = 5.0f, .shadow = false, .grad_fill = true },
	{ .name = "Rose", .bg = "#881337", .bg2 = "#881337", .line = "#fda4af", .fg = "#ffe4e6",
	  .sample = "drop shadow", .stroke = STROKE_INSET, .line_w = 2.0f, .inset = 5.0f, .shadow = true },
	{ .name = "Cyan", .bg = "#164e63", .bg2 = "#1e3a8a", .line = "#67e8f9", .fg = "#cffafe",
	  .sample = "gradient, no border", .stroke = STROKE_NONE, .line_w = 0.0f, .inset = 0.0f, .shadow = false, .grad_fill = true },
};

const int MSG_GFX = 1;

// One glyph per box, not one per (box, radius): a session holds MAX_GLYPHS
// (32) glyphs, and 9 boxes x 10 radii would be 90 registrations, silently
// exhausting the session and leaving later boxes pointing at earlier boxes'
// images. The frame axis carries radius * MAX_TILES + tile, so every radius
// of a box lives in one glyph at a fixed stride.
struct Model {
	tgp::Session gfx;
	tgp::Glyph[BOX_COUNT] rings;
	// Gradient boxes place a stretched interior strip under the text layer,
	// so the ramp shows through between the glyphs. Flat boxes leave these
	// unset and draw their interior as ordinary tiles.
	tgp::Glyph[BOX_COUNT] strips;
	tgp::InstId[BOX_COUNT] strip_ids;
	int[BOX_COUNT] radius;
	int selected;
	bool tgp_ok;   // terminal capability
	bool tgp_on;   // user toggle ('t')
}

fn int hexval(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return 0;
}

fn uint parse_rgb(String hex) {
	uint v = 0;
	sz i = hex.len > 0 && hex[0] == '#' ? 1 : 0;
	for (; i < hex.len && i < 7; i++) v = v * 16 + (uint)hexval(hex[i]);
	return v;
}

fn String repeat_str(String s, int n) {
	DString d = dstring::temp();
	for (int i = 0; i < n; i++) d.append_string(s);
	return d.str_view();
}

fn String center(String s, int w) {
	DString d = dstring::temp();
	int left = (w - (int)s.len) / 2;
	int right = w - (int)s.len - left;
	if (left < 0) left = 0;
	if (right < 0) right = 0;
	for (int i = 0; i < left; i++) d.append_char(' ');
	d.append_string(s);
	for (int i = 0; i < right; i++) d.append_char(' ');
	return d.str_view();
}

fn String clip(String s, int w) {
	if ((int)s.len <= w) return s;
	return w <= 0 ? "" : s[:(sz)w];
}

fn BoxStyle style_of(int b) {
	BoxDef d = BOX_DEFS[b];
	uint bg = parse_rgb(d.bg);
	uint bg2 = parse_rgb(d.bg2);
	return {
		.bg = bg,
		.bg2 = bg2,
		.grad = bg2 != bg,
		.line = parse_rgb(d.line),
		.line_w = d.line_w,
		.inset = d.inset,
		.stroke = d.stroke,
		.backdrop = parse_rgb(SCREEN_BG),
		.shadow_dx = d.shadow ? 3.0f : 0.0f,
		.shadow_dy = d.shadow ? 5.0f : 0.0f,
		.shadow_blur = d.shadow ? 6.0f : 0.0f,
		.shadow_alpha = d.shadow ? (char)170 : (char)0,
	};
}

// Frame index of one tile: radius picks the block, tile_index the slot in it.
// Interior rows left once the corner blocks take 2k of the fixed box height.
fn int body_rows(int k) {
	int n = BODY_ROWS + 2 - 2 * k;
	return n < 1 ? 1 : n;
}

fn int ring_frame(int rad, int k, int slot, int ox, int oy) {
	return rad * FRAMES_PER_RADIUS + tile_index(k, slot, ox, oy);
}

// Frame of one body-row tile (which: 0 left, 1 centre, 2 right).
fn int ring_row_frame(int rad, int k, int row, int which) {
	return rad * FRAMES_PER_RADIUS + row_tile_index(k, row, which);
}

fn bool Model.gfx_active(Model* self) => self.tgp_ok && self.tgp_on;

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.tgp_ok = milktea::kitty_graphics_supported();
	self.tgp_on = true;
	for (int b = 0; b < BOX_COUNT; b++) {
		self.radius[b] = RADII - 1;
		self.strip_ids[b] = tgp::NO_INSTANCE;
	}
	if (self.tgp_ok) {
		self.gfx = tgp::new_session();
		for (int b = 0; b < BOX_COUNT; b++) {
			BoxStyle st = style_of(b);
			// All radii in one buffer, each at a MAX_TILES-frame stride.
			char[] frames = mem::new_array(char, (sz)(RADII * FRAMES_PER_RADIUS) * TILE_BYTES);
			for (int rad = 0; rad < RADII; rad++) {
				int r = radius_px(rad);
				int k = radius_cells(r);
				sz base = (sz)(rad * FRAMES_PER_RADIUS) * TILE_BYTES;
				sz span = (sz)tile_count_rows(k, body_rows(k)) * TILE_BYTES;
				// Full-height slice: the gradient must be continuous down the
				// whole box, so every body row is cut from its own surface row
				// rather than tiling one row's slice.
				slice_box_rows(frames[base:span], k, body_rows(k), r, st);
			}
			// Gradient boxes also get a 1x256 ramp strip, stretched with c/r
			// to the interior at placement time.
			if (BOX_DEFS[b].grad_fill) {
				char[] strip = mem::new_array(char, STRIP_BYTES);
				render_gradient_strip(strip, st);
				self.strips[b] = self.gfx.register({
					.frames = strip,
					.count = 1, .width = STRIP_W, .height = STRIP_H,
					.fps = 0, .fallback = " ",
				})!!;
			}
			// A full session returns SESSION_FULL; registering per (box,
			// radius) used to blow past MAX_GLYPHS here and leave later boxes
			// pointing at earlier boxes' images.
			self.rings[b] = self.gfx.register({
				.frames = frames,
				.count = RADII * FRAMES_PER_RADIUS, .width = GX, .height = GY,
				.fps = 0, .fallback = " ",
			})!!;
		}
	}
	// tgp transmits lazily on the first tick after the alt screen is active;
	// view() alone runs before that flag is set, so prod it once.
	return milktea::tick(16, &on_gfx);
}

fn milktea::Msg on_gfx() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_GFX };
}

fn void Model.adjust_radius(Model* self, int delta) {
	int r = self.radius[self.selected] + delta;
	if (r < 0) r = 0;
	if (r > RADII - 1) r = RADII - 1;
	self.radius[self.selected] = r;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_GFX) {
		if (self.tgp_ok) self.gfx.tick();
		return null;
	}
	// Any state change can move a strip, so reconcile placements after it.
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return self.quit();
		case milktea::KeyCode.ESC:
			return self.quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return self.quit();
			if (k.rune == 't') {
				// Toggling graphics off leaves images on screen until the
				// next full repaint, so clear the placements right away. The
				// strip instances go with them and are re-placed on the way
				// back, since destroy() invalidates what the terminal holds.
				self.tgp_on = !self.tgp_on;
				if (self.tgp_ok) {
					for (int i = 0; i < BOX_COUNT; i++) {
						if (self.strip_ids[i] != tgp::NO_INSTANCE) {
							self.gfx.remove(self.strip_ids[i]);
							self.strip_ids[i] = tgp::NO_INSTANCE;
						}
					}
					self.gfx.sync();
					if (!self.tgp_on) self.gfx.destroy();
				}
				return milktea::tick(1, &on_gfx);
			}
			if (k.rune == '+' || k.rune == '=') { self.adjust_radius(1); return milktea::tick(1, &on_gfx); }
			if (k.rune == '-') { self.adjust_radius(-1); return milktea::tick(1, &on_gfx); }
		case milktea::KeyCode.RIGHT:
			self.selected = (self.selected + 1) % BOX_COUNT;
			return milktea::tick(1, &on_gfx);
		case milktea::KeyCode.LEFT:
			self.selected = (self.selected + BOX_COUNT - 1) % BOX_COUNT;
		case milktea::KeyCode.UP:
			self.selected = (self.selected + BOX_COUNT - COLS) % BOX_COUNT;
		case milktea::KeyCode.DOWN:
			self.selected = (self.selected + COLS) % BOX_COUNT;
		default:
	}
	return null;
}

fn milktea::Cmd Model.quit(Model* self) {
	if (self.tgp_ok) self.gfx.destroy();
	return milktea::quit();
}

fn void Model.on_destroy(Model* self) @dynamic {
	if (self.tgp_ok) self.gfx.destroy();
}

// tile_run emits n consecutive cells of one ring tile. The id-carrying fg
// color is set once for the whole run, and each cell carries an explicit
// (row 0, col 0) diacritic: a placeholder cell with no diacritics inherits
// its row from the left and INCREMENTS the column, so an undecorated run
// would ask for columns that a 1x1 tile does not have and render blank.
fn String tile_run(Model* m, int b, int rad, int k, int slot, int ox, int oy, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(g.base_id + (uint)ring_frame(rad, k, slot, ox, oy), n);
}

fn String tile_cell(Model* m, int b, int rad, int k, int slot, int ox, int oy) {
	return tile_run(m, b, rad, k, slot, ox, oy, 1);
}

// hrun_run emits n cells of the top/bottom run tile for corner row oy.
fn String hrun_run(Model* m, int b, int rad, int k, int oy, bool bottom, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(
		g.base_id + (uint)(rad * FRAMES_PER_RADIUS + hrun_tile_index(k, oy, bottom)), n);
}

// row_run emits n cells of one body-row tile (0 left, 1 centre, 2 right).
fn String row_run(Model* m, int b, int rad, int k, int row, int which, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(g.base_id + (uint)ring_row_frame(rad, k, row, which), n);
}

// ---- Emitting one box at an absolute rect ----

// append_box_at writes a box into out, positioning each row with an absolute
// cursor move. The placeholders bypass the node painter this way (it composes
// through a cell grid that drops them), so the escapes reach the terminal
// exactly as built.
fn void append_box_at(DString* out, Model* m, int b, xray::Rect rect) {
	BoxDef d = BOX_DEFS[b];
	glaze::Color bg = glaze::color_hex(d.bg);
	// A text cell always paints an opaque background -- there is no
	// "transparent" that lets an image show through a glyph cell. So the
	// label's background is the gradient sampled at its own row, which makes
	// it indistinguishable from the tile behind it.
	glaze::Style text_flat = glaze::style().foreground(glaze::color_hex(d.fg)).background(bg);
	glaze::Style title_flat = glaze::style().foreground(glaze::color_hex(d.line)).background(bg).with_bold(true);

	int rad = m.radius[b];
	bool on = m.gfx_active();
	int k = on ? radius_cells(radius_px(rad)) : 1;
	// The grid reserved 2*kmax rows per box; never draw a taller corner.
	int kmax = (rect.h - BODY_ROWS) / 2;
	if (kmax < 1) kmax = 1;
	if (k > kmax) {
		k = kmax;
		// Fall back to the largest radius that fits this corner budget.
		while (rad > 0 && radius_cells(radius_px(rad)) > kmax) rad--;
	}

	int inner = rect.w - 2 * k;
	if (inner < 1) inner = 1;

	bool sel = b == m.selected;
	String marker = sel ? "*" : " ";
	// Labels, centred in whatever body rows the corners leave.
	String[3] labels = {
		string::tformat("%s%s", marker, d.name),
		d.sample,
		string::tformat("r%dpx", radius_px(rad)),
	};

	int row = rect.y;

	if (!on) {
		// Text fallback: the same layout in box-drawing characters.
		glaze::Style line_st = glaze::style().foreground(glaze::color_hex(d.line)).background(bg);
		String rule = repeat_str("─", rect.w - 2);
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		out.append_string(line_st.render(string::tformat("╭%s╮", rule)));
		row++;
		int text_w = rect.w - 2;
		for (int r = 0; r < 3; r++) {
			out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
			out.append_string(line_st.render("│"));
			glaze::Style st = r == 0 ? title_flat : text_flat;
			out.append_string(st.render(center(clip(labels[r], text_w), text_w)));
			out.append_string(line_st.render("│"));
			row++;
		}
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		out.append_string(line_st.render(string::tformat("╰%s╯", rule)));
		return;
	}

	// Top corner-block rows.
	for (int oy = 0; oy < k; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		for (int ox = 0; ox < k; ox++) out.append_string(tile_cell(m, b, rad, k, SLOT_TL, ox, oy));
		out.append_string(hrun_run(m, b, rad, k, oy, false, inner));
		for (int ox = 0; ox < k; ox++) out.append_string(tile_cell(m, b, rad, k, SLOT_TR, ox, oy));
		row++;
	}

	// Body: the whole row is graphics -- left edge, gradient interior, right
	// edge -- so the fill is continuous with the corners. Text is written over
	// the interior afterwards, positioned by a second cursor move, because a
	// placeholder cell cannot carry a glyph of its own.
	int body = body_rows(k);
	for (int r = 0; r < body; r++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		out.append_string(row_run(m, b, rad, k, r, 0, k));
		out.append_string(row_run(m, b, rad, k, r, 1, inner));
		out.append_string(row_run(m, b, rad, k, r, 2, k));

		// Centre the three labels in the available body rows; a tall corner
		// leaves fewer rows, so the outer labels drop first.
		int li = r - (body - 3) / 2;
		String label = li >= 0 && li < 3 ? labels[li] : "";
		if (label.len > 0) {
			String cut = clip(label, inner);
			int pad = (inner - (int)cut.len) / 2;
			out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + k + pad + 1));
			// Sample the ramp at this row's centre, matching the tile under it.
			float t = ((float)(k + r) + 0.5f) / (float)rect.h;
			uint packed = gradient_at(style_of(b), t);
			glaze::Color rowbg = glaze::color_hex(string::tformat("#%06x", packed));
			glaze::Style st = li == 0
				? glaze::style().foreground(glaze::color_hex(d.line)).background(rowbg).with_bold(true)
				: glaze::style().foreground(glaze::color_hex(d.fg)).background(rowbg);
			out.append_string(st.render(cut));
		}
		row++;
	}

	// Bottom corner-block rows.
	for (int oy = 0; oy < k; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		for (int ox = 0; ox < k; ox++) out.append_string(tile_cell(m, b, rad, k, SLOT_BL, ox, oy));
		out.append_string(hrun_run(m, b, rad, k, oy, true, inner));
		for (int ox = 0; ox < k; ox++) out.append_string(tile_cell(m, b, rad, k, SLOT_BR, ox, oy));
		row++;
	}
}

// ---- View ----

// solve_grid lays the 3x3 grid out with the flex tree and fills rects with
// the solved cell geometry. Only the rects are used: see the note at the top
// on why the boxes are not tree content.
fn void solve_grid(xray::Rect area, xray::Rect[] rects) {
	xray::Node* grid = xray::vstack().with_gap(GRID_GAP);
	for (int r = 0; r < ROWS; r++) {
		xray::Node* row = xray::hstack().with_gap(GRID_GAP * 2).fill(1);
		for (int c = 0; c < COLS; c++) row.add(xray::vstack().fill(1));
		grid.add(row);
	}
	grid.solve(area);

	for (int r = 0; r < ROWS; r++) {
		xray::Node* row = grid.children[r];
		for (int c = 0; c < COLS; c++) rects[r * COLS + c] = row.child_rect(c);
	}
}

// place_strip puts (or moves) a gradient box's interior strip under the text
// layer, stretched to the interior rectangle. Because c/r scale the image,
// a size change is a replacement placement -- the ramp itself is never
// retransmitted.
fn void Model.place_strip(Model* self, int b, xray::Rect rect) {
	int rad = self.radius[b];
	int k = radius_cells(radius_px(rad));
	int kmax = (rect.h - BODY_ROWS) / 2;
	if (kmax < 1) kmax = 1;
	if (k > kmax) k = kmax;

	int cols = rect.w - 2 * k;
	int rows = body_rows(k);
	if (cols < 1 || rows < 1) return;

	if (self.strip_ids[b] == tgp::NO_INSTANCE) {
		self.strip_ids[b] = self.strips[b].place(
			rect.x + k, rect.y + k, tgp::Z_UNDER_TEXT, cols, rows);
	} else {
		self.gfx.move(self.strip_ids[b], rect.x + k, rect.y + k);
		self.gfx.resize(self.strip_ids[b], cols, rows);
	}
}

fn milktea::View Model.view(Model* self) @dynamic {
	if (self.gfx_active()) self.gfx.flush();

	int sw = milktea::screen_width();
	int sh = milktea::screen_height();

	DString out = dstring::temp();

	// Fill the screen with the backdrop first: the shadow tiles blend against
	// it, and a black terminal would swallow them.
	glaze::Style screen_st = glaze::style().background(glaze::color_hex(SCREEN_BG));
	for (int y = 0; y < sh; y++) {
		out.append_string(string::tformat("\x1b[%d;1H", y + 1));
		out.append_string(screen_st.render(repeat_str(" ", sw)));
	}

	// Header, then the grid below it.
	out.append_string("\x1b[1;1H");
	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#f0f0f0"))
		.background(glaze::color_hex(SCREEN_BG)).with_bold(true)
		.render("Nine-slice rounded boxes"));
	out.append_string("\x1b[2;1H");
	String sub = !self.tgp_ok
		? "kitty graphics unavailable: text fallback"
		: (self.tgp_on
			? "one surface per box, sliced on the cell grid"
			: "graphics off (t): plain terminal rendering");
	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#aaaaaa"))
		.background(glaze::color_hex(SCREEN_BG))
		.render(sub));

	int top = 4;
	// Every box is sized for the largest corner block in use, so the grid
	// keeps a stable geometry as the radius changes and rows never collide.
	int kmax = 1;
	if (self.gfx_active()) {
		for (int b = 0; b < BOX_COUNT; b++) {
			int k = radius_cells(radius_px(self.radius[b]));
			if (k > kmax) kmax = k;
		}
	}
	// Box height is FIXED: a larger corner radius consumes rows of the box
	// rather than growing it, so changing the radius re-rounds the corners
	// without moving the grid.
	int box_h = BODY_ROWS + 2;
	int grid_h = ROWS * (box_h + GRID_GAP);
	// A corner block cannot be taller than half the box, or the top and
	// bottom blocks would overlap.
	int khi = (box_h - 1) / 2;
	if (kmax > khi) kmax = khi;
	xray::Rect area = xray::new_rect(2, top, sw - 4, grid_h);

	xray::Rect[BOX_COUNT] rects;
	solve_grid(area, rects[..]);

	for (int b = 0; b < BOX_COUNT; b++) {
		xray::Rect rr = rects[b];
		// Each box is a fixed height; the solved rect gives x/width.
		rr.h = box_h;
		append_box_at(&out, self, b, rr);
	}

	int foot = top + grid_h + 1;
	if (foot > sh - 1) foot = sh - 1;
	out.append_string(string::tformat("\x1b[%d;1H", foot + 1));
	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#aaaaaa"))
		.background(glaze::color_hex(SCREEN_BG))
		.render("arrows select   -/+ radius   t graphics on/off   q quit"));

	return milktea::new_alt_screen_view(out.str_view());
}
