module milktea_gui;

// Reuse one device-resolution PlutoVG surface. Each decoration is uploaded
// and composited at its position in xray's paint stream, before later content.
// PlutoVG's premultiplied ARGB is converted to straight RGBA for raylib.

import milktea;
import xray;
import raylib6::rl;
import std::core::mem;

// The plutovg enum values the layer uses; the rest of the library's constants
// are not needed here.
const int PLUTOVG_SPREAD_PAD = 0;
const int PLUTOVG_LINE_JOIN_ROUND = 1;

// plutovg_gradient_stop_t: a stop offset followed by a colour. Laid out to
// match, so it can be passed straight through.
struct PlutovgStop {
	float offset;
	float r;
	float g;
	float b;
	float a;
}

// The slice of plutovg's API this file binds. Handles are opaque pointers: the
// library's structs stay its own.
extern fn void* plutovg_surface_create(int width, int height) @cname("plutovg_surface_create");
extern fn void plutovg_surface_destroy(void* surface) @cname("plutovg_surface_destroy");
extern fn char* plutovg_surface_get_data(void* surface) @cname("plutovg_surface_get_data");
extern fn int plutovg_surface_get_stride(void* surface) @cname("plutovg_surface_get_stride");
extern fn void* plutovg_canvas_create(void* surface) @cname("plutovg_canvas_create");
extern fn void plutovg_canvas_destroy(void* canvas) @cname("plutovg_canvas_destroy");
extern fn void plutovg_canvas_round_rect(void* canvas, float x, float y, float w, float h, float rx, float ry) @cname("plutovg_canvas_round_rect");
extern fn void plutovg_canvas_set_rgba(void* canvas, float r, float g, float b, float a) @cname("plutovg_canvas_set_rgba");
extern fn void plutovg_canvas_set_linear_gradient(void* canvas, float x1, float y1, float x2, float y2, int spread, PlutovgStop* stops, int nstops, void* matrix) @cname("plutovg_canvas_set_linear_gradient");
extern fn void plutovg_canvas_set_radial_gradient(void* canvas, float cx, float cy, float cr, float fx, float fy, float fr, int spread, PlutovgStop* stops, int nstops, void* matrix) @cname("plutovg_canvas_set_radial_gradient");
extern fn void plutovg_canvas_set_line_width(void* canvas, float width) @cname("plutovg_canvas_set_line_width");
extern fn void plutovg_canvas_set_line_join(void* canvas, int join) @cname("plutovg_canvas_set_line_join");
extern fn void plutovg_canvas_fill(void* canvas) @cname("plutovg_canvas_fill");
extern fn void plutovg_canvas_stroke(void* canvas) @cname("plutovg_canvas_stroke");
extern fn void plutovg_convert_argb_to_rgba(char* dst, char* src, int width, int height, int stride) @cname("plutovg_convert_argb_to_rgba");

// DecorRGBA is a colour in the floats plutovg wants, straight (not
// premultiplied) alpha.
struct DecorRGBA {
	float r;
	float g;
	float b;
	float a;
}

// decor_rgba converts an xray colour to plutovg's 0..1 floats. A colour kind
// with no truecolor value of its own (NONE, TRANSPARENT) converts to fully
// transparent, so a decoration left unset draws nothing rather than black.
fn DecorRGBA decor_rgba(xray::Color c, float fallback_a = 1.0f) {
	switch (c.kind) {
		case xray::ColorKind.TRUECOLOR:
			return {
				(float)c.r / 255.0f,
				(float)c.g / 255.0f,
				(float)c.b / 255.0f,
				(float)c.effective_alpha() / 255.0f,
			};
		case xray::ColorKind.ANSI:
			Rgb p = ANSI16[c.index & 0x0f];
			return { (float)p.r / 255.0f, (float)p.g / 255.0f, (float)p.b / 255.0f, fallback_a };
		case xray::ColorKind.ANSI256:
			Rgb p = ansi256_rgb(c.index);
			return { (float)p.r / 255.0f, (float)p.g / 255.0f, (float)p.b / 255.0f, fallback_a };
		default:
			return { 0.0f, 0.0f, 0.0f, 0.0f };
	}
}

// DecorPainter is the offscreen surface and the texture it reaches the screen
// through, sized in the window's device pixels.
struct DecorPainter {
	void* surface;
	void* canvas;
	rl::RLTexture2D texture;
	// Straight RGBA, raylib's format, converted from plutovg's premultiplied
	// ARGB each frame.
	char[] pixels;
	int width;
	int height;
	float scale;
	bool ready;
}

DecorPainter g_decor @local;

fn bool decor_available() => g_decor.ready;

fn void decor_shutdown() {
	decor_cache_clear();
	if (g_decor.texture.id != 0) {
		rl::unload_texture(g_decor.texture);
		g_decor.texture = { };
	}
	if (g_decor.canvas != null) {
		plutovg_canvas_destroy(g_decor.canvas);
		g_decor.canvas = null;
	}
	if (g_decor.surface != null) {
		plutovg_surface_destroy(g_decor.surface);
		g_decor.surface = null;
	}
	if (g_decor.pixels.ptr != null) {
		mem::free(g_decor.pixels.ptr);
		g_decor.pixels = { };
	}
	g_decor.ready = false;
}

// decor_init allocates the surface and its texture for a window of the given
// logical size at the given device scale. Calling it again reallocates, which
// is what a resize does.
fn bool decor_init(int width, int height, float scale) {
	decor_shutdown();
	int px_w = (int)((float)width * scale + 0.5f);
	int px_h = (int)((float)height * scale + 0.5f);
	if (px_w < 1 || px_h < 1) return false;
	g_decor.surface = plutovg_surface_create(px_w, px_h);
	if (g_decor.surface == null) return false;
	g_decor.canvas = plutovg_canvas_create(g_decor.surface);
	if (g_decor.canvas == null) {
		plutovg_surface_destroy(g_decor.surface);
		g_decor.surface = null;
		return false;
	}
	g_decor.width = px_w;
	g_decor.height = px_h;
	g_decor.scale = scale;
	g_decor.pixels = mem::new_array(char, (sz)px_w * px_h * 4);
	rl::RLImage img = {
		.data = g_decor.pixels.ptr,
		.width = px_w,
		.height = px_h,
		.mipmaps = 1,
		.format = rl::RLPixelFormat.UNCOMPRESSED_R8G8B8A8,
	};
	g_decor.texture = rl::load_texture_from_image(img);
	if (g_decor.texture.id == 0) {
		decor_shutdown();
		return false;
	}
	// The surface is drawn back at exactly its device size, so any filtering
	// only ever smooths a subpixel offset, never a real scale.
	g_decor.texture.set_filter(rl::RLTextureFilter.BILINEAR);
	g_decor.ready = true;
	return true;
}

// decor_ensure makes the surface match a window of the given logical size and
// device scale, allocating it on first use and reallocating on a resize. It is
// called before drawing, so the layer follows the window with no other plumbing.
fn void decor_ensure(int width, int height, float scale) {
	if (scale <= 0.0f) scale = 1.0f;
	int px_w = (int)((float)width * scale + 0.5f);
	int px_h = (int)((float)height * scale + 0.5f);
	if (g_decor.ready && g_decor.width == px_w && g_decor.height == px_h
		&& g_decor.scale == scale) {
		return;
	}
	decor_init(width, height, scale);
}

// DecorRegion is the part of the surface one decoration can touch, in device
// pixels. Clearing, converting and uploading only that much is what keeps a
// decoration cheap: the surface is the whole window at device scale, and
// doing the full thing per decoration cost tens of milliseconds a frame.
struct DecorRegion {
	int x;
	int y;
	int w;
	int h;
}

// decor_region is the device-pixel box decor_paint can reach for d: its rect
// grown by the shadow's offset and blur, plus a little for antialiasing,
// clamped to the surface. An empty box (w or h 0) means nothing to draw.
fn DecorRegion decor_region(xray::Decoration d) {
	float s = g_decor.scale;
	float x0 = (float)d.rect.x * s;
	float y0 = (float)d.rect.y * s;
	float x1 = x0 + (float)d.rect.w * s;
	float y1 = y0 + (float)d.rect.h * s;
	if (d.shadow) {
		float blur = d.shadow_blur * s;
		float dx = d.shadow_dx * s;
		float dy = d.shadow_dy * s;
		if (x0 + dx - blur < x0) x0 = x0 + dx - blur;
		if (y0 + dy - blur < y0) y0 = y0 + dy - blur;
		if (x1 + dx + blur > x1) x1 = x1 + dx + blur;
		if (y1 + dy + blur > y1) y1 = y1 + dy + blur;
	}
	int ix0 = (int)x0 - 2;
	int iy0 = (int)y0 - 2;
	int ix1 = (int)x1 + 3;
	int iy1 = (int)y1 + 3;
	if (ix0 < 0) ix0 = 0;
	if (iy0 < 0) iy0 = 0;
	if (ix1 > g_decor.width) ix1 = g_decor.width;
	if (iy1 > g_decor.height) iy1 = g_decor.height;
	if (ix1 <= ix0 || iy1 <= iy0) return { };
	return { ix0, iy0, ix1 - ix0, iy1 - iy0 };
}

// decor_begin clears the region of the surface to fully transparent, ready
// for a decoration painted inside it.
fn void decor_begin(DecorRegion r) {
	if (!g_decor.ready) return;
	char* data = plutovg_surface_get_data(g_decor.surface);
	int stride = plutovg_surface_get_stride(g_decor.surface);
	for (int y = r.y; y < r.y + r.h; y++) {
		mem::set(data + (sz)y * stride + (sz)r.x * 4, 0, (sz)r.w * 4);
	}
}

// decor_paint rasterises one decoration. Rect coordinates are the view's
// logical cells-or-points; the scale turns them into device pixels.
fn void decor_paint(xray::Decoration d) {
	if (!g_decor.ready) return;
	if (d.kind == xray::DecorationKind.NONE) return;
	float s = g_decor.scale;
	float x = (float)d.rect.x * s;
	float y = (float)d.rect.y * s;
	float w = (float)d.rect.w * s;
	float h = (float)d.rect.h * s;
	if (w <= 0.0f || h <= 0.0f) return;

	float r = d.radius * s;
	float max_r = (w < h ? w : h) / 2.0f;
	if (r > max_r) r = max_r;
	if (r < 0.0f) r = 0.0f;

	// Shadow: a few growing, fading copies of the shape rather than a real
	// blur — plutovg has no blur operator, and at UI shadow sizes the
	// difference does not read.
	if (d.shadow) {
		DecorRGBA sc = decor_rgba(d.shadow_color, 0.35f);
		float dx = d.shadow_dx * s;
		float dy = d.shadow_dy * s;
		float blur = d.shadow_blur * s;
		int layers = blur > 0.5f ? 4 : 1;
		for (int i = 1; i <= layers; i++) {
			float grow = blur * (float)(layers + 1 - i) / (float)layers;
			float a = sc.a / (float)layers;
			plutovg_canvas_set_rgba(g_decor.canvas, sc.r, sc.g, sc.b, a);
			float rr = r + grow;
			plutovg_canvas_round_rect(g_decor.canvas, x + dx - grow, y + dy - grow,
				w + grow * 2.0f, h + grow * 2.0f, rr, rr);
			plutovg_canvas_fill(g_decor.canvas);
		}
	}

	plutovg_canvas_round_rect(g_decor.canvas, x, y, w, h, r, r);
	switch (d.kind) {
		case xray::DecorationKind.SOLID:
			DecorRGBA c = decor_rgba(d.color);
			plutovg_canvas_set_rgba(g_decor.canvas, c.r, c.g, c.b, c.a);
		case xray::DecorationKind.LINEAR:
			PlutovgStop[2] stops;
			DecorRGBA c1 = decor_rgba(d.color);
			DecorRGBA c2 = decor_rgba(d.color2);
			stops[0] = { .offset = 0.0f, .r = c1.r, .g = c1.g, .b = c1.b, .a = c1.a };
			stops[1] = { .offset = 1.0f, .r = c2.r, .g = c2.g, .b = c2.b, .a = c2.a };
			plutovg_canvas_set_linear_gradient(g_decor.canvas,
				x + d.x1 * w, y + d.y1 * h, x + d.x2 * w, y + d.y2 * h,
				PLUTOVG_SPREAD_PAD, &stops[0], 2, null);
		case xray::DecorationKind.RADIAL:
			PlutovgStop[2] stops;
			DecorRGBA c1 = decor_rgba(d.color);
			DecorRGBA c2 = decor_rgba(d.color2);
			stops[0] = { .offset = 0.0f, .r = c1.r, .g = c1.g, .b = c1.b, .a = c1.a };
			stops[1] = { .offset = 1.0f, .r = c2.r, .g = c2.g, .b = c2.b, .a = c2.a };
			float cr = d.r > 0.0f ? d.r * (w < h ? w : h) : (w < h ? w : h) / 2.0f;
			plutovg_canvas_set_radial_gradient(g_decor.canvas,
				x + d.cx * w, y + d.cy * h, cr,
				x + d.fx * w, y + d.fy * h, 0.0f,
				PLUTOVG_SPREAD_PAD, &stops[0], 2, null);
		default:
			return;
	}
	plutovg_canvas_fill(g_decor.canvas);

	// Border drawn inside the rect: the stroke straddles the path, so the path
	// is inset by half the width and the fill above stays flush with the edge.
	if (d.border > 0.0f) {
		float bw = d.border * s;
		if (bw > 0.0f && w > bw && h > bw) {
			DecorRGBA bc = decor_rgba(d.border_color);
			plutovg_canvas_set_rgba(g_decor.canvas, bc.r, bc.g, bc.b, bc.a);
			plutovg_canvas_set_line_width(g_decor.canvas, bw);
			plutovg_canvas_set_line_join(g_decor.canvas, PLUTOVG_LINE_JOIN_ROUND);
			float inset = bw / 2.0f;
			float br = r - inset;
			if (br < 0.0f) br = 0.0f;
			plutovg_canvas_round_rect(g_decor.canvas, x + inset, y + inset,
				w - bw, h - bw, br, br);
			plutovg_canvas_stroke(g_decor.canvas);
		}
	}
}

// DecorCached is one decoration already rasterised into a texture of its own.
// The rounded rects, gradients and shadows a view decorates with are the same
// from one frame to the next, so the expensive part — rasterising on the CPU
// and uploading — runs only when one changes; otherwise it is one quad.
struct DecorCached {
	xray::Decoration d;
	float scale;
	DecorRegion r;
	rl::RLTexture2D tex;
	long used;
}

const DECOR_CACHE = 32;
DecorCached[DECOR_CACHE] g_decor_cache @local;
long g_decor_clock @local;

// decor_cached returns the texture for d, rasterising it on a miss into the
// least recently used slot.
fn DecorCached* decor_cached(xray::Decoration d) @local {
	g_decor_clock++;
	DecorCached* lru = &g_decor_cache[0];
	foreach (&c : g_decor_cache) {
		if (c.tex.id != 0 && c.scale == g_decor.scale && mem::equals(((char*)&c.d)[:xray::Decoration::size], ((char*)&d)[:xray::Decoration::size])) {
			c.used = g_decor_clock;
			return c;
		}
		if (c.used < lru.used) lru = c;
	}
	DecorRegion r = decor_region(d);
	if (r.w == 0 || r.h == 0) return null;
	decor_begin(r);
	decor_paint(d);
	char* src = plutovg_surface_get_data(g_decor.surface);
	int stride = plutovg_surface_get_stride(g_decor.surface);
	for (int y = 0; y < r.h; y++) {
		plutovg_convert_argb_to_rgba(g_decor.pixels.ptr + (sz)y * r.w * 4,
			src + (sz)(r.y + y) * stride + (sz)r.x * 4, r.w, 1, stride);
	}
	if (lru.tex.id != 0 && (lru.r.w != r.w || lru.r.h != r.h)) {
		rl::unload_texture(lru.tex);
		lru.tex = { };
	}
	if (lru.tex.id == 0) {
		rl::RLImage img = {
			.data = g_decor.pixels.ptr,
			.width = r.w,
			.height = r.h,
			.mipmaps = 1,
			.format = rl::RLPixelFormat.UNCOMPRESSED_R8G8B8A8,
		};
		lru.tex = rl::load_texture_from_image(img);
		lru.tex.set_filter(rl::RLTextureFilter.BILINEAR);
	} else {
		rl::gl_update_texture(lru.tex.id, 0, 0, r.w, r.h,
			(int)rl::RLPixelFormat.UNCOMPRESSED_R8G8B8A8, g_decor.pixels.ptr);
	}
	lru.d = d;
	lru.scale = g_decor.scale;
	lru.r = r;
	lru.used = g_decor_clock;
	return lru;
}

fn void decor_cache_clear() @local {
	foreach (&c : g_decor_cache) {
		if (c.tex.id != 0) rl::unload_texture(c.tex);
		*c = { };
	}
}

// decor_draw composites one decoration at its place in the paint stream.
fn void decor_draw(xray::Decoration d, GuiOptions opts, int width, int height) {
	decor_ensure(width, height,
		rl::get_window_scale_dpi().x);
	if (!decor_available()) return;
	if (!d.pixel_rect) {
		d.rect.x *= opts.cell_w;
		d.rect.y *= opts.cell_h;
		d.rect.w *= opts.cell_w;
		d.rect.h *= opts.cell_h;
	}
	DecorCached* c = decor_cached(d);
	if (c == null) return;
	float s = g_decor.scale;
	rl::draw_texture_pro(c.tex,
		{ 0, 0, (float)c.r.w, (float)c.r.h },
		{ (float)c.r.x / s, (float)c.r.y / s, (float)c.r.w / s, (float)c.r.h / s },
		{ 0, 0 }, 0.0f, rl::WHITE);
}
