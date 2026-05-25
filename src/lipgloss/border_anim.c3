module lipgloss;

import std::math;
import std::core::dstring;

// ── Tick interval for each animation type ────────────────────────────────────

fn int border_anim_tick_ms(BorderAnimation anim) {
	switch (anim) {
		case PULSE: return 16;  // ~60fps
		case RAINBOW: return 16;  // ~60fps
		case RACE: return 50;  // ~20fps — snappy, visible trail
		default: return 0;
	}
}

// ── Internal color helpers ───────────────────────────────────────────────────

fn Color _hsl(int hue255, int sat255, int lum255) @local {
	double h = (double)hue255 * 360.0 / 255.0;
	double s = (double)sat255 / 255.0;
	double l = (double)lum255 / 255.0;
	double c = (1.0 - math::abs(2.0 * l - 1.0)) * s;
	// frac = (h/60) mod 2 — implemented without fmod



	double h60   = h / 60.0;
	double frac2 = h60 - 2.0 * (double)(int)(h60 / 2.0);
	double x     = c * (1.0 - math::abs(frac2 - 1.0));
	double m     = l - c / 2.0;
	double r1    = 0;
	double g1    = 0;
	double b1    = 0;
	if (h < 60) {
		r1 = c;
		g1 = x;
	} else if (h < 120) {
		r1 = x;
		g1 = c;
	} else if (h < 180) {
		g1 = c;
		b1 = x;
	} else if (h < 240) {
		g1 = x;
		b1 = c;
	} else if (h < 300) {
		r1 = x;
		b1 = c;
	} else {
		r1 = c;
		b1 = x;
	}
	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)((r1 + m) * 255.0),
		.g = (char)((g1 + m) * 255.0),
		.b = (char)((b1 + m) * 255.0),
	};
}

fn int _sin255(int deg) @local {
	double rad = (double)deg * 3.14159265 / 180.0;
	double s   = math::sin(rad);
	return (int)((s + 1.0) * 127.5);
}

fn int _clamp255(int v) @local {
	if (v < 0) return 0;
	if (v > 255) return 255;
	return v;
}

fn Color _color_lerp(Color base, Color target, int t255) @local {
	int inv = 255 - t255;
	return {
		.kind = ColorKind.TRUECOLOR,
		.r = (char)((int)base.r * inv / 255 + (int)target.r * t255 / 255),
		.g = (char)((int)base.g * inv / 255 + (int)target.g * t255 / 255),
		.b = (char)((int)base.b * inv / 255 + (int)target.b * t255 / 255),
	};
}

// ── Border animation rendering ───────────────────────────────────────────────

// wrap_animated renders a border around content of the given dimensions,
// applying the selected animation mode.  `time_ms` is the current wall-clock
// time in milliseconds (e.g. from jsrt_now_ms()).  The base colour is taken
// from `style.border_fg`; if NONE, white is used.
// 
// Clockwise perimeter positions (0-based):
//   0            : top_left corner
//   1..W         : top edge (left→right)
//   W+1          : top_right corner
//   W+2..W+1+H   : right edge (top→bottom)
//   W+2+H        : bottom_right corner
//   W+3+H..2W+2+H: bottom edge (right→left)
//   2W+3+H       : bottom_left corner
//   2W+4+H..total-1: left edge (bottom→top)
//   total = 2*(W+H)+4
fn String Border.wrap_animated(self, int content_w, int content_h, BorderAnimation anim, Style style, long time_ms) {
	if (anim == BorderAnimation.NONE) return self.wrap_with_color("", style.border_fg);

	bool is_empty = self.top.len == 0 && self.bottom.len == 0 && self.left.len == 0 && self.right.len == 0
		&& self.top_left.len == 0
		&& self.top_right.len == 0
		&& self.bottom_left.len == 0
		&& self.bottom_right.len == 0;
	if (is_empty) return "";

	// Total perimeter cells in clockwise order.
	int cw          = content_w;
	int ch          = content_h;
	int total_perim = 2 * (cw + ch) + 4;
	if (total_perim <= 0) total_perim = 1;

	Color base = style.border_fg.kind != ColorKind.NONE ? style.border_fg : color_hex("#ffffff");
	int speed  = style.border_anim_speed > 0 ? style.border_anim_speed : 1000;
	int t      = (int)(time_ms % (long)speed);

	DString out = dstring::temp();

	// ── Top row: pos 0 (TL corner) + 1..cw (top edge) + cw+1 (TR corner) ──
	out.append_string(_border_cell_color(self.top_left, 0, total_perim, anim, base, t, speed));
	for (int i = 0; i < cw; i++) {
		out.append_string(_border_cell_color(self.top, 1 + i, total_perim, anim, base, t, speed));
	}
	out.append_string(_border_cell_color(self.top_right, cw + 1, total_perim, anim, base, t, speed));
	out.append_string("\x1b[0m\n");

	// ── Body rows: left border rendered first, then content, then right ──
	// Left edge walks backwards (bottom→top) in the clockwise perimeter,
	// so row 0 (top body row) is at position total-1 and row ch-1 is at 2*cw+4+ch.
	// Right edge walks top→bottom: row 0 is at cw+2, row ch-1 is at cw+1+ch.
	for (int row = 0; row < ch; row++) {
		int left_pos  = total_perim - 1 - row; // clockwise: left edge going up
		int right_pos = cw + 2 + row;         // clockwise: right edge going down
		out.append_string(_border_cell_color(self.left, left_pos, total_perim, anim, base, t, speed));
		for (int j = 0; j < cw; j++) out.append_char(' ');
		out.append_string(_border_cell_color(self.right, right_pos, total_perim, anim, base, t, speed));
		out.append_string("\x1b[0m\n");
	}

	// ── Bottom row: BL corner + bottom edge (right→left) + BR corner ────
	// Clockwise: BR is at cw+2+ch, bottom edge is cw+3+ch..2*cw+2+ch, BL is 2*cw+3+ch.
	// Rendered left-to-right on screen, so BL first, then bottom (reversed), then BR.
	out.append_string(_border_cell_color(self.bottom_left, 2 * cw + 3 + ch, total_perim, anim, base, t, speed));
	for (int i = 0; i < cw; i++) {
		// bottom edge in clockwise order goes right→left, so screen column i
		// corresponds to clockwise position (2*cw+2+ch - i).
		int pos = 2 * cw + 2 + ch - i;
		out.append_string(_border_cell_color(self.bottom, pos, total_perim, anim, base, t, speed));
	}
	out.append_string(_border_cell_color(self.bottom_right, cw + 2 + ch, total_perim, anim, base, t, speed));
	out.append_string("\x1b[0m");

	return out.copy_str(tmem);
}

// _border_cell_color returns the ANSI string for a single border cell
// (SGR open + character), with colour determined by the animation mode.
fn String _border_cell_color(String ch, int pos, int total, BorderAnimation anim, Color base, int t, int speed) @local {
	DString s = dstring::temp();

	Color c;
	switch (anim) {
		case PULSE:

			{
				int phase = t * 360 / speed;
				int wave  = _sin255(phase);
				c = _color_lerp({ .kind = ColorKind.TRUECOLOR, .r = 0, .g = 0, .b = 0 }, base, wave);
			}
		case RAINBOW:

			{
				int hue = ((pos * 255 / total) + (t * 255 / speed)) & 0xff;
				c = _hsl(hue, 255, 140);
			}
		case RACE:

			{
				int head = t * total / speed;
				int dist = head - pos;
				if (dist < 0) dist += total;
				int trail = 20;
				if (dist <= trail) {
					int bright = (trail - dist) * 255 / trail;
					Color dim = {
						.kind = ColorKind.TRUECOLOR,
						.r = (char)((int)base.r / 4),
						.g = (char)((int)base.g / 4),
						.b = (char)((int)base.b / 4)
					};
					c = _color_lerp(dim, base, bright);
				} else {
					c = {
						.kind = ColorKind.TRUECOLOR,
						.r = (char)((int)base.r / 8),
						.g = (char)((int)base.g / 8),
						.b = (char)((int)base.b / 8)
					};
				}
			}
		default: { c = base; }
	}

	s.append_string("\x1b[38;2;");
	s.appendf("%d;%d;%d", (int)c.r, (int)c.g, (int)c.b);
	s.append_char('m');
	s.append_string(ch);
	return s.str_view();
}