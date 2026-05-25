module lipgloss;

import std::core::dstring;

// BorderAnimation selects an animated border rendering mode.
enum BorderAnimation : char {
	NONE,    // static border (default)
	PULSE,   // pulses the base color in brightness
	RAINBOW, // rainbow colors spin around the perimeter
	RACE,    // a dash of bright color races around, leaving a dim trail
}

fn int string_width(String s) {
	int w        = 0;
	bool in_ansi = false;
	sz i         = 0;
	while (i < s.len) {
		if (s[i] == '\x1b') {
			in_ansi = true;
			i++;
			continue;
		}
		if (in_ansi) {
			if ((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z')) {
				in_ansi = false;
			}
			i++;
			continue;
		}

		// Decode UTF-8 codepoint
		uint cp = 0;
		char b  = s[i];
		if ((b & 0x80) == 0) {
			cp = (uint)b;
			i++;
		} else if ((b & 0xe0) == 0xc0) {
			cp = (uint)(b & 0x1f);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else if ((b & 0xf0) == 0xe0) {
			cp = (uint)(b & 0x0f);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else if ((b & 0xf8) == 0xf0) {
			cp = (uint)(b & 0x07);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else {
			i++;
			continue;
		}

		// Wide characters (CJK, emoji, box drawing, etc.)
		if (cp >= 0x1100) {
			// CJK Unified Ideographs
			if (cp >= 0x4e00 && cp <= 0x9fff) {
				w += 2;
				continue;
			}
			// CJK Extension A
			if (cp >= 0x3400 && cp <= 0x4dbf) {
				w += 2;
				continue;
			}
			// Hangul
			if (cp >= 0xac00 && cp <= 0xd7a3) {
				w += 2;
				continue;
			}
			// Fullwidth Latin
			if (cp >= 0xff01 && cp <= 0xff60) {
				w += 2;
				continue;
			}
			// CJK Compatibility
			if (cp >= 0xf900 && cp <= 0xfaff) {
				w += 2;
				continue;
			}
			// Enclosed CJK
			if (cp >= 0x3000 && cp <= 0x303f) {
				w += 2;
				continue;
			}
			// Narrow symbols (width 1 in most terminals)
			if (cp >= 0x2100 && cp <= 0x21ff) {
				w += 1;
				continue;
			} // Letterlike, Number Forms, Arrows
			if (cp >= 0x2200 && cp <= 0x22ff) {
				w += 1;
				continue;
			} // Mathematical Operators
			if (cp >= 0x2300 && cp <= 0x23ff) {
				w += 1;
				continue;
			} // Miscellaneous Technical
			if (cp >= 0x25a0 && cp <= 0x25ff) {
				w += 1;
				continue;
			} // Geometric Shapes
			// Box drawing and block elements are narrow (width 1)
			if (cp >= 0x2500 && cp <= 0x257f) {
				w += 1;
				continue;
			}
			if (cp >= 0x2580 && cp <= 0x259f) {
				w += 1;
				continue;
			}
			// Braille
			if (cp >= 0x2800 && cp <= 0x28ff) {
				w += 1;
				continue;
			}
			// Emoji and symbols — all width 2
			w += 2;
			continue;
		}
		w++;
	}
	return w;
}

struct Style {
	Color fg;
	Color bg;
	Color border_fg;
	bool bold;
	bool italic;
	bool underline;
	int pad_top;
	int pad_right;
	int pad_bottom;
	int pad_left;
	int width; // 0 = auto (don't pad)
	int height; // 0 = auto
	Position h_align; // horizontal alignment within width
	Position v_align; // vertical alignment within height
	Border border; // zero value = no border
	BorderAnimation border_anim; // NONE = static
	int border_anim_speed; // ms per full cycle (default 1000)
}

fn Style new_style() {
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

fn Style Style.set_bold(self, bool v) {
	Style s = self;
	s.bold = v;
	return s;
}

fn Style Style.set_italic(self, bool v) {
	Style s = self;
	s.italic = v;
	return s;
}

fn Style Style.set_underline(self, bool v) {
	Style s = self;
	s.underline = v;
	return s;
}

fn Style Style.padding(self, int top, int right, int bottom, int left) {
	Style s = self;
	s.pad_top = top;
	s.pad_right = right;
	s.pad_bottom = bottom;
	s.pad_left = left;
	return s;
}

fn Style Style.set_width(self, int w) {
	Style s = self;
	s.width = w;
	return s;
}

fn Style Style.set_border(self, Border b) {
	Style s = self;
	s.border = b;
	return s;
}

fn Style Style.set_border_fg(self, Color c) {
	Style s = self;
	s.border_fg = c;
	return s;
}

fn Style Style.set_border_anim(self, BorderAnimation anim) {
	Style s = self;
	s.border_anim = anim;
	if (s.border_anim_speed == 0) s.border_anim_speed = 1000;
	return s;
}

fn Style Style.set_border_anim_speed(self, int ms) {
	Style s = self;
	s.border_anim_speed = ms;
	return s;
}

fn Style Style.set_height(self, int h) {
	Style s = self;
	s.height = h;
	return s;
}

fn Style Style.align(self, Position h, Position v) {
	Style s = self;
	s.h_align = h;
	s.v_align = v;
	return s;
}

fn Style Style.align_horizontal(self, Position h) {
	Style s = self;
	s.h_align = h;
	return s;
}

fn Style Style.align_vertical(self, Position v) {
	Style s = self;
	s.v_align = v;
	return s;
}

// Shorthand methods — shorter names for common operations.
// These coexist with the longer names for backwards compatibility.

fn Style Style.with_fg(self, String hex) {
	return self.foreground(color_hex(hex));
}

fn Style Style.with_bg(self, String hex) {
	return self.background(color_hex(hex));
}

fn Style Style.with_bold(self, bool v) {
	return self.set_bold(v);
}

fn Style Style.with_italic(self, bool v) {
	return self.set_italic(v);
}

fn Style Style.with_underline(self, bool v) {
	return self.set_underline(v);
}

fn Style Style.with_border(self, Border b) {
	return self.set_border(b);
}

fn Style Style.with_border_anim(self, BorderAnimation anim) {
	return self.set_border_anim(anim);
}

fn Style Style.with_border_anim_speed(self, int ms) {
	return self.set_border_anim_speed(ms);
}

fn Style Style.with_width(self, int width) {
	return self.set_width(width);
}

// measure_height renders content at the given outer width and counts the output lines.
// Useful for auto-sizing a box before committing it to a layout rect.
fn int Style.measure_height(self, String input, int outer_width) {
	// set_width means total outer width (border+pad+content); render() subtracts border internally.
	Style sized     = self.set_width(outer_width);
	String rendered = sized.render(input);
	int lines       = 1;
	for (sz i = 0; i < rendered.len; i++) {
		if (rendered[i] == '\n') lines++;
	}
	return lines;
}

fn String Style.render(self, String input) {
	DString out = dstring::temp();

	// Split input into lines.
	String[256] lines;
	sz line_count = 0;
	sz line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			lines[line_count] = input[line_start:i - line_start];
			line_count++;
			line_start = i + 1;
			if (i == input.len) break;
		}
	}

	// Determine target width.
	// In Go lipgloss, Width(N) means total output = N (border + padding included).
	// So we subtract border and padding from the requested width to get the
	// content area width.
	int border_h = 0;
	bool border_is_empty = self.border.top.len == 0 && self.border.bottom.len == 0 && self.border.left.len == 0
		&& self.border.right.len == 0
		&& self.border.top_left.len == 0
		&& self.border.top_right.len == 0
		&& self.border.bottom_left.len == 0
		&& self.border.bottom_right.len == 0;
	if (!border_is_empty) {
		border_h = 2; // left + right border chars
	}

	int target_width = self.width;
	if (target_width > 0) {
		// Subtract border and padding to get content area
		target_width = target_width - border_h - self.pad_left - self.pad_right;
		if (target_width < 1) target_width = 1;
	} else {
		// Auto-size to widest line
		target_width = 0;
		for (sz i = 0; i < line_count; i++) {
			int line_width = string_width(lines[i]);
			if (line_width > target_width) target_width = line_width;
		}
	}

	bool has_attrs = self.fg.kind != ColorKind.NONE || self.bg.kind != ColorKind.NONE || self.bold || self.italic
		|| self.underline;

	// Total line width = content + padding (border is applied after)
	int line_width = target_width + self.pad_left + self.pad_right;

	// Build content into a temp buffer first, then add height alignment.
	DString body = dstring::temp();

	// Top padding lines.
	for (int i = 0; i < self.pad_top; i++) {
		for (int j = 0; j < line_width; j++) body.append_char(' ');
		if (has_attrs) {
			body.append_string("\x1b[0m");
		}
		body.append_char('\n');
	}

	// Content lines.
	for (sz i = 0; i < line_count; i++) {
		String line = lines[i];

		// Build styled line: pad_left + content + reset + fill spaces + pad_right.
		DString styled = dstring::temp();
		for (int j = 0; j < self.pad_left; j++) styled.append_char(' ');
		styled.append_string(line);
		int current_len = string_width(line) + self.pad_left;
		int fill        = (target_width + self.pad_left) - current_len;
		if (fill > 0) {
			// Reset any styles opened inside `line` before writing fill spaces.
			styled.append_string("\x1b[0m");
			for (int j = 0; j < fill; j++) styled.append_char(' ');
		}
		for (int j = 0; j < self.pad_right; j++) styled.append_char(' ');

		String styled_str = styled.str_view();

		// Wrap with SGR if needed.
		if (has_attrs) {
			body.append_string("\x1b[");
			bool first = true;
			if (self.bold) {
				body.append_string("1");
				first = false;
			}
			if (self.italic) {
				if (!first) body.append_char(';');
				body.append_string("3");
				first = false;
			}
			if (self.underline) {
				if (!first) body.append_char(';');
				body.append_string("4");
				first = false;
			}
			if (self.fg.kind != ColorKind.NONE) {
				if (!first) body.append_char(';');
				self.fg.write_sgr_params(&body, true);
				first = false;
			}
			if (self.bg.kind != ColorKind.NONE) {
				if (!first) body.append_char(';');
				self.bg.write_sgr_params(&body, false);
			}
			body.append_string("m");
			body.append_string(styled_str);
			body.append_string("\x1b[0m");
		} else {
			body.append_string(styled_str);
		}

		body.append_char('\n');
	}

	// Bottom padding lines.
	for (int i = 0; i < self.pad_bottom; i++) {
		for (int j = 0; j < line_width; j++) body.append_char(' ');
		if (has_attrs) {
			body.append_string("\x1b[0m");
		}
		body.append_char('\n');
	}

	// Height: add empty lines to reach target height, with vertical alignment.
	// self.height means total outer height (like Go lipgloss v2), so subtract border.
	int border_v      = !border_is_empty ? 2 : 0;
	int height_target = self.height - border_v;
	if (height_target < 0) height_target = 0;
	int total_lines = (int)line_count + self.pad_top + self.pad_bottom;
	if (height_target > 0 && total_lines < height_target) {
		int extra        = height_target - total_lines;
		int top_extra    = 0;
		int bottom_extra = 0;
		if (self.v_align == Position.CENTER) {
			top_extra = extra / 2;
			bottom_extra = extra - top_extra;
		} else if (self.v_align == Position.BOTTOM) {
			top_extra = extra;
		} else {
			bottom_extra = extra;
		}

		// Write top extra, then body, then bottom extra
		for (int i = 0; i < top_extra; i++) {
			for (int j = 0; j < line_width; j++) out.append_char(' ');
			out.append_char('\n');
		}
		out.append_string(body.str_view());
		for (int i = 0; i < bottom_extra; i++) {
			for (int j = 0; j < line_width; j++) out.append_char(' ');
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

	if (!border_is_empty) {
		return self.border.wrap_with_color(rendered, self.border_fg);
	}
	return rendered.tcopy();
}

// render_content_only renders the styled content WITHOUT the border.
// The caller's width/height should already account for border overhead.
// Used by animated border rendering to separate content from border.
fn String Style.render_content_only(self, String input) {
	// Temporarily clear the border, render, then restore.
	Style saved = self;
	Style s     = self;
	s.border = { };
	s.border_fg = { };
	s.border_anim = BorderAnimation.NONE;
	String result = s.render(input);
	return result;
}