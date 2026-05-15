module xray;

import std::core::dstring;

// ============================================================
// Color — supports basic ANSI (16), 256-color palette, and
// truecolor (24-bit RGB).
// ============================================================

enum ColorKind : char {
	NONE,      // unset / default terminal color
	ANSI,      // basic 16 colors (0-15)
	ANSI256,   // xterm 256-color palette index
	TRUECOLOR, // 24-bit RGB
}

struct Color {
	ColorKind kind;
	char index;     // ANSI (0-15) or ANSI256 (0-255) palette index
	char r;         // truecolor red
	char g;         // truecolor green
	char b;         // truecolor blue
}

// Constructors

fn Color color_none() {
	return { .kind = ColorKind.NONE };
}

fn Color color_ansi(char code) {
	return { .kind = ColorKind.ANSI, .index = code };
}

fn Color color_256(char idx) {
	return { .kind = ColorKind.ANSI256, .index = idx };
}

fn Color color_rgb(char r, char g, char b) {
	return { .kind = ColorKind.TRUECOLOR, .r = r, .g = g, .b = b };
}

fn Color color_hex(String hex) {
	String h = hex;
	if (h.len > 0 && h[0] == '#') h = h[1..];
	if (h.len < 6) return color_none();

	char r = (hex_nibble(h[0]) << 4) | hex_nibble(h[1]);
	char g = (hex_nibble(h[2]) << 4) | hex_nibble(h[3]);
	char b = (hex_nibble(h[4]) << 4) | hex_nibble(h[5]);
	return color_rgb(r, g, b);
}

fn char hex_nibble(char c) @local {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return 0;
}

// Queries

fn bool Color.is_none(&self) {
	return self.kind == ColorKind.NONE;
}

fn bool Color.eq(&self, Color other) {
	if (self.kind != other.kind) return false;
	switch (self.kind) {
		case ColorKind.NONE: return true;
		case ColorKind.ANSI:
		case ColorKind.ANSI256:
			return self.index == other.index;
		case ColorKind.TRUECOLOR:
			return self.r == other.r && self.g == other.g && self.b == other.b;
		default: return true;
	}
}

// SGR emission — foreground

fn String Color.to_sgr_fg(&self) {
	switch (self.kind) {
		case ColorKind.NONE:
			return "";
		case ColorKind.ANSI:
			if (self.index < 8) {
				return string::tformat("\x1b[%dm", 30 + self.index);
			}
			return string::tformat("\x1b[%dm", 90 + (self.index - 8));
		case ColorKind.ANSI256:
			return string::tformat("\x1b[38;5;%dm", self.index);
		case ColorKind.TRUECOLOR:
			return string::tformat("\x1b[38;2;%d;%d;%dm", self.r, self.g, self.b);
		default:
			return "";
	}
}

// SGR emission — background

fn String Color.to_sgr_bg(&self) {
	switch (self.kind) {
		case ColorKind.NONE:
			return "";
		case ColorKind.ANSI:
			if (self.index < 8) {
				return string::tformat("\x1b[%dm", 40 + self.index);
			}
			return string::tformat("\x1b[%dm", 100 + (self.index - 8));
		case ColorKind.ANSI256:
			return string::tformat("\x1b[48;5;%dm", self.index);
		case ColorKind.TRUECOLOR:
			return string::tformat("\x1b[48;2;%d;%d;%dm", self.r, self.g, self.b);
		default:
			return "";
	}
}

// ============================================================
// PALETTE_256 — standard xterm 256-color palette as RGB values.
// ============================================================

Color[256] g_palette_256;
bool g_palette_initialized = false;

fn void init_palette() @local {
	if (g_palette_initialized) return;
	g_palette_initialized = true;

	// 0-7: Standard ANSI colors
	g_palette_256[0]  = color_rgb(0, 0, 0);
	g_palette_256[1]  = color_rgb(128, 0, 0);
	g_palette_256[2]  = color_rgb(0, 128, 0);
	g_palette_256[3]  = color_rgb(128, 128, 0);
	g_palette_256[4]  = color_rgb(0, 0, 128);
	g_palette_256[5]  = color_rgb(128, 0, 128);
	g_palette_256[6]  = color_rgb(0, 128, 128);
	g_palette_256[7]  = color_rgb(192, 192, 192);

	// 8-15: Bright ANSI colors
	g_palette_256[8]  = color_rgb(128, 128, 128);
	g_palette_256[9]  = color_rgb(255, 0, 0);
	g_palette_256[10] = color_rgb(0, 255, 0);
	g_palette_256[11] = color_rgb(255, 255, 0);
	g_palette_256[12] = color_rgb(0, 0, 255);
	g_palette_256[13] = color_rgb(255, 0, 255);
	g_palette_256[14] = color_rgb(0, 255, 255);
	g_palette_256[15] = color_rgb(255, 255, 255);

	// 16-231: 6x6x6 color cube
	char[6] cube_vals = { 0, 95, 135, 175, 215, 255 };
	for (char ri = 0; ri < 6; ri++) {
		for (char gi = 0; gi < 6; gi++) {
			for (char bi = 0; bi < 6; bi++) {
				g_palette_256[16 + ri * 36 + gi * 6 + bi] = color_rgb(cube_vals[ri], cube_vals[gi], cube_vals[bi]);
			}
		}
	}

	// 232-255: Grayscale ramp (8 to 238 in steps of 10)
	for (char i = 0; i < 24; i++) {
		char v = 8 + i * 10;
		g_palette_256[232 + i] = color_rgb(v, v, v);
	}
}

fn Color palette_256(char idx) {
	init_palette();
	return g_palette_256[idx];
}

// downsample_truecolor_to_256 maps an RGB value to the nearest
// index in the 256-color palette using squared Euclidean distance.
fn char downsample_truecolor_to_256(char r, char g, char b) {
	init_palette();
	char best = 16;
	int best_dist = 0x7fffffff;
	for (char i = 16; i < 232; i++) {
		Color c = g_palette_256[i];
		int dr = (int)r - (int)c.r;
		int dg = (int)g - (int)c.g;
		int db = (int)b - (int)c.b;
		int dist = dr * dr + dg * dg + db * db;
		if (dist < best_dist) {
			best_dist = dist;
			best = i;
		}
	}
	for (char i = 232; i < 255; i++) {
		Color c = g_palette_256[i];
		int dr = (int)r - (int)c.r;
		int dg = (int)g - (int)c.g;
		int db = (int)b - (int)c.b;
		int dist = dr * dr + dg * dg + db * db;
		if (dist < best_dist) {
			best_dist = dist;
			best = i;
		}
	}
	return best;
}

// downsample_256_to_ansi maps a 256-color index to the nearest
// basic ANSI color (0-15).
fn char downsample_256_to_ansi(char idx) {
	if (idx < 16) return idx;
	init_palette();
	Color c = g_palette_256[idx];
	return downsample_truecolor_to_ansi(c.r, c.g, c.b);
}

fn char downsample_truecolor_to_ansi(char r, char g, char b) {
	init_palette();
	char best = 0;
	int best_dist = 0x7fffffff;
	for (char i = 0; i < 16; i++) {
		Color c = g_palette_256[i];
		int dr = (int)r - (int)c.r;
		int dg = (int)g - (int)c.g;
		int db = (int)b - (int)c.b;
		int dist = dr * dr + dg * dg + db * db;
		if (dist < best_dist) {
			best_dist = dist;
			best = i;
		}
	}
	return best;
}

// ColorProfile controls how colors are downsampled when emitting SGR.
enum ColorProfile : char {
	ASCII,     // no color
	ANSI,      // basic 16 colors only
	ANSI256,   // 256-color palette
	TRUECOLOR, // full 24-bit RGB
}

// Color.to_sgr_fg_profile emits SGR foreground respecting the profile.
fn String Color.to_sgr_fg_profile(&self, ColorProfile profile) {
	Color c = *self;
	if (profile == ColorProfile.ANSI && c.kind == ColorKind.TRUECOLOR) {
		c = color_ansi(downsample_truecolor_to_ansi(c.r, c.g, c.b));
	} else if (profile == ColorProfile.ANSI && c.kind == ColorKind.ANSI256) {
		c = color_ansi(downsample_256_to_ansi(c.index));
	} else if (profile == ColorProfile.ANSI256 && c.kind == ColorKind.TRUECOLOR) {
		c = color_256(downsample_truecolor_to_256(c.r, c.g, c.b));
	} else if (profile == ColorProfile.ASCII) {
		return "";
	}
	return c.to_sgr_fg();
}

// Color.to_sgr_bg_profile emits SGR background respecting the profile.
fn String Color.to_sgr_bg_profile(&self, ColorProfile profile) {
	Color c = *self;
	if (profile == ColorProfile.ANSI && c.kind == ColorKind.TRUECOLOR) {
		c = color_ansi(downsample_truecolor_to_ansi(c.r, c.g, c.b));
	} else if (profile == ColorProfile.ANSI && c.kind == ColorKind.ANSI256) {
		c = color_ansi(downsample_256_to_ansi(c.index));
	} else if (profile == ColorProfile.ANSI256 && c.kind == ColorKind.TRUECOLOR) {
		c = color_256(downsample_truecolor_to_256(c.r, c.g, c.b));
	} else if (profile == ColorProfile.ASCII) {
		return "";
	}
	return c.to_sgr_bg();
}
