// The glyph atlas: one byte of coverage per pixel, filled the first time each
// glyph is drawn. Glyphs come from the platform's rasteriser (CoreText on
// macOS) at the window's device resolution, so they reach the screen 1:1.
//
// Rows are packed into shelves left to right. When the atlas fills it grows
// downward; packed glyphs keep their pixel position, and texture coordinates
// are worked out from the atlas's current size whenever a glyph is drawn.
module milktea_gui;

import std::collections::map;
import std::core::mem;
import std::io;

const int ATLAS_WIDTH = 1024;
const int ATLAS_MAX_HEIGHT = 8192;
// A block of solid coverage in the corner, where every flat rect samples.
const int WHITE_SIZE = 4;

struct Glyph {
	int x;
	int y;
	int w;
	int h;
	int off_x;
	int off_y;
	int advance;
	bool missing; // no installed font has it
}

// The faces a frame draws with: the text face, and the face box-drawing
// rules use when the cell is taller than the text (see Gui.rule_split).
enum Face : char {
	TEXT,
	RULE,
}

struct Atlas {
	char[] pixels;
	int w;
	int h;
	int shelf_x;
	int shelf_y;
	int shelf_h;
	bool dirty;
	HashMap{ulong, Glyph} glyphs;
	void*[2] faces;
	char[] scratch;
}

Atlas g_atlas @private;

fn void atlas_reset() @private {
	if (g_atlas.pixels.ptr) mem::free(g_atlas.pixels);
	g_atlas.w = ATLAS_WIDTH;
	g_atlas.h = 512;
	g_atlas.pixels = mem::new_array(char, (sz)g_atlas.w * g_atlas.h);
	for (int y = 0; y < WHITE_SIZE; y++) {
		for (int x = 0; x < WHITE_SIZE; x++) g_atlas.pixels[(sz)y * g_atlas.w + x] = 255;
	}
	g_atlas.shelf_x = WHITE_SIZE + 2;
	g_atlas.shelf_y = 0;
	g_atlas.shelf_h = WHITE_SIZE;
	if (!g_atlas.glyphs.is_initialized()) g_atlas.glyphs.init(mem);
	g_atlas.glyphs.clear();
	g_atlas.dirty = true;
}

// atlas_set_faces swaps the fonts in. Every glyph cached so far belongs to
// the old ones, so the atlas starts again.
fn void atlas_set_faces(void* text, void* rule) @private {
	void* a = g_atlas.faces[0];
	void* b = g_atlas.faces[1];
	if (a != null && a != text && a != rule) mt_font_close(a);
	if (b != null && b != a && b != text && b != rule) mt_font_close(b);
	g_atlas.faces[0] = text;
	g_atlas.faces[1] = rule;
	atlas_reset();
}

fn void atlas_free() @private {
	void* a = g_atlas.faces[0];
	void* b = g_atlas.faces[1];
	if (a != null) mt_font_close(a);
	if (b != null && b != a) mt_font_close(b);
	g_atlas.faces = {};
	if (g_atlas.pixels.ptr) mem::free(g_atlas.pixels);
	g_atlas.pixels = {};
	if (g_atlas.scratch.ptr) mem::free(g_atlas.scratch);
	g_atlas.scratch = {};
	if (g_atlas.glyphs.is_initialized()) g_atlas.glyphs.free();
}

// atlas_place finds room for a w x h glyph, growing the atlas if it has to.
// Returns false when even the largest atlas is full; the caller then starts
// the atlas again, since everything in it will be re-rasterised on demand.
fn bool atlas_place(int w, int h, int* x, int* y) @private {
	if (w > g_atlas.w) return false;
	if (g_atlas.shelf_x + w > g_atlas.w) {
		g_atlas.shelf_y += g_atlas.shelf_h + 1;
		g_atlas.shelf_x = 0;
		g_atlas.shelf_h = 0;
	}
	while (g_atlas.shelf_y + h > g_atlas.h) {
		if (g_atlas.h * 2 > ATLAS_MAX_HEIGHT) return false;
		int nh = g_atlas.h * 2;
		char[] next = mem::new_array(char, (sz)g_atlas.w * nh);
		next[:g_atlas.pixels.len] = g_atlas.pixels[..];
		mem::free(g_atlas.pixels);
		g_atlas.pixels = next;
		g_atlas.h = nh;
	}
	*x = g_atlas.shelf_x;
	*y = g_atlas.shelf_y;
	g_atlas.shelf_x += w + 1;
	if (h > g_atlas.shelf_h) g_atlas.shelf_h = h;
	return true;
}

// atlas_glyph returns cp in the given face, rasterising it on first use.
fn Glyph atlas_glyph(Face face, uint cp) @private {
	ulong key = (ulong)face << 32 | cp;
	if (try g = g_atlas.glyphs.get(key)) return g;
	Glyph g = { .missing = true };
	void* font = g_atlas.faces[(int)face];
	if (font == null) return g;
	if (g_atlas.scratch.len == 0) g_atlas.scratch = mem::new_array(char, 64 * 64);
	MtGlyphInfo info;
	int rc = mt_font_glyph(font, cp, &info, g_atlas.scratch.ptr, (int)g_atlas.scratch.len);
	if (rc < 0) {
		mem::free(g_atlas.scratch);
		g_atlas.scratch = mem::new_array(char, (sz)-rc);
		rc = mt_font_glyph(font, cp, &info, g_atlas.scratch.ptr, (int)g_atlas.scratch.len);
	}
	if (rc > 0) {
		g = { .w = info.w, .h = info.h, .off_x = info.off_x, .off_y = info.off_y, .advance = info.advance };
		if (info.w > 0 && info.h > 0) {
			int x;
			int y;
			if (!atlas_place(info.w, info.h, &x, &y)) {
				io::eprintn("milktea-gui: glyph atlas full, starting it again");
				atlas_reset();
				if (!atlas_place(info.w, info.h, &x, &y)) return { .missing = true };
			}
			for (int r = 0; r < info.h; r++) {
				sz dst = (sz)(y + r) * g_atlas.w + x;
				sz src = (sz)r * info.w;
				g_atlas.pixels[dst : info.w] = g_atlas.scratch[src : info.w];
			}
			g.x = x;
			g.y = y;
			g_atlas.dirty = true;
		}
	}
	g_atlas.glyphs.set(key, g);
	return g;
}

// atlas_upload hands the atlas to the GPU if anything was added since the
// last frame.
fn void atlas_upload() @private {
	if (!g_atlas.dirty) return;
	mt_atlas_upload(g_atlas.pixels.ptr, g_atlas.w, g_atlas.h);
	g_atlas.dirty = false;
}
