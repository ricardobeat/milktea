module glaze;

import std::core::dstring;
import utf8;

// BorderAnimation selects an animated border rendering mode.
enum BorderAnimation : char {
	NONE,    // static border (default)
	PULSE,   // pulses the base color in brightness
	RAINBOW, // rainbow colors spin around the perimeter
	RACE,    // a dash of bright color races around, leaving a dim trail
}

// codepoint_width is the number of terminal columns a codepoint takes: 0, 1
// or 2. See utf8::width.
fn sz codepoint_width(uint cp) => utf8::width(cp);


// skip_escape returns the index just past the escape sequence starting at
// `start` (which must point at ESC), or s.len if the sequence is unterminated.
//
// CSI (ESC [ ...) ends at the first byte in 0x40..0x7e. OSC (ESC ] ...) runs
// until BEL or ST (ESC \) and may legitimately contain letters — treating it
// like a CSI ended the scan on the first letter in the payload and counted the
// remainder as visible text. viewport.c3 emits OSC 52 for clipboard writes, so
// this is a sequence that really does flow through here.
fn sz skip_escape(String s, sz start) {
	sz i = start + 1; // past ESC
	if (i >= s.len) return s.len;

	char kind = s[i];
	if (kind == ']') {
		i++;
		while (i < s.len) {
			if (s[i] == 0x07) return i + 1; // BEL
			if (s[i] == 0x1b && i + 1 < s.len && s[i + 1] == '\\') return i + 2; // ST
			i++;
		}
		return s.len;
	}

	if (kind == '[') {
		i++;
		while (i < s.len) {
			if (s[i] >= 0x40 && s[i] <= 0x7e) return i + 1;
			i++;
		}
		return s.len;
	}

	// Two-byte escapes (ESC M, ESC 7, ...) and anything unrecognised: consume
	// the single following byte.
	return i + 1;
}

// truncate_to_width returns the longest prefix of `s` whose display width is
// at most `max_width`, measured the same way as string_width.
//
// Escape sequences are carried through whole and cost no width, so the result
// never ends in the middle of one — cutting at a byte index would emit the
// leading bytes of a CSI as literal visible text. Multi-byte characters are
// likewise kept intact, and a wide glyph that would straddle the limit is
// dropped rather than half-included.
fn String truncate_to_width(String s, sz max_width) {
	if (max_width <= 0) return "";
	sz w = 0;
	sz i  = 0;
	while (i < s.len) {
		if (s[i] == '\x1b') {
			i = skip_escape(s, i);
			continue;
		}
		uint cp;
		sz char_len = utf8::decode(s[i..], &cp);
		sz cw       = codepoint_width(cp);
		if (w + cw > max_width) break;
		w += cw;
		i += char_len;
	}
	return s[:i];
}

// utf8_width_at returns the display width of the UTF-8 sequence starting at
// index `i`. Callers stepping through a string character by character should
// advance their column counter by this amount, not by one: a wide glyph (CJK,
// emoji) occupies two terminal columns, so counting it once misaligns
// selection and padding on lines that contain one.
fn sz utf8_width_at(String s, sz i) {
	uint cp;
	utf8::decode(s[i..], &cp);
	return codepoint_width(cp);
}

// string_width returns the terminal display width of a string, skipping ANSI
// escape sequences. Uses the same codepoint width rules as xray::char_width.
fn sz string_width(String s) {
	sz w = 0;
	sz i  = 0;
	while (i < s.len) {
		if (s[i] == '\x1b') {
			i = skip_escape(s, i);
			continue;
		}

		// A byte that cannot start a character takes no width.
		if (!utf8::is_lead(s[i])) {
			i++;
			continue;
		}
		uint cp;
		i += utf8::decode(s[i..], &cp);

		w += codepoint_width(cp);
	}
	return w;
}

struct Style {
	Color fg;
	Color bg;
	Color border_color;
	Color corner_color;
	// Background behind the border. Unset means the border sits on the block's
	// own background, which is right for a box drawn around its content. A
	// border used as a drop shadow wants the surface behind the block instead,
	// so that the half of each cell the shadow does not cover shows it.
	Color border_bg;
	// Second border color. When set, the border runs from border_color on its
	// top row to this on its bottom row, one step per row, blended in LUV.
	Color border_gradient;
	// Second background color. When set, the block's background is a vertical
	// gradient from bg to this, one step per row, interpolated in LUV so the
	// change reads evenly. Unset leaves bg flat.
	Color bg_gradient;
	bool bold;
	bool italic;
	bool underline;
	sz pad_top;
	sz pad_right;
	sz pad_bottom;
	sz pad_left;
	sz width; // 0 = auto (don't pad)
	// Bounds on an auto width, total like width: the block hugs its content
	// but is at least min_width and at most max_width wide, wrapping to fit
	// the latter. 0 leaves that side unbounded; a set width overrides both.
	sz min_width;
	sz max_width;
	// Text wider than width wraps onto more lines unless this is set, in
	// which case it runs past the edge, like CSS white-space: nowrap.
	bool nowrap;
	sz height; // 0 = auto
	Position align_h; // horizontal alignment within width
	Position align_v; // vertical alignment within height
	Border border; // zero value = no border
	BorderAnimation border_animation; // NONE = static
	sz anim_speed_ms; // ms per full cycle (default 1000)
}

fn Style style() {
	return { };
}

fn Style Style.foreground(self, Color c) {
	Style s = self;
	s.fg = c;
	return s;
}

fn Style Style.background(self, Color c) {
	Style s = self;
	s.bg = c;
	return s;
}

fn Style Style.with_bold(self, bool v) {
	Style s = self;
	s.bold = v;
	return s;
}

fn Style Style.with_italic(self, bool v) {
	Style s = self;
	s.italic = v;
	return s;
}

fn Style Style.with_underline(self, bool v) {
	Style s = self;
	s.underline = v;
	return s;
}

// pad applies the same padding to all four sides.
fn Style Style.pad(self, sz n) => self.padding(n, n, n, n);

// pad_x and pad_y pad one axis, which is the common case for a label or a
// status line that needs breathing room on the sides but not above.
fn Style Style.pad_x(self, sz n) {
	Style s = self;
	s.pad_left = n;
	s.pad_right = n;
	return s;
}

fn Style Style.pad_y(self, sz n) {
	Style s = self;
	s.pad_top = n;
	s.pad_bottom = n;
	return s;
}

fn Style Style.padding(self, sz top, sz right, sz bottom, sz left) {
	Style s = self;
	s.pad_top = top;
	s.pad_right = right;
	s.pad_bottom = bottom;
	s.pad_left = left;
	return s;
}

fn Style Style.with_width(self, sz w) {
	Style s = self;
	s.width = w;
	return s;
}

fn Style Style.with_border(self, Border b) {
	Style s = self;
	s.border = b;
	return s;
}

fn Style Style.border_fg(self, Color c) {
	Style s = self;
	s.border_color = c;
	return s;
}

fn Style Style.corner_fg(self, Color c) {
	Style s = self;
	s.corner_color = c;
	return s;
}

fn Style Style.border_anim(self, BorderAnimation anim) {
	Style s = self;
	s.border_animation = anim;
	if (s.anim_speed_ms == 0) s.anim_speed_ms = 1000;
	return s;
}

fn Style Style.border_anim_speed(self, sz ms) {
	Style s = self;
	s.anim_speed_ms = ms;
	return s;
}

fn Style Style.with_height(self, sz h) {
	Style s = self;
	s.height = h;
	return s;
}

fn Style Style.align(self, Position h, Position v) {
	Style s = self;
	s.align_h = h;
	s.align_v = v;
	return s;
}

fn Style Style.align_horizontal(self, Position h) {
	Style s = self;
	s.align_h = h;
	return s;
}

fn Style Style.align_vertical(self, Position v) {
	Style s = self;
	s.align_v = v;
	return s;
}

fn Style Style.with_fg(self, String hex) {
	return self.foreground(color_hex(hex));
}

fn Style Style.with_bg(self, String hex) {
	return self.background(color_hex(hex));
}

// measure_height renders content at the given outer width and counts the output lines.
// Useful for auto-sizing a box before committing it to a layout rect.
fn sz Style.measure_height(self, String input, sz outer_width) {
	// width() means total outer width (border+pad+content); render() subtracts border internally.
	Style sized     = self.with_width(outer_width);
	String rendered = sized.render(input);
	sz lines       = 1;
	for (sz i = 0; i < rendered.len; i++) {
		if (rendered[i] == '\n') lines++;
	}
	return lines;
}

fn void color_whitespace(DString* buf, Color* bg, bool has_bg, sz n) @local {
	if (n <= 0) return;
	if (has_bg) {
		buf.append_string("\x1b[");
		bg.write_sgr_params(buf, false);
		buf.append_string("m");
	}
	for (sz j = 0; j < n; j++) buf.append_char(' ');
	if (has_bg) buf.append_string("\x1b[0m");
}

// next_sgr_channels looks at the escape sequence starting at `pos`, if there
// is one, and reports whether it sets a foreground and/or a background color.
// A style re-applying itself after an inner reset uses this to leave alone
// whatever the content is about to set for itself.
fn void next_sgr_channels(String s, sz pos, bool* fg, bool* bg) @local {
	*fg = false;
	*bg = false;
	if (pos + 2 >= s.len || s[pos] != '\x1b' || s[pos + 1] != '[') return;

	sz i = pos + 2;
	sz code = 0;
	bool have = false;
	while (i < s.len && s[i] != 'm') {
		if (s[i] >= '0' && s[i] <= '9') {
			code = code * 10 + (sz)(s[i] - '0');
			have = true;
		} else if (s[i] == ';') {
			if (have) mark_sgr_channel(code, fg, bg);
			code = 0;
			have = false;
		} else {
			// Not an SGR sequence.
			return;
		}
		i++;
	}
	if (i < s.len && have) mark_sgr_channel(code, fg, bg);
}

// mark_sgr_channel records which channel one SGR parameter sets. 30-38 and
// 90-97 are foreground, 40-48 and 100-107 background; 39 and 49 reset a
// channel to the default, which still counts as the content deciding it.
fn void mark_sgr_channel(sz code, bool* fg, bool* bg) @local {
	if ((code >= 30 && code <= 39) || (code >= 90 && code <= 97)) *fg = true;
	if ((code >= 40 && code <= 49) || (code >= 100 && code <= 107)) *bg = true;
}

// frame_width is the columns the style spends on its border and padding.
fn sz Style.frame_width(self) {
	return self.pad_left + self.pad_right
		+ (self.border.left.len > 0 ? 1 : 0) + (self.border.right.len > 0 ? 1 : 0);
}

fn Style Style.with_min_width(self, sz w) {
	Style s = self;
	s.min_width = w;
	return s;
}

fn Style Style.with_max_width(self, sz w) {
	Style s = self;
	s.max_width = w;
	return s;
}

// write_sgr writes one SGR sequence that turns on what it is given, or
// nothing when that is nothing.
fn void write_sgr(DString* out, bool bold, bool italic, bool underline, Color fg, Color bg) @local {
	out.append_string("\x1b[");
	sz start = out.len();
	if (bold) out.append_string("1;");
	if (italic) out.append_string("3;");
	if (underline) out.append_string("4;");
	if (fg.kind != ColorKind.NONE) {
		fg.write_sgr_params(out, true);
		out.append_char(';');
	}
	if (bg.kind != ColorKind.NONE) {
		bg.write_sgr_params(out, false);
		out.append_char(';');
	}
	if (out.len() == start) {
		out.chop(start - 2);
	} else {
		(*out)[out.len() - 1] = 'm';
	}
}

fn String Style.render(self, String input) {
	DString out = dstring::temp();

	if (self.width == 0 && (self.min_width > 0 || self.max_width > 0)) {
		sz outer = widest_line(input) + self.frame_width();
		if (self.max_width > 0 && outer > self.max_width) outer = self.max_width;
		if (self.min_width > 0 && outer < self.min_width) outer = self.min_width;
		return self.with_width(outer).render(input);
	}

	// A set width is the most the content may take, so wrap to what is left
	// of it inside the border and padding before splitting into lines.
	if (self.width > 0 && !self.nowrap) {
		input = wrap_text(input, self.width - self.frame_width());
	}

	sz line_count = 1;
	for (sz i = 0; i < input.len; i++) {
		if (input[i] == '\n') line_count++;
	}

	// Determine target width.
	// In Go glaze, Width(N) means total output = N (border + padding included).
	// So we subtract border and padding from the requested width to get the
	// content area width.
	sz border_h = 0;
	bool border_is_empty = self.border.is_empty();
	if (!border_is_empty) {
		border_h = 2; // left + right border chars
	}

	sz target_width = self.width;
	if (target_width > 0) {
		// Subtract border and padding to get content area
		target_width = target_width - border_h - self.pad_left - self.pad_right;
		if (target_width < 1) target_width = 1;
	} else {
		// Auto-size to widest line
		target_width = widest_line(input);
	}

	bool has_attrs = self.fg.kind != ColorKind.NONE || self.bg.kind != ColorKind.NONE || self.bold || self.italic
		|| self.underline;
	bool has_bg = self.bg.kind != ColorKind.NONE;

	// The prefix that opens the content depends only on the style, so it is
	// built once rather than rebuilt for every line.
	DString prefix = dstring::temp();
	write_sgr(&prefix, self.bold, self.italic, self.underline, self.fg, self.bg);
	String sgr_prefix = prefix.str_view();

	// Total line width = content + padding (border is applied after)
	sz line_width = target_width + self.pad_left + self.pad_right;

	// Build content into a temp buffer first, then add height alignment.
	DString body = dstring::temp();

	// Top padding lines.
	for (sz i = 0; i < self.pad_top; i++) {
		color_whitespace(&body, &self.bg, has_bg, line_width);
		body.append_char('\n');
	}

	// Content lines.
	for (sz start = 0; start <= input.len;) {
		sz end = start;
		while (end < input.len && input[end] != '\n') end++;
		String line = input[start:end - start];
		start = end + 1;

		// Build styled line: pad_left + [align_h lead] + content + fill + pad_right.
		sz content_w   = string_width(line);
		sz slack       = target_width - content_w;
		if (slack < 0) slack = 0;
		sz h_lead      = 0;
		if (self.align_h == Position.CENTER) { h_lead = slack / 2; }
		else if (self.align_h == Position.RIGHT) { h_lead = slack; }
		sz fill        = slack - h_lead;

		// Pad left + horizontal alignment lead.
		color_whitespace(&body, &self.bg, has_bg, self.pad_left + h_lead);

		// Content (styled).
		if (has_attrs) {
			body.append_string(sgr_prefix);
			// Write line content, re-applying outer style after any inner resets.
			sz li = 0;
			while (li < line.len) {
				// Detect \x1b[0m or \x1b[0;...m (full reset)
				if (line[li] == '\x1b' && li + 2 < line.len && line[li+1] == '[') {
					// Find end of escape
					sz esc_start = li;
					li += 2;
					while (li < line.len && line[li] != 'm' && line[li] != 'A' && line[li] != 'B'
						&& line[li] != 'C' && line[li] != 'D' && line[li] != 'H'
						&& line[li] != 'J' && line[li] != 'K') li++;
					if (li < line.len) li++;
					body.append_string(line[esc_start:li - esc_start]);
					// A reset inside the content drops this style along with the
					// content's own, so re-apply it — but only the channels the
					// content does not set for itself right after. Content that
					// resets and immediately re-colors, as a nested border does,
					// would otherwise have its color overwritten by this one.
					if (line[esc_start + 2] == '0') {
						// The reset may carry its own colors — \x1b[0;38;2;..m
						// is a reset and a foreground in one sequence — so look
						// inside it as well as at whatever follows.
						bool sets_fg;
						bool sets_bg;
						next_sgr_channels(line[esc_start:li - esc_start], 0, &sets_fg, &sets_bg);
						if (!sets_fg || !sets_bg) {
							bool nfg;
							bool nbg;
							next_sgr_channels(line, li, &nfg, &nbg);
							sets_fg = sets_fg || nfg;
							sets_bg = sets_bg || nbg;
						}
						Color none = { .kind = ColorKind.NONE };
						write_sgr(&body, self.bold && !sets_fg, false, false,
							sets_fg ? none : self.fg, sets_bg ? none : self.bg);
					}
				} else {
					body.append_char(line[li]);
					li++;
				}
			}
			body.append_string("\x1b[0m");
		} else {
			body.append_string(line);
		}

		// Fill + pad right.
		color_whitespace(&body, &self.bg, has_bg, fill + self.pad_right);

		body.append_char('\n');
	}

	// Bottom padding lines.
	for (sz i = 0; i < self.pad_bottom; i++) {
		color_whitespace(&body, &self.bg, has_bg, line_width);
		body.append_char('\n');
	}

	// Height: add empty lines to reach target height, with vertical alignment.
	// height means total outer height (like Go glaze v2), so subtract border.
	sz border_v      = !border_is_empty ? 2 : 0;
	sz height_target = self.height - border_v;
	if (height_target < 0) height_target = 0;
	sz total_lines = (sz)line_count + self.pad_top + self.pad_bottom;
	if (height_target > 0 && total_lines < height_target) {
		sz extra        = height_target - total_lines;
		sz top_extra    = 0;
		sz bottom_extra = 0;
		if (self.align_v == Position.CENTER) {
			top_extra = extra / 2;
			bottom_extra = extra - top_extra;
		} else if (self.align_v == Position.BOTTOM) {
			top_extra = extra;
		} else {
			bottom_extra = extra;
		}

		for (sz i = 0; i < top_extra; i++) {
			color_whitespace(&out, &self.bg, has_bg, line_width);
			out.append_char('\n');
		}
		out.append_string(body.str_view());
		for (sz i = 0; i < bottom_extra; i++) {
			color_whitespace(&out, &self.bg, has_bg, line_width);
			out.append_char('\n');
		}
	} else {
		out.append_string(body.str_view());
	}

	// Remove trailing newline if needed, then apply border or copy.
	String rendered = out.str_view();
	if (rendered.len > 0 && rendered[rendered.len - 1] == '\n') {
		rendered = rendered[:rendered.len - 1];
	}

	// height is the block's total height, so content taller than it is clipped
	// rather than allowed to overflow. A block that grew past the size it was
	// given would paint over whatever the layout put below it — including its
	// own drop shadow.
	if (height_target > 0 && total_lines > height_target) {
		rendered = clip_lines(rendered, height_target);
	}

	if (!border_is_empty) {
		Color bbg = self.border_bg.kind != ColorKind.NONE ? self.border_bg : self.bg;
		String bordered = self.border.wrap_with_color(rendered, self.border_color, bbg, self.corner_color, self.border_gradient);
		// The gradient runs over the whole block, border rows included, so it
		// is applied after wrapping rather than to the content alone.
		return apply_bg_gradient(bordered, self.bg, self.bg_gradient);
	}
	return apply_bg_gradient(rendered.tcopy(), self.bg, self.bg_gradient);
}

// apply_bg_gradient rewrites a rendered block so each row's background is a
// step between `from` and `to`, interpolated in LUV — perceptually even, where
// a straight RGB lerp bunches the visible change at one end.
//
// It runs over the finished block because the row count is not settled until
// vertical alignment and the border have been applied, and a gradient needs to
// know how many rows it is spread across.
//
// Rows are found by splitting on newlines, which is safe for multi-byte
// content: no UTF-8 continuation byte can be 0x0a.
fn String apply_bg_gradient(String block, Color from, Color to) @local {
	if (to.kind != ColorKind.TRUECOLOR || from.kind != ColorKind.TRUECOLOR) return block;

	sz rows = 1;
	foreach (c : block) if (c == '\n') rows++;

	DString out = dstring::temp();
	sz row = 0;
	usz start = 0;
	for (usz i = 0; i <= block.len; i++) {
		if (i < block.len && block[i] != '\n') continue;

		if (row > 0) out.append_char('\n');
		// A one-row block has no span to interpolate over.
		double t = rows > 1 ? (double)row / (double)(rows - 1) : 0.0;
		Color bg = blend_luv(from, to, t);
		replace_bg(&out, block[start:i - start], bg);

		row++;
		start = i + 1;
	}
	return out.copy_str(tmem);
}

// replace_bg copies one row with `bg` as its background throughout: it opens
// with it so unstyled cells are covered, and reasserts it after every escape
// sequence — including ones that set a background of their own, whose color is
// the flat one this gradient replaces.
//
// Foreground and attributes in those sequences are left alone, so text keeps
// its own color over the gradient.
fn void replace_bg(DString* out, String row, Color bg) @local {
	out.append_string("\x1b[");
	bg.write_sgr_params(out, false);
	out.append_char('m');

	usz i = 0;
	while (i < row.len) {
		if (row[i] != '\x1b' || i + 1 >= row.len || row[i + 1] != '[') {
			out.append_char(row[i]);
			i++;
			continue;
		}
		usz esc = i;
		i += 2;
		while (i < row.len && row[i] != 'm' && !is_csi_final(row[i])) i++;
		if (i < row.len) i++;
		out.append_string(row[esc:i - esc]);

		out.append_string("\x1b[");
		bg.write_sgr_params(out, false);
		out.append_char('m');
	}
	out.append_string("\x1b[0m");
}

fn bool is_csi_final(char c) @local {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

// render_content_only renders the styled content WITHOUT the border.
// The caller's width/height should already account for border overhead.
// Used by animated border rendering to separate content from border.
fn String Style.render_content_only(self, String input) {
	// self is a copy, so clearing the border here leaves the caller's style
	// alone.
	Style s = self;
	s.border = { };
	s.border_color = { };
	s.corner_color = { };
	s.border_gradient = { };
	s.border_animation = BorderAnimation.NONE;
	return s.render(input);
}

