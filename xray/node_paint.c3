module xray;

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
	int repaint_ms;
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
fn PaintResult ScreenBuffer.paint(&self, Node* root, ScreenBuffer** scratch = null, long now_ms = 0) {
	PaintResult res;
	self.paint_node(root, &res, scratch);
	self.draw_cursor(&res, now_ms);
	return res;
}

// Default blink period for a drawn cursor, in milliseconds per phase.
const int CURSOR_BLINK_MS = 500;

// draw_cursor runs a self-painting cursor's callback, last, once the grid is
// finished. It has to be last because the callback is handed the character
// already at that cell so it can show it through — which does not exist until
// everything else has painted.
//
// now_ms drives the blink. xray has no clock of its own, so the caller
// supplies one; milktea::draw passes milktea::time_ms().
fn void ScreenBuffer.draw_cursor(&self, PaintResult* res, long now_ms) {
	ContentCursor c = res.cursor;
	if (!c.has_cursor || c.draw == null) return;
	if (c.x < 0 || c.y < 0 || (sz)c.x >= self.width || (sz)c.y >= self.height) return;

	int period = c.blink_ms > 0 ? c.blink_ms : CURSOR_BLINK_MS;
	bool blink = ((now_ms / (long)period) % 2) == 0;

	Cell* cell = self.cell_at((sz)c.x, (sz)c.y);
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

	// The shadow goes down first so the content lands on top of it.
	if (n.layer_style.shadow.enabled) {
		self.render_shadow(r.x, r.y, r.w, r.h, n.layer_style.shadow);
	}

	if (n.content != null && r.w > 0 && r.h > 0) {
		String s = n.content.render(r);
		if (s.len > 0) {
			if (n.alpha_value != 0 && n.alpha_value < 255 && scratch != null) {
				self.paint_blended(r, s, n.alpha_value, scratch);
			} else {
				self.render_ansi_string((sz)r.x, (sz)r.y, s, default_style());
			}
		}

		if (&n.content.cursor) {
			ContentCursor c = n.content.cursor(r);
			if (c.has_cursor) res.cursor = c;
		}
	}

	for (int i = 0; i < n.child_count; i++) {
		self.paint_node(n.children[i], res, scratch);
	}

	// Inner shadow sits over the node's own content but under its children,
	// matching how a shadow inside a box darkens the box rather than what
	// is stacked on it.
	if (n.layer_style.inner_shadow.enabled) {
		self.render_inner_shadow(r.x, r.y, r.w, r.h, n.layer_style.inner_shadow);
	}
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
		sz w = tmp.width  < (sz)r.w ? (sz)r.w : tmp.width;
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
