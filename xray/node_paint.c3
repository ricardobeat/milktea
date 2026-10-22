module xray;

import glaze;

// PaintResult is what a tree walk reports back to the caller beyond the
// pixels themselves.
struct PaintResult {
	// Where the terminal cursor belongs, if any node claimed it. When more
	// than one does, the last one painted wins — but content is expected to
	// claim it only when focused, so that should not arise.
	ContentCursor cursor;

	// Smallest repaint interval any node asked for, in milliseconds, or 0 if
	// none did. The runtime schedules one timer from this rather than each
	// node running its own.
	sz repaint_ms;
}

// paint walks a solved tree and draws it into buf.
// 
// Children are painted after their parent and later siblings after earlier
// ones, so a zstack layers in the order things were added. Nothing clips to
// its parent's rect — only to the buffer — because a shadow is drawn at an
// offset and would otherwise be cut off by the very node casting it.
// 
// The tree must already be solved against a rect inside buf.
// 
// scratch is a spare buffer used only when a node blends (see Node.alpha). It
// is grown as needed and reused across nodes and frames, so callers should
// hang one off something long-lived and pass its address. Passing null
// disables blending: those nodes paint opaque.
fn PaintResult ScreenBuffer.paint(&self, Node* root, ScreenBuffer** scratch = null, sz now_ms = 0) {
	PaintResult res;
	self.paint_node(root, &res, scratch);
	self.draw_cursor(&res, now_ms);
	return res;
}

// Default blink period for a drawn cursor, in milliseconds per phase.
const sz CURSOR_BLINK_MS = 500;

// draw_cursor runs a self-painting cursor's callback, last, once the grid is
// finished. It has to be last because the callback is handed the character
// already at that cell so it can show it through — which does not exist until
// everything else has painted.
// 
// now_ms drives the blink. xray has no clock of its own, so the caller
// supplies one; milktea::draw passes milktea::frame_ms().
fn void ScreenBuffer.draw_cursor(&self, PaintResult* res, sz now_ms) {
	ContentCursor c = res.cursor;
	if (!c.has_cursor || c.draw == null) return;
	if (c.x < 0 || c.y < 0 || (sz)c.x >= self.width || (sz)c.y >= self.height) return;

	sz period = c.blink_ms > 0 ? c.blink_ms : CURSOR_BLINK_MS;
	bool blink = ((now_ms / period) % 2) == 0;

	Cell* cell   = self.cell_at((sz)c.x, (sz)c.y);
	String under = (cell != null && cell.content_len > 0) ? cell.content_str() : "";

	// A drawn cursor animates, so ask for a repaint on its own blink period.
	// This is set before painting and regardless of what the callback returns:
	// an empty return is the blink's off phase, and skipping the request there
	// would stop the animation until something else forced a frame.
	if (res.repaint_ms == 0 || period < res.repaint_ms) res.repaint_ms = period;

	String drawn = c.draw(c.x, c.y, blink, under);
	// An empty return means "leave the cell alone", which is how a blinking
	// cursor spends its off phase.
	if (drawn.len == 0) return;
	// overlay_char writes exactly one cell slot, so a wide glyph — an emoji,
	// a katakana character — cannot displace its neighbour.
	self.overlay_char((sz)c.x, (sz)c.y, drawn, default_style());
}

fn void ScreenBuffer.paint_node(&self, Node* n, PaintResult* res, ScreenBuffer** scratch) {
	if (n == null) return;
	Rect r = n.computed_rect;

	if (n.repaint_ms > 0 && (res.repaint_ms == 0 || n.repaint_ms < res.repaint_ms)) {
		res.repaint_ms = n.repaint_ms;
	}

	// alpha 0 is "fully invisible": skip the node, its effects, and its
	// subtree. A fade-out's final frame reaches value exactly 0, so this is
	// what keeps that last painted frame from leaving a ghost behind. The
	// repaint request is collected above first: a fade-in's opening frame
	// also sits at alpha 0, and it must still ask for the next frame.
	if (n.alpha_value == 0) return;

	// The shadow goes down first so the content lands on top of it. A node's
	// alpha scales the shadow along with the content: they are one object, so
	// a half-faded panel casting a solid shadow would read as two.
	if (n.layer_style.shadow.enabled) {
		Shadow s = n.layer_style.shadow;
		s.opacity = scale_opacity(s.opacity, n.alpha_value);
		if (s.opacity > 0) self.render_shadow(r.x, r.y, r.w, r.h, s);
	}

	if (n.has_box() && r.w > 0 && r.h > 0) {
		Color bg = n.box.bg;
		if (bg.kind == ColorKind.TRUECOLOR && bg.effective_alpha() < 255) {
			self.paint_translucent_box(r, n.box, n.alpha_value, scratch);
		} else {
			self.paint_string(r, n.box.with_width(r.w).with_height(r.h).render(""), n.alpha_value, scratch);
		}
	}

	Insets f = n.frame();
	Rect inner = r.inset(f.left, f.top, f.right, f.bottom);
	if (n.content != null && inner.w > 0 && inner.h > 0) {
		if (&n.content.paint) {
			n.content.paint(self, inner);
		} else if (&n.content.render) {
			self.paint_string(inner, n.content.render(inner), n.alpha_value, scratch);
		}

		if (&n.content.cursor) {
			ContentCursor c = n.content.cursor(inner);
			if (c.has_cursor) res.cursor = c;
		}
	}

	for (sz i = 0; i < n.child_count; i++) {
		self.paint_node(n.children[i], res, scratch);
	}

	// Inner shadow sits over the node's own content but under its children,
	// matching how a shadow inside a box darkens the box rather than what
	// is stacked on it.
	if (n.layer_style.inner_shadow.enabled) {
		InnerShadow is = n.layer_style.inner_shadow;
		is.opacity = scale_opacity(is.opacity, n.alpha_value);
		if (is.opacity > 0) self.render_inner_shadow(r.x, r.y, r.w, r.h, is);
	}
}

// paint_translucent_box paints a box whose background lets what is beneath
// show through. The background is blended over both colors of every cell in
// r and the glyphs stay, so a half block keeps its shape under the tint. A
// translucent background is flat: bg_gradient does not apply.
// 
// The border is drawn over the tint at the node's alpha. A border_bg puts a
// background of its own under the border cells in place of the tint, and a
// TRANSPARENT one leaves them as they were.
fn void ScreenBuffer.paint_translucent_box(&self, Rect r, glaze::Style box, char alpha, ScreenBuffer** scratch) {
	glaze::Border b = box.border;
	bool bordered = b.top.len > 0 || b.bottom.len > 0 || b.left.len > 0 || b.right.len > 0;
	// The cells inside the border, relative to r.
	sz top = b.top.len > 0 ? 1 : 0;
	sz left = b.left.len > 0 ? 1 : 0;
	sz bottom = r.h - (b.bottom.len > 0 ? 1 : 0);
	sz right = r.w - (b.right.len > 0 ? 1 : 0);

	Color tint = box.bg;
	tint.a = scale_alpha(tint, alpha);
	Color edge_bg = box.border_bg;
	if (edge_bg.kind == ColorKind.NONE) edge_bg = tint;
	if (edge_bg.kind == ColorKind.TRUECOLOR) edge_bg.a = scale_alpha(edge_bg, alpha);

	for (sz y = 0; y < r.h; y++) {
		sz dy = r.y + y;
		if (dy < 0 || dy >= self.height) continue;
		for (sz x = 0; x < r.w; x++) {
			sz dx = r.x + x;
			if (dx < 0 || dx >= self.width) continue;
			bool inside = y >= top && y < bottom && x >= left && x < right;
			Color c = inside ? tint : edge_bg;
			if (c.kind != ColorKind.TRUECOLOR) continue;
			Cell* cell = &self.cells[dy * self.width + dx];
			cell.style.bg = c.blend_over(cell.style.bg);
			if (cell.style.fg.kind == ColorKind.TRUECOLOR) cell.style.fg = c.blend_over(cell.style.fg);
		}
		self.dirty_lines[dy] = true;
	}

	if (!bordered) return;
	// The border's own background was painted above, so the glyphs go on
	// without one and keep it.
	glaze::Style edge = { .border = b, .border_color = box.border_color, .border_gradient = box.border_gradient,
		.corner_color = box.corner_color, .border_animation = box.border_animation, .anim_speed_ms = box.anim_speed_ms };
	String s = edge.with_width(r.w).with_height(r.h).render("");
	if (alpha < 255 && scratch != null) {
		self.paint_blended(r, s, alpha, scratch);
		return;
	}
	ScreenBuffer* own = null;
	defer if (own != null) {
		own.destroy();
		mem::free(own);
	}
	if (scratch == null) scratch = &own;
	ScreenBuffer* tmp = *scratch;
	if (tmp == null) {
		tmp = new_screen_buffer(r.w, r.h);
		*scratch = tmp;
	} else if (tmp.width < r.w || tmp.height < r.h) {
		tmp.resize(tmp.width > r.w ? tmp.width : r.w, tmp.height > r.h ? tmp.height : r.h);
	}
	tmp.clear();
	tmp.render_ansi_string(0, 0, s, default_style());
	for (sz y = 0; y < r.h; y++) {
		for (sz x = 0; x < r.w; x++) {
			if (y >= top && y < bottom && x >= left && x < right) continue;
			Cell c = tmp.cells[y * tmp.width + x];
			if (c.style.bg.kind == ColorKind.NONE) c.style.bg = color_transparent();
			self.set_cell(r.x + x, r.y + y, c);
		}
	}
}

// scale_alpha is c's alpha dimmed by a node's alpha. It never reaches 0,
// which a Color reads as opaque.
fn char scale_alpha(Color c, char alpha) @local {
	char a = (char)(((sz)c.effective_alpha() * (sz)alpha + 127) / 255);
	return a == 0 ? 1 : a;
}

// paint_string paints a rendered string over r, blended when the node is
// translucent.
fn void ScreenBuffer.paint_string(&self, Rect r, String s, char alpha, ScreenBuffer** scratch) {
	if (s.len == 0) return;
	if (alpha < 255 && scratch != null) {
		self.paint_blended(r, s, alpha, scratch);
		return;
	}
	if (r.x + r.w <= 0 || r.y + r.h <= 0) return;
	// Clipped to the rect: a string is not always the size it was asked to
	// be, and one that is not would spill into its neighbours.
	sz max_row = r.y + r.h < self.height ? r.y + r.h : self.height;
	sz max_col = r.x + r.w < self.width ? r.x + r.w : self.width;
	// Text has no background of its own unless it sets one, as in CSS: where
	// it does not, what is painted beneath shows through around its glyphs.
	Style see_through = default_style().set_bg(color_transparent());
	self.render_ansi_string((sz)r.x, (sz)r.y, s, see_through, max_row, max_col);
}

// scale_opacity dims an effect's opacity by a node's alpha, so shadows fade
// with the node that casts them.
// 
// 255 — the opaque default — leaves the opacity untouched, and every other
// value scales proportionally, rounding to nearest so a nearly-opaque node
// does not lose its shadow to truncation. (Alpha 0 never reaches here: paint
// skips such a node's subtree entirely.)
fn char scale_opacity(char opacity, char alpha) @local {
	if (alpha == 255) return opacity;
	return (char)(((sz)opacity * (sz)alpha + 127) / 255);
}

// overlay paints an ANSI string over a w×h box at x, y, for a program that
// draws into its own buffer rather than through a tree. Opaque (alpha 255)
// replaces what is there, except for blank cells when transparent is set; any
// other alpha blends the string's colors over the screen and keeps the
// characters beneath, as a translucent layer does; 0 paints nothing.
fn void ScreenBuffer.overlay(&self, sz x, sz y, sz w, sz h, String s, char alpha = 255, bool transparent = false) {
	if (alpha == 0 || w <= 0 || h <= 0) return;
	if (alpha == 255) {
		self.blit_ansi(x, y, w, h, s, transparent);
		return;
	}
	ScreenBuffer* scratch = null;
	defer if (scratch != null) {
		scratch.destroy();
		mem::free(scratch);
	}
	self.paint_blended({ .x = x, .y = y, .w = w, .h = h }, s, alpha, &scratch);
}

// paint_blended renders content into a scratch buffer and blends its colors
// over what is already at r, leaving the underlying characters in place.
// That is what makes a translucent panel dim the screen behind it instead of
// erasing it.
fn void ScreenBuffer.paint_blended(&self, Rect r, String content, char alpha, ScreenBuffer** scratch) {
	ScreenBuffer* tmp = *scratch;
	if (tmp == null) {
		tmp = new_screen_buffer((sz)r.w, (sz)r.h);
		*scratch = tmp;
	} else if (tmp.width < (sz)r.w || tmp.height < (sz)r.h) {
		sz w = tmp.width < (sz)r.w ? (sz)r.w : tmp.width;
		sz h = tmp.height < (sz)r.h ? (sz)r.h : tmp.height;
		tmp.resize(w, h);
	}
	// The scratch is shared across nodes and frames, so it has to start
	// empty or a previous node's content bleeds through.
	tmp.clear();
	tmp.render_ansi_string(0, 0, content, default_style());

	for (sz cy = 0; cy < (sz)r.h; cy++) {
		for (sz cx = 0; cx < (sz)r.w; cx++) {
			sz dx = (sz)r.x + cx;
			sz dy = (sz)r.y + cy;
			// sz is signed: a node scrolled off the top or left gives
			// negative coordinates that would index before the buffer.
			if (dx < 0 || dy < 0 || dx >= self.width || dy >= self.height) continue;

			Cell src = tmp.cells[cy * tmp.width + cx];
			src.style.bg.a = alpha;
			src.style.fg.a = alpha;
			Cell* dst = &self.cells[dy * self.width + dx];

			if (src.style.bg.kind == ColorKind.TRUECOLOR) {
				dst.style.bg = src.style.bg.blend_over(dst.style.bg);
			}
			if (src.style.fg.kind == ColorKind.TRUECOLOR) {
				dst.style.fg = src.style.fg.blend_over(dst.style.fg);
			}
			self.dirty_lines[dy] = true;
		}
	}
}