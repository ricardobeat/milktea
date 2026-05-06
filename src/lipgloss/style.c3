module lipgloss;

import std::core::dstring;

fn int string_width(String s) {
    int w = 0;
    bool in_ansi = false;
    usz i = 0;
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
        char b = s[i];
        if ((b & 0x80) == 0) {
            cp = (uint)b;
            i++;
        } else if ((b & 0xe0) == 0xc0) {
            cp = (uint)(b & 0x1f);
            i++;
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
        } else if ((b & 0xf0) == 0xe0) {
            cp = (uint)(b & 0x0f);
            i++;
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
        } else if ((b & 0xf8) == 0xf0) {
            cp = (uint)(b & 0x07);
            i++;
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
            if (i < s.len) { cp = (cp << 6) | (uint)(s[i] & 0x3f); i++; }
        } else {
            i++;
            continue;
        }

        // Wide characters (CJK, emoji, box drawing, etc.)
        if (cp >= 0x1100) {
            // CJK Unified Ideographs
            if (cp >= 0x4e00 && cp <= 0x9fff) { w += 2; continue; }
            // CJK Extension A
            if (cp >= 0x3400 && cp <= 0x4dbf) { w += 2; continue; }
            // Hangul
            if (cp >= 0xac00 && cp <= 0xd7a3) { w += 2; continue; }
            // Fullwidth Latin
            if (cp >= 0xff01 && cp <= 0xff60) { w += 2; continue; }
            // CJK Compatibility
            if (cp >= 0xf900 && cp <= 0xfaff) { w += 2; continue; }
            // Enclosed CJK
            if (cp >= 0x3000 && cp <= 0x303f) { w += 2; continue; }
            // Box drawing and block elements are narrow (width 1)
            if (cp >= 0x2500 && cp <= 0x257f) { w += 1; continue; }
            if (cp >= 0x2580 && cp <= 0x259f) { w += 1; continue; }
            // Braille
            if (cp >= 0x2800 && cp <= 0x28ff) { w += 1; continue; }
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
    bool bold;
    bool italic;
    bool underline;
    int pad_top;
    int pad_right;
    int pad_bottom;
    int pad_left;
    int width;        // 0 = auto (don't pad)
    Border border;    // zero value = no border
}

fn Style new_style() {
    return {};
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

fn String Style.render(self, String input) {
    DString out = dstring::temp();

    // Split input into lines.
    String[256] lines;
    usz line_count = 0;
    usz line_start = 0;
    for (usz i = 0; i <= input.len; i++) {
        if (i == input.len || input[i] == '\n') {
            lines[line_count] = input[line_start:i - line_start];
            line_count++;
            line_start = i + 1;
            if (i == input.len) break;
        }
    }

    // Determine target width.
    int target_width = self.width;
    if (target_width <= 0) {
        target_width = 0;
        for (usz i = 0; i < line_count; i++) {
            int line_width = string_width(lines[i]) + self.pad_left + self.pad_right;
            if (line_width > target_width) target_width = line_width;
        }
    }

    bool has_attrs = self.fg.kind != ColorKind.NONE || self.bg.kind != ColorKind.NONE ||
                     self.bold || self.italic || self.underline;

    // Top padding lines.
    for (int i = 0; i < self.pad_top; i++) {
        for (int j = 0; j < target_width; j++) out.append_char(' ');
        if (has_attrs) {
            out.append_string("\x1b[0m");
        }
        out.append_char('\n');
    }

    // Content lines.
    for (usz i = 0; i < line_count; i++) {
        String line = lines[i];

        // Build styled line: pad_left + line + pad to width + pad_right.
        DString styled = dstring::temp();
        for (int j = 0; j < self.pad_left; j++) styled.append_char(' ');
        styled.append_string(line);
        int current_len = string_width(line) + self.pad_left;
        for (int j = current_len; j < target_width; j++) styled.append_char(' ');
        for (int j = 0; j < self.pad_right; j++) styled.append_char(' ');

        String styled_str = styled.str_view();

        // Wrap with SGR if needed.
        if (has_attrs) {
            out.append_string("\x1b[");
            bool first = true;
            if (self.bold) {
                out.append_string("1");
                first = false;
            }
            if (self.italic) {
                if (!first) out.append_char(';');
                out.append_string("3");
                first = false;
            }
            if (self.underline) {
                if (!first) out.append_char(';');
                out.append_string("4");
                first = false;
            }
            if (self.fg.kind != ColorKind.NONE) {
                if (!first) out.append_char(';');
                self.fg.write_sgr_params(&out, true);
                first = false;
            }
            if (self.bg.kind != ColorKind.NONE) {
                if (!first) out.append_char(';');
                self.bg.write_sgr_params(&out, false);
            }
            out.append_string("m");
            out.append_string(styled_str);
            out.append_string("\x1b[0m");
        } else {
            out.append_string(styled_str);
        }

        out.append_char('\n');
    }

    // Bottom padding lines.
    for (int i = 0; i < self.pad_bottom; i++) {
        for (int j = 0; j < target_width; j++) out.append_char(' ');
        if (has_attrs) {
            out.append_string("\x1b[0m");
        }
        out.append_char('\n');
    }

    // Remove trailing newline if needed, then apply border or copy.
    String rendered = out.str_view();
    if (rendered.len > 0 && rendered[rendered.len - 1] == '\n') {
        rendered = rendered[:rendered.len - 1];
    }

    // Check if border is empty.
    bool border_is_empty = self.border.top.len == 0 && self.border.bottom.len == 0 &&
                           self.border.left.len == 0 && self.border.right.len == 0 &&
                           self.border.top_left.len == 0 && self.border.top_right.len == 0 &&
                           self.border.bottom_left.len == 0 && self.border.bottom_right.len == 0;

    if (!border_is_empty) {
        return self.border.wrap(rendered);
    }
    return rendered.tcopy();
}
