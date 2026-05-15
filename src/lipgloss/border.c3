module lipgloss;

import std::core::dstring;

struct Border {
    String top;
    String bottom;
    String left;
    String right;
    String top_left;
    String top_right;
    String bottom_left;
    String bottom_right;
}

fn Border no_border() {
    return {};
}

fn Border normal_border() {
    return { .top="-", .bottom="-", .left="|", .right="|",
             .top_left="+", .top_right="+", .bottom_left="+", .bottom_right="+" };
}

fn Border rounded_border() {
    return { .top="─", .bottom="─", .left="│", .right="│",
             .top_left="╭", .top_right="╮", .bottom_left="╰", .bottom_right="╯" };
}

// hidden_border occupies the same space as rounded_border but renders
// with spaces — content shifts are avoided when switching focus.
fn Border hidden_border() {
    return { .top=" ", .bottom=" ", .left=" ", .right=" ",
             .top_left=" ", .top_right=" ", .bottom_left=" ", .bottom_right=" " };
}

fn Border thick_border() {
    return { .top="━", .bottom="━", .left="┃", .right="┃",
             .top_left="┏", .top_right="┓", .bottom_left="┗", .bottom_right="┛" };
}

fn Border double_border() {
    return { .top="═", .bottom="═", .left="║", .right="║",
             .top_left="╔", .top_right="╗", .bottom_left="╚", .bottom_right="╝" };
}

// Wrap input lines (split by '\n') with this border.
// If border_fg is not NONE, border characters are wrapped in SGR.
fn String Border.wrap(self, String input) {
    return self.wrap_with_color(input, { .kind = ColorKind.NONE });
}

fn String Border.wrap_with_color(self, String input, Color border_fg) {
    bool is_empty = self.top.len == 0 && self.bottom.len == 0 &&
                    self.left.len == 0 && self.right.len == 0 &&
                    self.top_left.len == 0 && self.top_right.len == 0 &&
                    self.bottom_left.len == 0 && self.bottom_right.len == 0;
    if (is_empty) return input.tcopy();

    bool color_border = border_fg.kind != ColorKind.NONE;
    DString sgr_open = dstring::temp();
    String sgr_close = "\x1b[0m";
    if (color_border) {
        sgr_open.append_string("\x1b[");
        border_fg.write_sgr_params(&sgr_open, true);
        sgr_open.append_char('m');
    }
    String sgr_open_str = sgr_open.str_view();

    // Find max line width (visual).
    sz max_width = 0;
    sz line_start = 0;
    for (sz i = 0; i <= input.len; i++) {
        if (i == input.len || input[i] == '\n') {
            String line = input[line_start:i - line_start];
            sz w = (sz)string_width(line);
            if (w > max_width) max_width = w;
            line_start = i + 1;
            if (i == input.len) break;
        }
    }

    DString out = dstring::temp();

    // Top border row.
    if (color_border) out.append_string(sgr_open_str);
    out.append_string(self.top_left);
    for (sz i = 0; i < max_width; i++) out.append_string(self.top);
    out.append_string(self.top_right);
    if (color_border) out.append_string(sgr_close);
    out.append_char('\n');

    // Body lines.
    line_start = 0;
    for (sz i = 0; i <= input.len; i++) {
        if (i == input.len || input[i] == '\n') {
            String line = input[line_start:i - line_start];
            if (color_border) out.append_string(sgr_open_str);
            out.append_string(self.left);
            if (color_border) out.append_string(sgr_close);
            out.append_string(line);
            for (sz p = (sz)string_width(line); p < max_width; p++) out.append_char(' ');
            if (color_border) out.append_string(sgr_open_str);
            out.append_string(self.right);
            if (color_border) out.append_string(sgr_close);
            out.append_char('\n');
            line_start = i + 1;
            if (i == input.len) break;
        }
    }

    // Bottom border row.
    if (color_border) out.append_string(sgr_open_str);
    out.append_string(self.bottom_left);
    for (sz i = 0; i < max_width; i++) out.append_string(self.bottom);
    out.append_string(self.bottom_right);
    if (color_border) out.append_string(sgr_close);

    return out.copy_str(tmem);
}
