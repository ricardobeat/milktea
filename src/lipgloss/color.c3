module lipgloss;

import std::core::dstring;

faultdef BAD_HEX;

enum ColorKind : char {
    NONE,
    ANSI,
    TRUECOLOR,
}

struct Color {
    ColorKind kind;
    char ansi;
    char r;
    char g;
    char b;
}

fn Color color_none() {
    return { .kind = ColorKind.NONE };
}

fn Color color_ansi(int idx) {
    char clamped = (char)(idx < 0 ? 0 : (idx > 15 ? 15 : idx));
    return { .kind = ColorKind.ANSI, .ansi = clamped };
}

fn char? hex_digit(char c) {
    if (c >= '0' && c <= '9') return (char)(c - '0');
    if (c >= 'a' && c <= 'f') return (char)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (char)(c - 'A' + 10);
    return BAD_HEX~;
}

fn char? hex_pair(char hi, char lo) {
    char hi_val = hex_digit(hi)!;
    char lo_val = hex_digit(lo)!;
    return (char)((hi_val << 4) | lo_val);
}

fn Color color_hex(String hex) {
    String input = hex;
    if (input.len > 0 && input[0] == '#') {
        input = input[1..];
    }
    if (input.len != 6) return color_none();

    char? r_val = hex_pair(input[0], input[1]);
    char? g_val = hex_pair(input[2], input[3]);
    char? b_val = hex_pair(input[4], input[5]);

    if (catch r_val) return color_none();
    if (catch g_val) return color_none();
    if (catch b_val) return color_none();

    return {
        .kind = ColorKind.TRUECOLOR,
        .r = r_val,
        .g = g_val,
        .b = b_val,
    };
}

fn void Color.write_sgr_params(self, DString* out, bool foreground) {
    switch (self.kind) {
        case NONE:
        case ANSI:
            if (self.ansi < 8) {
                out.appendf(foreground ? "3%d" : "4%d", self.ansi);
            } else {
                out.appendf(foreground ? "9%d" : "10%d", self.ansi - 8);
            }
        case TRUECOLOR:
            out.appendf(foreground ? "38;2;%d;%d;%d" : "48;2;%d;%d;%d",
                        self.r, self.g, self.b);
    }
}
