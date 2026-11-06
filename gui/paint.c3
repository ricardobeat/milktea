// The painter turns a drawn View into what the GPU draws: one stream of
// quads (cell backgrounds, block elements, glyphs) and a decoration draw
// wherever the paint stream puts one, all in device pixels.
module milktea_gui;

import milktea;
import xray;
import std::collections::list;
import std::math;

struct Rgba {
	char r;
	char g;
	char b;
	char a;
}

const Rgba BLACK = { 0, 0, 0, 255 };
const Rgba WHITE = { 255, 255, 255, 255 };
const Rgba CLEAR = { 0, 0, 0, 0 };

fn uint Rgba.pack(self) @inline => (uint)self.r | (uint)self.g << 8 | (uint)self.b << 16 | (uint)self.a << 24;

// to_rgba resolves a cell colour. `fallback` is what a NONE or TRANSPARENT
// colour becomes: "terminal default" is black for a background but white
// for a foreground, and only the caller knows which it is resolving.
fn Rgba to_rgba(xray::Color c, Rgba fallback) {
	switch (c.kind) {
		case xray::ColorKind.TRUECOLOR:
			// effective_alpha() maps xray's a == 0 ("opaque", for backwards
			// compatibility) onto a real 255.
			return { c.r, c.g, c.b, c.effective_alpha() };
		case xray::ColorKind.ANSI:
			Rgb p = ANSI16[c.index & 0x0f];
			return { p.r, p.g, p.b, 255 };
		case xray::ColorKind.ANSI256:
			Rgb p = ansi256_rgb(c.index);
			return { p.r, p.g, p.b, 255 };
		default:
			return fallback;
	}
}

// decor_color is a decoration colour as the shader takes it: straight RGBA,
// 0..1. NONE and TRANSPARENT draw nothing; palette colours have no alpha of
// their own and take `fallback_a`.
fn float[4] decor_color(xray::Color c, float fallback_a = 1.0f) @private {
	switch (c.kind) {
		case xray::ColorKind.TRUECOLOR:
			return { c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.effective_alpha() / 255.0f };
		case xray::ColorKind.ANSI:
			Rgb p = ANSI16[c.index & 0x0f];
			return { p.r / 255.0f, p.g / 255.0f, p.b / 255.0f, fallback_a };
		case xray::ColorKind.ANSI256:
			Rgb p = ansi256_rgb(c.index);
			return { p.r / 255.0f, p.g / 255.0f, p.b / 255.0f, fallback_a };
		default:
			return { 0, 0, 0, 0 };
	}
}

// CellFit is where inside its cell a glyph from a given face is drawn, in
// points. Splitting the slack between the font's advance and the cell puts
// text in the middle of the cell, the way a terminal does.
struct CellFit {
	int dx;
	int dy;
}

struct Painter {
	List{MtVertex} verts;
	List{MtCmd} cmds;
	List{MtDecor} decors;
	float scale;
	int cell_w;
	int cell_h;
	CellFit text_fit;
	CellFit rule_fit;
	// The cell is taller than the text, so box-drawing rules come from a
	// face sized to the cell and still meet the rows above and below.
	bool rule_split;
	// Where the trailing half of the last wide cell sits, in points. xray
	// writes a blank placeholder there, which the terminal never shows and
	// which would otherwise paint a default background over the glyph.
	int wide_x;
	int wide_y;
	bool wide_pending;
}

Painter g_paint @private;

fn void Painter.begin(&self) {
	if (!self.verts.is_initialized()) {
		self.verts.init(mem, 1 << 14);
		self.cmds.init(mem, 64);
		self.decors.init(mem, 16);
	}
	self.verts.clear();
	self.cmds.clear();
	self.decors.clear();
	self.wide_pending = false;
}

fn void Painter.free(&self) {
	if (!self.verts.is_initialized()) return;
	self.verts.free();
	self.cmds.free();
	self.decors.free();
}

fn int Painter.quads(&self) @inline => (int)(self.verts.len() / 4);

fn void Painter.push_quad(&self, float x0, float y0, float x1, float y1,
		float u0, float v0, float u1, float v1, uint color, int kind = CMD_QUADS, int decor = 0) {
	int q = self.quads();
	self.verts.push({ x0, y0, u0, v0, color });
	self.verts.push({ x1, y0, u1, v0, color });
	self.verts.push({ x0, y1, u0, v1, color });
	self.verts.push({ x1, y1, u1, v1, color });
	sz n = self.cmds.len();
	if (kind == CMD_QUADS && n > 0 && self.cmds[n - 1].kind == CMD_QUADS) {
		self.cmds.get_ref(n - 1).quad_count++;
		return;
	}
	self.cmds.push({ .kind = kind, .first_quad = q, .quad_count = 1, .decor = decor });
}

// clip limits what follows to a rect given in layout units (points), or
// with w <= 0 lifts the limit.
fn void Painter.clip(&self, sz x, sz y, sz w, sz h) {
	float s = self.scale;
	MtCmd c = { .kind = CMD_CLIP, .first_quad = self.quads() };
	if (w > 0 && h > 0) {
		c.clip = { (int)((float)x * s), (int)((float)y * s), (int)math::ceil((float)w * s), (int)math::ceil((float)h * s) };
	}
	self.cmds.push(c);
}

// rect fills a rect given in points.
fn void Painter.rect(&self, int x, int y, int w, int h, Rgba c) {
	if (c.a == 0 || w <= 0 || h <= 0) return;
	float s = self.scale;
	float u = WHITE_SIZE / 2;
	self.push_quad((float)x * s, (float)y * s, (float)(x + w) * s, (float)(y + h) * s, u, u, u, u, c.pack());
}

// glyph draws cp with its line top-left at (x, y) in device pixels, and
// returns how far the pen moves.
fn float Painter.glyph(&self, Face face, uint cp, float x, float y, Rgba c) {
	Glyph g = atlas_glyph(face, cp);
	if (g.missing) return 0;
	if (g.w > 0 && g.h > 0) {
		float gx = x + g.off_x;
		float gy = y + g.off_y;
		self.push_quad(gx, gy, gx + g.w, gy + g.h, (float)g.x, (float)g.y, (float)(g.x + g.w), (float)(g.y + g.h), c.pack());
	}
	return g.advance;
}

// Box drawing. These are meant to meet across cells, so they are the ones
// drawn at the cell's height rather than the text's (see rule_split). Block
// elements are not listed: block_glyph paints them as rects, exact at any
// size.
fn bool is_rule_glyph(uint cp) @private => cp >= 0x2500 && cp <= 0x257F;

// block_glyph paints U+2580 block elements as rects instead of glyphs. They
// are meant to tile against their neighbours, and a font's bearings rarely
// put the glyph flush with the cell, which leaves seams. Returns false for
// anything it does not draw.
fn bool Painter.block_glyph(&self, uint cp, int px, int py, Rgba fg) {
	int cw = self.cell_w;
	int ch = self.cell_h;
	switch (cp) {
		case 0x2588: self.rect(px, py, cw, ch, fg);
		case 0x2580: self.rect(px, py, cw, ch / 2, fg);
		case 0x2584: self.rect(px, py + ch / 2, cw, ch - ch / 2, fg);
		case 0x258c: self.rect(px, py, cw / 2, ch, fg);
		case 0x2590: self.rect(px + cw / 2, py, cw - cw / 2, ch, fg);
		case 0x2591: self.rect(px, py, cw, ch, shade(fg, 0.25f));
		case 0x2592: self.rect(px, py, cw, ch, shade(fg, 0.5f));
		case 0x2593: self.rect(px, py, cw, ch, shade(fg, 0.75f));
		case 0x2596: self.rect(px, py + ch / 2, cw / 2, ch - ch / 2, fg);
		case 0x2597: self.rect(px + cw / 2, py + ch / 2, cw - cw / 2, ch - ch / 2, fg);
		case 0x2598: self.rect(px, py, cw / 2, ch / 2, fg);
		case 0x259d: self.rect(px + cw / 2, py, cw - cw / 2, ch / 2, fg);
		default: return false;
	}
	return true;
}

// shade is fg at `amount` of its opacity, for the ░▒▓ shades: ░ a quarter,
// ▓ three quarters. They read as a translucency over what is behind them,
// and drawn that way they also work over a transparent background, which
// has no colour of its own to mix toward.
fn Rgba shade(Rgba fg, float amount) @private {
	return { fg.r, fg.g, fg.b, (char)((float)fg.a * amount) };
}

// cell paints one cell: its background, then its text. `ordered` is a cell
// from the paint stream, where a transparent background keeps whatever was
// painted beneath it instead of turning black.
fn void Painter.cell(&self, xray::Cell cell, sz col, sz row, bool ordered,
		bool pixels = false, sz bg_w = 0, sz bg_h = 0) {
	int px = (int)(pixels ? col : col * self.cell_w);
	int py = (int)(pixels ? row : row * self.cell_h);
	bool placeholder = self.wide_pending && px == self.wide_x && py == self.wide_y;
	self.wide_pending = false;
	if (placeholder && cell.content_len == 1 && cell.content[0] == ' '
		&& cell.style.bg.kind == xray::ColorKind.NONE) return;
	Rgba bg = ordered && cell.style.bg.kind == xray::ColorKind.TRANSPARENT
		? CLEAR : to_rgba(cell.style.bg, BLACK);
	int bw = (int)(pixels && bg_w > 0 ? bg_w : self.cell_w);
	if (cell.width == 2) {
		// A wide cell covers its own column and the next one.
		bw += self.cell_w;
		self.wide_x = px + self.cell_w;
		self.wide_y = py;
		self.wide_pending = true;
	}
	self.rect(px, py, bw, (int)(pixels && bg_h > 0 ? bg_h : self.cell_h), bg);
	if (cell.content_len == 0 || cell.content[0] == ' ') return;
	Rgba fg = to_rgba(cell.style.fg, WHITE);
	String text = cell.content_str();
	uint cp;
	sz n = xray::utf8_decode(text, &cp);
	if (self.block_glyph(cp, px, py, fg)) return;
	bool rule = self.rule_split && is_rule_glyph(cp);
	CellFit fit = rule ? self.rule_fit : self.text_fit;
	Face face = rule ? Face.RULE : Face.TEXT;
	float s = self.scale;
	float x = math::round((float)(px + fit.dx) * s);
	float y = math::round((float)(py + fit.dy) * s);
	// A cell can hold a base character and the marks that combine with it.
	sz i = 0;
	while (i < text.len) {
		n = xray::utf8_decode(text[i..], &cp);
		if (n < 1) break;
		x += self.glyph(face, cp, x, y, fg);
		i += n;
	}
}

// tint washes one cell with a colour over whatever is painted there.
fn void Painter.tint(&self, sz col, sz row, bool pixels, xray::Color c) {
	int x = (int)(pixels ? col : col * self.cell_w);
	int y = (int)(pixels ? row : row * self.cell_h);
	self.rect(x, y, self.cell_w, self.cell_h, to_rgba(c, CLEAR));
}

// invisible reports a decoration that draws nothing: a clear solid fill
// with no border or shadow. Apps use one to have a node's text painted with
// a clear background (see xray's decorated content).
fn bool invisible(xray::Decoration d) @private {
	if (d.kind != xray::DecorationKind.SOLID || d.shadow || d.inner_shadow) return false;
	if (d.border > 0.0f && decor_color(d.border_color)[3] > 0.0f) return false;
	return decor_color(d.color)[3] <= 0.0f;
}

// decoration adds one decoration: a quad over everything it can touch, and
// the parameters the shader works its fill, border and shadows out from.
fn void Painter.decoration(&self, xray::Decoration d) {
	if (d.kind == xray::DecorationKind.NONE || invisible(d)) return;
	float s = self.scale;
	float x = d.rect.x * s;
	float y = d.rect.y * s;
	float w = d.rect.w * s;
	float h = d.rect.h * s;
	if (!d.pixel_rect) {
		x *= self.cell_w;
		y *= self.cell_h;
		w *= self.cell_w;
		h *= self.cell_h;
	}
	if (w <= 0 || h <= 0) return;
	float short_side = w < h ? w : h;
	float r = d.radius * s;
	if (r > short_side / 2) r = short_side / 2;
	if (r < 0) r = 0;

	MtDecor m;
	m.rect = { x, y, w, h };
	float bw = d.border > 0 ? d.border * s : 0;
	if (bw >= w || bw >= h) bw = 0;
	int flags = (d.shadow ? 1 : 0) | (d.inner_shadow ? 2 : 0);
	m.misc = { r, (float)d.kind.ordinal, bw, (float)flags };
	m.c1 = decor_color(d.color);
	m.c2 = decor_color(d.color2);
	m.bc = decor_color(d.border_color);
	switch (d.kind) {
		case xray::DecorationKind.LINEAR:
			m.grad = { x + d.x1 * w, y + d.y1 * h, x + d.x2 * w, y + d.y2 * h };
		case xray::DecorationKind.RADIAL:
			m.grad = { x + d.cx * w, y + d.cy * h, x + d.fx * w, y + d.fy * h };
			m.grad2 = { d.r > 0 ? d.r * short_side : short_side / 2, 0, 0, 0 };
		default:
	}
	// A CSS blur radius is a Gaussian with half its sigma.
	float reach = 0;
	if (d.shadow) {
		float sigma = d.shadow_blur > 0 ? d.shadow_blur / 2 * s : 0;
		m.sh = { d.shadow_dx * s, d.shadow_dy * s, sigma, d.shadow_spread * s };
		m.shc = decor_color(d.shadow_color, 0.35f);
		float off = math::max(math::abs(m.sh[0]), math::abs(m.sh[1]));
		reach = sigma * 3 + math::max(m.sh[3], 0.0f) + off;
	}
	if (d.inner_shadow) {
		float sigma = d.inner_blur > 0 ? d.inner_blur / 2 * s : 0;
		m.inner = { d.inner_dx * s, d.inner_dy * s, sigma, d.inner_spread * s };
		m.inc = decor_color(d.inner_color, 0.35f);
	}
	reach += 2;
	int index = (int)self.decors.len();
	self.decors.push(m);
	self.push_quad(x - reach, y - reach, x + w + reach, y + h + reach, 0, 0, 0, 0, 0, CMD_DECOR, index);
}

// paint_view fills the painter from a drawn view: the paint stream in order
// when the view recorded one, otherwise the plain cell grid.
fn void Painter.paint_view(&self, milktea::View v) {
	self.begin();
	if (v.paint_ops.len > 0) {
		foreach (op : v.paint_ops) {
			switch (op.kind) {
				case xray::PaintKind.DECORATION: self.decoration(op.decoration);
				case xray::PaintKind.TINT: self.tint(op.col, op.row, op.pixels, op.tint);
				case xray::PaintKind.CELL: self.cell(op.cell, op.col, op.row, true, op.pixels, op.bg_w, op.bg_h);
				case xray::PaintKind.CLIP: self.clip(op.col, op.row, op.bg_w, op.bg_h);
			}
		}
		return;
	}
	if (v.cells.ptr == null) return;
	for (sz row = 0; row < v.cells_height; row++) {
		for (sz col = 0; col < v.cells_width; col++) {
			self.cell(v.cells[row * v.cells_width + col], col, row, false);
		}
	}
}

// submit draws what the painter holds into the offscreen target.
fn void Painter.submit(&self, int fb_w, int fb_h) {
	atlas_upload();
	float[4] clear = { 0, 0, 0, 1 };
	mt_render(self.verts.array_view().ptr, self.quads(), self.cmds.array_view().ptr, (int)self.cmds.len(),
		self.decors.array_view().ptr, fb_w, fb_h, &clear);
}
