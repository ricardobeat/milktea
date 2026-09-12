// palette.c3 resolves xray's ANSI and ANSI256 palette indices to RGB so a
// GUI build renders 16- and 256-color styles the same way a terminal would.
// Truecolor styles bypass this entirely — they already carry their RGB.
module milktea_gui;

struct Rgb {
	char r;
	char g;
	char b;
}

// The 16 ANSI colors, in xterm's default palette. A real terminal lets the
// user retheme these; a GUI window has no such config to read, so xterm's
// defaults stand in as the one palette every terminal agrees to approximate.
const Rgb[16] ANSI16 = {
	{   0,   0,   0 }, // 0 black
	{ 205,   0,   0 }, // 1 red
	{   0, 205,   0 }, // 2 green
	{ 205, 205,   0 }, // 3 yellow
	{   0,   0, 238 }, // 4 blue
	{ 205,   0, 205 }, // 5 magenta
	{   0, 205, 205 }, // 6 cyan
	{ 229, 229, 229 }, // 7 white
	{ 127, 127, 127 }, // 8 bright black
	{ 255,   0,   0 }, // 9 bright red
	{   0, 255,   0 }, // 10 bright green
	{ 255, 255,   0 }, // 11 bright yellow
	{  92,  92, 255 }, // 12 bright blue
	{ 255,   0, 255 }, // 13 bright magenta
	{   0, 255, 255 }, // 14 bright cyan
	{ 255, 255, 255 }, // 15 bright white
};

// The 6 levels each RGB channel takes in the 6x6x6 color cube (indices
// 16-231). Note the jump from 0 to 95 — the cube is deliberately not linear.
const char[6] CUBE_LEVELS = { 0, 95, 135, 175, 215, 255 };

// ansi256_rgb maps a 256-color palette index to RGB following xterm's
// layout: 0-15 are the ANSI colors above, 16-231 a 6x6x6 RGB cube, and
// 232-255 a 24-step grayscale ramp.
fn Rgb ansi256_rgb(char idx) {
	if (idx < 16) return ANSI16[idx];
	if (idx < 232) {
		int c = (int)idx - 16;
		return {
			CUBE_LEVELS[c / 36],
			CUBE_LEVELS[(c / 6) % 6],
			CUBE_LEVELS[c % 6],
		};
	}
	// Grayscale ramp: 8, 18, 28 ... 238 — neither pure black nor pure white,
	// both of which the cube and ANSI16 already provide.
	char v = (char)(8 + ((int)idx - 232) * 10);
	return { v, v, v };
}
