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
// Total box height in cells, set by layout. Radius and border never change it.
const int BOX_H = BODY_ROWS + 2;
const int GRID_GAP = 1;

// The drop shadow darkens whatever is under it, so it is invisible on a black
// terminal. Paint a lighter backdrop behind everything.
const String SCREEN_BG = "#212136";

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

// One glyph per box, holding only the radius currently on screen.
//
// Radius is just one axis of a box's style -- border width, inset, fill,
// shadow are others -- so pre-building the cross-product does not scale: even
// radius alone was 9 boxes x 8 radii = 4.3MB of RGBA transmitted at startup,
// visible as a staggered fade-in, for eight variants of which one is ever
// shown. Each box now registers its current radius and releases the previous
// one, so the wire cost is what is displayed, not what could be.
struct Model {
	tgp::Session gfx;
	tgp::Glyph[BOX_COUNT] rings;
	// Radius each ring was built for; -1 means nothing registered yet.
	int[BOX_COUNT] ring_radius;
	// Whether that ring was built with the selection border.
	bool[BOX_COUNT] ring_selected;
	// Shadow tiles, a separate pass drawn outside the box. Only shadowed
	// boxes register one.
	tgp::Glyph[BOX_COUNT] shadows;
	// Radius the shadow was built for; -1 means none. The shadow follows the
	// box silhouette, so its corner curve -- and its tile count -- change with
	// the radius, exactly like the ring's.
	int[BOX_COUNT] shadow_radius;
	int[BOX_COUNT] radius;
	// Solved grid rects from the last view(), so a mouse press can be hit
	// tested. view() computes the layout; update() only reads it back.
	xray::Rect[BOX_COUNT] hit;
	bool hit_valid;
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

// Selected boxes get a 2px neon-blue border. Selection is a STYLE, so it goes
// through the same rasterizer as everything else -- the ring is rebuilt with
// the new stroke rather than drawn over the top, which keeps it concentric
// with the corner arc at any radius.
const String SELECT_LINE = "#38bdf3";
const float SELECT_W = 4.0f;
const float SELECT_INSET = 1.0f;

fn BoxStyle style_of(int b, bool selected = false) {
	BoxDef d = BOX_DEFS[b];
	uint bg = parse_rgb(d.bg);
	uint bg2 = parse_rgb(d.bg2);
	if (selected) {
		return {
			.bg = bg,
			.bg2 = bg2,
			.grad = bg2 != bg,
			.line = parse_rgb(SELECT_LINE),
			.line_w = SELECT_W,
			.inset = SELECT_INSET,
			.stroke = STROKE_INSET,
			.backdrop = parse_rgb(SCREEN_BG),
			.shadow_dx = d.shadow ? 3.0f : 0.0f,
			.shadow_dy = d.shadow ? 5.0f : 0.0f,
			.shadow_blur = d.shadow ? 6.0f : 0.0f,
			.shadow_alpha = d.shadow ? (char)170 : (char)0,
		};
	}
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
// Interior rows left once the corner blocks take 2*ky of the box height. The
// box height is fixed by layout; a radius never changes it.
fn int body_rows(int ky) {
	int n = BOX_H - 2 * ky;
	return n < 1 ? 1 : n;
}

fn int ring_frame(int kx, int ky, int slot, int ox, int oy) {
	return tile_index(kx, ky, slot, ox, oy);
}

// Frame of one body-row tile (which: 0 left, 1 centre, 2 right).
fn int ring_row_frame(int kx, int ky, int row, int which) {
	return row_tile_index(kx, ky, row, which);
}

fn bool Model.gfx_active(Model* self) => self.tgp_ok && self.tgp_on;

// sync_ring makes box b's glyph match its current radius, building and
// registering the tiles if it does not already hold them. The previous radius
// is released, which deletes its images from the terminal and frees the
// session slot -- without that, cycling through radii would exhaust
// MAX_GLYPHS.
// effective_radius is the radius a box can actually draw. Box height comes
// from style and layout; the radius does not get to change it. The only real
// constraint is that the top and bottom corner blocks must not overlap, so a
// k-cell corner needs 2k <= box_h, leaving box_h - 2k interior rows (which
// may be as few as one -- a large radius eats into the text area, which is
// what a large radius is supposed to look like).
//
// The builder and the emitter MUST agree on this: they index the same glyph,
// and a k=1 layout and a k=2 layout put different tiles at the same index.
fn int effective_radius(int rad, int box_h) {
	int ky_max = box_h / 2;
	if (ky_max < 1) ky_max = 1;
	while (rad > 0 && radius_cells_y(radius_px(rad)) > ky_max) rad--;
	return rad;
}

fn void Model.sync_ring(Model* self, int b) {
	if (!self.tgp_ok) return;
	int rad = effective_radius(self.radius[b], BOX_H);
	bool sel = b == self.selected;
	if (self.ring_radius[b] == rad && self.ring_selected[b] == sel) return;

	// Keep the old glyph alive until the new one is on the terminal: release
	// deletes images immediately, and view() would then emit placeholders for
	// ids that no longer resolve -- one frame of blank box.
	bool had_old = self.ring_radius[b] >= 0;
	tgp::Glyph old = self.rings[b];

	int r = radius_px(rad);
	int kx = radius_cells_x(r);
	int ky = radius_cells_y(r);
	int body = body_rows(ky);
	int n = tile_count_rows(kx, ky, body);
	char[] frames = mem::new_array(char, (sz)n * TILE_BYTES);
	// Full-height slice: the gradient must be continuous down the whole box,
	// so every body row is cut from its own surface row rather than tiling
	// one row's slice.
	slice_box_rows(frames, kx, ky, body, r, style_of(b, sel));
	self.rings[b] = self.gfx.register({
		.frames = frames,
		.count = n, .width = GX, .height = GY,
		.fps = 0, .fallback = " ",
	})!!;
	// Transmit the replacement, THEN drop the old one.
	self.gfx.flush();
	if (had_old) self.gfx.release(old);

	self.ring_radius[b] = rad;
	self.ring_selected[b] = sel;

	// Shadow is independent of radius/selection styling, so it is built once.
	// The shadow does not depend on selection, only on the radius.
	if (BOX_DEFS[b].shadow && self.shadow_radius[b] != rad) {
		bool had_shadow = self.shadow_radius[b] >= 0;
		tgp::Glyph old_shadow = self.shadows[b];
		char[] sf = mem::new_array(char, (sz)shadow_tile_count(kx, ky) * TILE_BYTES);
		slice_shadow(sf, 2 * kx + 1, BOX_H, kx, ky, r, style_of(b, false));
		self.shadows[b] = self.gfx.register({
			.frames = sf,
			.count = shadow_tile_count(kx, ky), .width = GX, .height = GY,
			.fps = 0, .fallback = " ",
		})!!;
		self.gfx.flush();
		if (had_shadow) self.gfx.release(old_shadow);
		self.shadow_radius[b] = rad;
	}
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.tgp_ok = milktea::kitty_graphics_supported();
	self.tgp_on = true;
	// Radius steps up across the grid, so the whole range is visible at once
	// -- including the radii that need a two-cell-wide corner block -- rather
	// than every box starting the same and needing +/- to tell apart.
	for (int b = 0; b < BOX_COUNT; b++) {
		self.radius[b] = (b * (RADII - 1) + (BOX_COUNT - 1) / 2) / (BOX_COUNT - 1);
		self.ring_radius[b] = -1;
		self.ring_selected[b] = false;
		self.shadow_radius[b] = -1;
	}
	if (self.tgp_ok) {
		self.gfx = tgp::new_session();
		for (int b = 0; b < BOX_COUNT; b++) self.sync_ring(b);
	}
	// tgp transmits lazily on the first tick after the alt screen is active;
	// view() alone runs before that flag is set, so prod it once.
	return milktea::tick(16, &on_gfx);
}

fn milktea::Msg on_gfx() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_GFX };
}

// select rebuilds the two boxes whose border changes: the one gaining the
// selection ring and the one losing it.
fn void Model.select(Model* self, int b) {
	if (b == self.selected || b < 0 || b >= BOX_COUNT) return;
	int prev = self.selected;
	self.selected = b;
	self.sync_ring(prev);
	self.sync_ring(b);
}

fn void Model.adjust_radius(Model* self, int delta) {
	int r = self.radius[self.selected] + delta;
	if (r < 0) r = 0;
	if (r > RADII - 1) r = RADII - 1;
	self.radius[self.selected] = r;
	self.sync_ring(self.selected);
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_GFX) {
		if (self.tgp_ok) self.gfx.tick();
		return null;
	}
	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (msg.mouse.action != milktea::MouseAction.MOUSE_PRESS) return null;
		if (msg.mouse.button != milktea::MouseButton.MOUSE_LEFT) return null;
		int b = self.box_at(msg.mouse.col, msg.mouse.row);
		if (b >= 0) self.select(b);
		return milktea::tick(1, &on_gfx);
	}
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
				// back, since destroy() invalidates what the terminal holds.
				self.tgp_on = !self.tgp_on;
				if (self.tgp_ok) {
					if (!self.tgp_on) self.gfx.destroy();
				}
				return milktea::tick(1, &on_gfx);
			}
			if (k.rune == '+' || k.rune == '=') { self.adjust_radius(1); return milktea::tick(1, &on_gfx); }
			if (k.rune == '-') { self.adjust_radius(-1); return milktea::tick(1, &on_gfx); }
		case milktea::KeyCode.RIGHT:
			self.select((self.selected + 1) % BOX_COUNT);
			return milktea::tick(1, &on_gfx);
		case milktea::KeyCode.LEFT:
			self.select((self.selected + BOX_COUNT - 1) % BOX_COUNT);
			return milktea::tick(1, &on_gfx);
		case milktea::KeyCode.UP:
			self.select((self.selected + BOX_COUNT - COLS) % BOX_COUNT);
			return milktea::tick(1, &on_gfx);
		case milktea::KeyCode.DOWN:
			self.select((self.selected + COLS) % BOX_COUNT);
			return milktea::tick(1, &on_gfx);
		default:
	}
	return null;
}

// box_at returns the box under a cell coordinate, or -1. Uses the rects the
// last view() solved, so it follows the layout automatically.
fn int Model.box_at(Model* self, int col, int row) {
	if (!self.hit_valid) return -1;
	for (int b = 0; b < BOX_COUNT; b++) {
		xray::Rect r = self.hit[b];
		if (col >= r.x && col < r.x + r.w && row >= r.y && row < r.y + r.h) return b;
	}
	return -1;
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
fn String tile_run(Model* m, int b, int kx, int ky, int slot, int ox, int oy, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(g.base_id + (uint)ring_frame(kx, ky, slot, ox, oy), n);
}

fn String tile_cell(Model* m, int b, int kx, int ky, int slot, int ox, int oy) {
	return tile_run(m, b, kx, ky, slot, ox, oy, 1);
}

// hrun_run emits n cells of the top/bottom run tile for corner row oy.
fn String hrun_run(Model* m, int b, int kx, int ky, int oy, bool bottom, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(
		g.base_id + (uint)hrun_tile_index(kx, ky, oy, bottom), n);
}

// row_run emits n cells of one body-row tile (0 left, 1 centre, 2 right).
fn String row_run(Model* m, int b, int kx, int ky, int row, int which, int n) {
	tgp::Glyph g = m.rings[b];
	return tgp::placeholder_run(g.base_id + (uint)ring_row_frame(kx, ky, row, which), n);
}

// ---- Emitting one box at an absolute rect ----

// append_box_at writes a box into out, positioning each row with an absolute
// cursor move. The placeholders bypass the node painter this way (it composes
// through a cell grid that drops them), so the escapes reach the terminal
// exactly as built.
// append_shadow_at draws the drop shadow: one column right of the box, one row
// below, and the corner. A separate pass, before the box, so the shadow is not
// clipped by the box's own tiles -- which is what made it invisible when it
// lived inside them.
fn void append_shadow_at(DString* out, Model* m, int b, xray::Rect rect) {
	if (!m.gfx_active() || m.shadow_radius[b] < 0) return;
	uint base = m.shadows[b].base_id;
	int rad = effective_radius(m.radius[b], BOX_H);
	int kx = radius_cells_x(radius_px(rad));
	int ky = radius_cells_y(radius_px(rad));

	int col = rect.x + rect.w;   // the column right of the box
	int mid_rows = rect.h - 2 * ky;
	if (mid_rows < 0) mid_rows = 0;

	// Right column: the curve at each end, the straight tile repeated between.
	for (int oy = 0; oy < ky; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", rect.y + oy + 1, col + 1));
		out.append_string(tgp::placeholder_string(base + (uint)shadow_right_top(oy)));
	}
	for (int i = 0; i < mid_rows; i++) {
		out.append_string(string::tformat("\x1b[%d;%dH", rect.y + ky + i + 1, col + 1));
		out.append_string(tgp::placeholder_string(base + (uint)shadow_right_mid(ky)));
	}
	for (int oy = 0; oy < ky; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", rect.y + rect.h - ky + oy + 1, col + 1));
		out.append_string(tgp::placeholder_string(base + (uint)shadow_right_bot(ky, oy)));
	}

	// Bottom row: the shadow is offset right, so it starts one cell in.
	int row = rect.y + rect.h;
	int mid_cols = rect.w - 2 * kx;
	if (mid_cols < 0) mid_cols = 0;
	out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
	for (int ox = 0; ox < kx; ox++) {
		out.append_string(tgp::placeholder_string(base + (uint)shadow_bottom_left(kx, ky, ox)));
	}
	if (mid_cols > 0) {
		out.append_string(tgp::placeholder_run(base + (uint)shadow_bottom_mid(kx, ky), mid_cols));
	}
	for (int ox = 0; ox < kx; ox++) {
		out.append_string(tgp::placeholder_string(base + (uint)shadow_bottom_right(kx, ky, ox)));
	}
	// The outer corner where the two runs meet.
	out.append_string(tgp::placeholder_string(base + (uint)shadow_corner(kx, ky)));
}

fn void append_box_at(DString* out, Model* m, int b, xray::Rect rect) {
	BoxDef d = BOX_DEFS[b];
	glaze::Color bg = glaze::color_hex(d.bg);
	// A text cell always paints an opaque background -- there is no
	// "transparent" that lets an image show through a glyph cell. So the
	// label's background is the gradient sampled at its own row, which makes
	// it indistinguishable from the tile behind it.
	glaze::Style text_flat = glaze::style().foreground(glaze::color_hex(d.fg)).background(bg);
	glaze::Style title_flat = glaze::style().foreground(glaze::color_hex(d.line)).background(bg).with_bold(true);

	// Same clamp the glyph was built with: see effective_radius.
	int rad = effective_radius(m.radius[b], rect.h);
	bool on = m.gfx_active();
	int kx = on ? radius_cells_x(radius_px(rad)) : 1;
	int ky = on ? radius_cells_y(radius_px(rad)) : 1;
	int inner = rect.w - 2 * kx;
	if (inner < 1) inner = 1;

	// With graphics the neon border marks the selection, so the title needs
	// no marker. The text fallback has no such border, so it keeps one.
	bool sel = b == m.selected;
	String title = on || !sel ? d.name : string::tformat("* %s", d.name);
	String[3] labels = {
		title,
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

	// Top corner-block rows: kx cells across, ky rows down.
	for (int oy = 0; oy < ky; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		for (int ox = 0; ox < kx; ox++) out.append_string(tile_cell(m, b, kx, ky, SLOT_TL, ox, oy));
		out.append_string(hrun_run(m, b, kx, ky, oy, false, inner));
		for (int ox = 0; ox < kx; ox++) out.append_string(tile_cell(m, b, kx, ky, SLOT_TR, ox, oy));
		row++;
	}

	// Body: the whole row is graphics -- left edge, gradient interior, right
	// edge -- so the fill is continuous with the corners. Text is written over
	// the interior afterwards, positioned by a second cursor move, because a
	// placeholder cell cannot carry a glyph of its own.
	// Body rows use ONE edge cell per side whatever the radius: the vertical
	// border is a straight stroke and does not widen with the corner. Only
	// the corner rows span kx cells; here the extra width is interior, so the
	// centre run absorbs it. Repeating the edge tile kx times would draw the
	// stroke kx times.
	int side_inner = rect.w - 2;
	if (side_inner < 1) side_inner = 1;
	int body = body_rows(ky);
	for (int r = 0; r < body; r++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		out.append_string(row_run(m, b, kx, ky, r, 0, 1));
		out.append_string(row_run(m, b, kx, ky, r, 1, side_inner));
		out.append_string(row_run(m, b, kx, ky, r, 2, 1));

		// Centre the three labels in the available body rows; a tall corner
		// leaves fewer rows, so the outer labels drop first.
		int li = r - (body - 3) / 2;
		String label = li >= 0 && li < 3 ? labels[li] : "";
		if (label.len > 0) {
			String cut = clip(label, side_inner);
			int pad = (side_inner - (int)cut.len) / 2;
			out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1 + pad + 1));
			// Sample the ramp at this row's centre, matching the tile under it.
			float t = ((float)(ky + r) + 0.5f) / (float)rect.h;
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
	for (int oy = 0; oy < ky; oy++) {
		out.append_string(string::tformat("\x1b[%d;%dH", row + 1, rect.x + 1));
		for (int ox = 0; ox < kx; ox++) out.append_string(tile_cell(m, b, kx, ky, SLOT_BL, ox, oy));
		out.append_string(hrun_run(m, b, kx, ky, oy, true, inner));
		for (int ox = 0; ox < kx; ox++) out.append_string(tile_cell(m, b, kx, ky, SLOT_BR, ox, oy));
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
			int k = radius_cells_y(radius_px(self.radius[b]));
			if (k > kmax) kmax = k;
		}
	}
	// Box height is FIXED: a larger corner radius consumes rows of the box
	// rather than growing it, so changing the radius re-rounds the corners
	// without moving the grid.
	int box_h = BOX_H;
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
		self.hit[b] = rr;
		// Shadow first: the box paints over its inner edge.
		append_shadow_at(&out, self, b, rr);
		append_box_at(&out, self, b, rr);
	}
	self.hit_valid = true;

	int foot = top + grid_h + 1;
	if (foot > sh - 1) foot = sh - 1;
	out.append_string(string::tformat("\x1b[%d;1H", foot + 1));
	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#aaaaaa"))
		.background(glaze::color_hex(SCREEN_BG))
		.render("click or arrows select   -/+ radius   t graphics on/off   q quit"));

	return milktea::new_alt_screen_view(out.str_view())
		.set_mouse_mode(milktea::MouseMode.MOUSE_MODE_CELL_MOTION);
}
