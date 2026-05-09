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

fn Border thick_border() {
    return { .top="━", .bottom="━", .left="┃", .right="┃",
             .top_left="┏", .top_right="┓", .bottom_left="┗", .bottom_right="┛" };
}

fn Border double_border() {
    return { .top="═", .bottom="═", .left="║", .right="║",
             .top_left="╔", .top_right="╗", .bottom_left="╚", .bottom_right="╝" };
}

// Wrap input lines (split by '\n') with this border.
fn String Border.wrap(self, String input) {
    bool is_empty = self.top.len == 0 && self.bottom.len == 0 &&
                    self.left.len == 0 && self.right.len == 0 &&
                    self.top_left.len == 0 && self.top_right.len == 0 &&
                    self.bottom_left.len == 0 && self.bottom_right.len == 0;
    if (is_empty) return input.tcopy();

    // Find max line width (visual).
    usz max_width = 0;
    usz line_start = 0;
    for (usz i = 0; i <= input.len; i++) {
        if (i == input.len || input[i] == '\n') {
            String line = input[line_start:i - line_start];
            usz w = (usz)string_width(line);
            if (w > max_width) max_width = w;
            line_start = i + 1;
            if (i == input.len) break;
        }
    }

    DString out = dstring::temp();

    // Top border row.
    out.append_string(self.top_left);
    for (usz i = 0; i < max_width; i++) out.append_string(self.top);
    out.append_string(self.top_right);
    out.append_char('\n');

    // Body lines.
    line_start = 0;
    for (usz i = 0; i <= input.len; i++) {
        if (i == input.len || input[i] == '\n') {
            String line = input[line_start:i - line_start];
            out.append_string(self.left);
            out.append_string(line);
            for (usz p = (usz)string_width(line); p < max_width; p++) out.append_char(' ');
            out.append_string(self.right);
            out.append_char('\n');
            line_start = i + 1;
            if (i == input.len) break;
        }
    }

    // Bottom border row.
    out.append_string(self.bottom_left);
    for (usz i = 0; i < max_width; i++) out.append_string(self.bottom);
    out.append_string(self.bottom_right);

    return out.copy_str(tmem);
}
