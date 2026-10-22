module dye;

import std::core::dstring;

// ============================================================
// Color — supports basic ANSI (16), 256-color palette, and
// truecolor (24-bit RGB).
// ============================================================

enum ColorKind : char {
	NONE,        // unset / default terminal color
	ANSI,        // basic 16 colors (0-15)
	ANSI256,     // xterm 256-color palette index
	TRUECOLOR,   // 24-bit RGB
	TRANSPARENT, // compositing: inherit from underlying layer
}

struct Color {
	ColorKind kind;
	char index; // ANSI (0-15) or ANSI256 (0-255) palette index
	char r; // truecolor red
	char g; // truecolor green
	char b; // truecolor blue
	char a; // alpha: 0 = opaque (default, backwards compat), 1-254 = blended, 255 = opaque
}

// Constructors

fn Color color_none() {
	return { .kind = ColorKind.NONE };
}

fn Color color_transparent() {
	return { .kind = ColorKind.TRANSPARENT };
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

fn Color color_rgba(char r, char g, char b, char a) {
	return { .kind = ColorKind.TRUECOLOR, .r = r, .g = g, .b = b, .a = a };
}

// effective_alpha returns the real alpha value (0 means opaque for backwards compat).
fn char Color.effective_alpha(&self) {
	return self.a == 0 ? (char)255 : self.a;
}

// blend_over returns this color alpha-blended over dst.
// Blending needs a known destination color. When dst is not truecolor the
// background behind it is unknown, so this color is returned at full strength
// instead of being darkened against an assumed black.
fn Color Color.blend_over(&self, Color dst) {
	if (self.kind != ColorKind.TRUECOLOR) return *self;
	if (dst.kind != ColorKind.TRUECOLOR) return color_rgb(self.r, self.g, self.b);
	int a = (int)self.effective_alpha();
	int inv_a = 255 - a;
	return color_rgb(
		(char)(((int)self.r * a + (int)dst.r * inv_a) / 255),
		(char)(((int)self.g * a + (int)dst.g * inv_a) / 255),
		(char)(((int)self.b * a + (int)dst.b * inv_a) / 255)
	);
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
		case ColorKind.NONE:
		case ColorKind.TRANSPARENT:
			return true;
		case ColorKind.ANSI:
		case ColorKind.ANSI256:
			return self.index == other.index;
		case ColorKind.TRUECOLOR:
			return self.r == other.r && self.g == other.g && self.b == other.b
				&& self.effective_alpha() == other.effective_alpha();
		default: return true;
	}
}

// SGR emission — foreground

fn String Color.to_sgr_fg(&self) {
	return self.to_sgr(false);
}

// SGR emission — background

fn String Color.to_sgr_bg(&self) {
	return self.to_sgr(true);
}

// to_sgr_underline emits the sequence that sets the underline colour. That
// slot takes the extended forms only, so a basic ANSI colour is written as its
// palette index.
fn String Color.to_sgr_underline(&self) {
	switch (self.kind) {
		case ColorKind.ANSI:
		case ColorKind.ANSI256:
			return string::tformat("\x1b[58;5;%dm", (int)self.index);
		case ColorKind.TRUECOLOR:
			return string::tformat("\x1b[58;2;%d;%d;%dm", (int)self.r, (int)self.g, (int)self.b);
		default:
			return "";
	}
}

// to_sgr emits the escape sequence that selects this color. background picks
// the background variant of each code.
fn String Color.to_sgr(&self, bool background) {
	switch (self.kind) {
		case ColorKind.NONE:
			return "";
		case ColorKind.ANSI: {
			if (self.index < 8) {
				return string::tformat("\x1b[%dm", (background ? 40 : 30) + (int)self.index);
			}
			return string::tformat("\x1b[%dm", (background ? 100 : 90) + (int)(self.index - 8));
		}
		case ColorKind.ANSI256:
			return string::tformat("\x1b[%d;5;%dm", background ? 48 : 38, (int)self.index);
		case ColorKind.TRUECOLOR:
			return string::tformat("\x1b[%d;2;%d;%d;%dm", background ? 48 : 38, (int)self.r, (int)self.g, (int)self.b);
		default:
			return "";
	}
}

// ============================================================
// PALETTE_256 — standard xterm 256-color palette as RGB values.
// ============================================================

// The 16 base colors, as r,g,b triples.
const char[48] ANSI_16_RGB = {
	0, 0, 0,       128, 0, 0,     0, 128, 0,     128, 128, 0,
	0, 0, 128,     128, 0, 128,   0, 128, 128,   192, 192, 192,
	128, 128, 128, 255, 0, 0,     0, 255, 0,     255, 255, 0,
	0, 0, 255,     255, 0, 255,   0, 255, 255,   255, 255, 255,
};

// The 6 levels of the 6x6x6 color cube.
const char[6] CUBE_LEVELS = { 0, 95, 135, 175, 215, 255 };

// palette_256 returns the xterm 256-color palette entry for idx.
// The palette is computed on demand, so it is always complete and safe to
// read from more than one thread.
fn Color palette_256(char idx) {
	int i = (int)idx;
	if (i < 16) {
		return color_rgb(ANSI_16_RGB[i * 3], ANSI_16_RGB[i * 3 + 1], ANSI_16_RGB[i * 3 + 2]);
	}
	if (i < 232) {
		int n  = i - 16;
		int ri = n / 36;
		int gi = (n % 36) / 6;
		int bi = n % 6;
		return color_rgb(CUBE_LEVELS[ri], CUBE_LEVELS[gi], CUBE_LEVELS[bi]);
	}
	char v = (char)(8 + (i - 232) * 10);
	return color_rgb(v, v, v);
}

// downsample_truecolor_to_256 maps an RGB value to the nearest
// index in the 256-color palette using squared Euclidean distance.
fn char downsample_truecolor_to_256(char r, char g, char b) {
	char best     = 16;
	int best_dist = 0x7fffffff;
	for (int i = 16; i < 256; i++) {
		Color c  = palette_256((char)i);
		int dr   = (int)r - (int)c.r;
		int dg   = (int)g - (int)c.g;
		int db   = (int)b - (int)c.b;
		int dist = dr * dr + dg * dg + db * db;
		if (dist < best_dist) {
			best_dist = dist;
			best = (char)i;
		}
	}
	return best;
}

// downsample_256_to_ansi maps a 256-color index to the nearest
// basic ANSI color (0-15).
fn char downsample_256_to_ansi(char idx) {
	if (idx < 16) return idx;
	Color c = palette_256(idx);
	return downsample_truecolor_to_ansi(c.r, c.g, c.b);
}

fn char downsample_truecolor_to_ansi(char r, char g, char b) {
	char best     = 0;
	int best_dist = 0x7fffffff;
	for (char i = 0; i < 16; i++) {
		Color c  = palette_256(i);
		int dr   = (int)r - (int)c.r;
		int dg   = (int)g - (int)c.g;
		int db   = (int)b - (int)c.b;
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