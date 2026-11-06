// backend.m
//
// The GPU half of milktea's GUI: sokol_app for the window and its events,
// sokol_gfx on Metal for drawing. It is the only file that includes sokol,
// and it keeps the API it offers C3 small and flat (gui/backend.c3 binds it),
// so no sokol struct has to be mirrored on the C3 side.
//
// A frame is drawn into an offscreen image at the window's device
// resolution, then composited onto the window, cutting rounded corners on
// the way when the window has them. Frames where nothing changed only
// composite again. The same offscreen image is what a screenshot reads back,
// and a screenshot run draws it with no window at all (mt_headless_begin).
//
// Three pipelines draw everything:
//   quad       glyphs and solid rects, one vertex stream, coverage from the
//              glyph atlas (solid rects sample a white block in it)
//   decor      one rounded rect per draw, its fill, border and shadows
//              worked out per pixel from the rect (no rasterising on the CPU)
//   composite  the offscreen image onto the window
#ifdef __APPLE__

#define SOKOL_IMPL
#define SOKOL_METAL
#define SOKOL_NO_ENTRY
#include "sokol_gfx.h"
#include "sokol_app.h"
#include "sokol_glue.h"
#include "sokol_log.h"

#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <stdlib.h>
#include <string.h>

// ---- shared with gui/backend.c3 -------------------------------------------

typedef struct {
	float x, y; // device pixels
	float u, v; // atlas pixels
	uint32_t color; // RGBA8, straight alpha
} MtVertex;

enum { MT_CMD_QUADS = 0, MT_CMD_DECOR = 1 };

typedef struct {
	int kind;
	int first_quad;
	int quad_count;
	int decor; // index into the decor array, for MT_CMD_DECOR
} MtCmd;

// Per-decoration parameters, as the decor fragment shader reads them: eleven
// float4s, all geometry in device pixels and colours straight RGBA 0..1.
typedef struct {
	float rect[4];   // x, y, w, h
	float misc[4];   // radius, kind (1 solid, 2 linear, 3 radial), border width, flags (1 shadow, 2 inner)
	float c1[4];
	float c2[4];
	float bc[4];     // border colour
	float grad[4];   // linear: x1 y1 x2 y2; radial: cx cy fx fy
	float grad2[4];  // radial: outer radius
	float sh[4];     // shadow dx dy sigma spread
	float shc[4];
	float in[4];     // inner shadow dx dy sigma spread
	float inc[4];
} MtDecor;

typedef struct {
	int type; // MT_EV_*
	int key;
	uint32_t ch;
	int repeat;
	uint32_t mods;
	int button;
	float x, y; // points
	float scroll_y;
} MtEvent;

enum {
	MT_EV_NONE, MT_EV_KEY_DOWN, MT_EV_KEY_UP, MT_EV_CHAR, MT_EV_MOUSE_DOWN, MT_EV_MOUSE_UP,
	MT_EV_MOUSE_MOVE, MT_EV_MOUSE_LEAVE, MT_EV_SCROLL, MT_EV_RESIZED, MT_EV_QUIT_REQUESTED,
	MT_EV_FOCUSED, MT_EV_UNFOCUSED,
};

typedef void (*MtVoidFn)(void);
typedef void (*MtEventFn)(const MtEvent *);

// ---- shaders ----------------------------------------------------------------

static const char *QUAD_VS =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct vs_in { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; float4 color [[attribute(2)]]; };\n"
	"struct vs_out { float4 pos [[position]]; float2 uv; float4 color; float2 px; };\n"
	"struct params { float2 size; float2 atlas; };\n"
	"vertex vs_out _main(vs_in in [[stage_in]], constant params& p [[buffer(0)]]) {\n"
	"  vs_out o;\n"
	"  o.pos = float4(in.pos.x / p.size.x * 2.0 - 1.0, 1.0 - in.pos.y / p.size.y * 2.0, 0.0, 1.0);\n"
	"  o.uv = in.uv / max(p.atlas, float2(1.0)); o.color = in.color; o.px = in.pos;\n"
	"  return o;\n"
	"}\n";

static const char *QUAD_FS =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct vs_out { float4 pos [[position]]; float2 uv; float4 color; float2 px; };\n"
	"fragment float4 _main(vs_out in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {\n"
	"  float a = in.color.a * tex.sample(smp, in.uv).r;\n"
	"  return float4(in.color.rgb * a, a);\n"
	"}\n";

static const char *DECOR_FS =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct vs_out { float4 pos [[position]]; float2 uv; float4 color; float2 px; };\n"
	"struct decor { float4 rect; float4 misc; float4 c1; float4 c2; float4 bc; float4 grad; float4 grad2;\n"
	"  float4 sh; float4 shc; float4 inn; float4 inc; };\n"
	// Signed distance to a rounded rect spanning lo..hi.
	"static float sd_round(float2 p, float2 lo, float2 hi, float r) {\n"
	"  float2 c = (lo + hi) * 0.5; float2 h = max((hi - lo) * 0.5, float2(0.0));\n"
	"  r = min(r, min(h.x, h.y));\n"
	"  float2 q = abs(p - c) - h + r;\n"
	"  return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;\n"
	"}\n"
	"static float cover(float d) { return clamp(0.5 - d, 0.0, 1.0); }\n"
	// A Gaussian-blurred rounded rect, in closed form along x and sampled
	// along y (Evan Wallace, 'Fast rounded rectangle shadows').
	"static float gauss(float x, float s) { return exp(-(x * x) / (2.0 * s * s)) / (2.5066283 * s); }\n"
	"static float2 erf2(float2 x) { float2 s = sign(x); float2 a = abs(x);\n"
	"  x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a; x *= x; return s - s / (x * x); }\n"
	"static float shadow_x(float x, float y, float s, float r, float2 h) {\n"
	"  float d = min(h.y - r - abs(y), 0.0);\n"
	"  float curved = h.x - r + sqrt(max(0.0, r * r - d * d));\n"
	"  float2 i = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (0.70710678 / s));\n"
	"  return i.y - i.x;\n"
	"}\n"
	"static float blurred(float2 p, float2 lo, float2 hi, float r, float s) {\n"
	"  if (s < 0.25) return cover(sd_round(p, lo, hi, r));\n"
	"  float2 c = (lo + hi) * 0.5; float2 h = max((hi - lo) * 0.5, float2(0.0)); p -= c;\n"
	"  r = min(r, min(h.x, h.y));\n"
	"  float lo_y = p.y - h.y; float hi_y = p.y + h.y;\n"
	"  float st = clamp(-3.0 * s, lo_y, hi_y); float en = clamp(3.0 * s, lo_y, hi_y);\n"
	"  float step = (en - st) / 6.0; float y = st + step * 0.5; float v = 0.0;\n"
	"  for (int i = 0; i < 6; i++) { v += shadow_x(p.x, p.y - y, s, r, h) * gauss(y, s) * step; y += step; }\n"
	"  return v;\n"
	"}\n"
	"static float4 over(float4 dst, float3 rgb, float a) { return float4(rgb * a, a) + dst * (1.0 - a); }\n"
	"fragment float4 _main(vs_out in [[stage_in]], constant decor& d [[buffer(0)]]) {\n"
	"  float2 p = in.px;\n"
	"  float2 lo = d.rect.xy; float2 hi = d.rect.xy + d.rect.zw; float r = d.misc.x;\n"
	"  int kind = int(d.misc.y + 0.5); int flags = int(d.misc.w + 0.5);\n"
	"  float4 o = float4(0.0);\n"
	"  if ((flags & 1) != 0) {\n"
	"    float sp = d.sh.w; float2 off = d.sh.xy;\n"
	"    float a = blurred(p, lo + off - sp, hi + off + sp, r + sp, d.sh.z);\n"
	"    o = over(o, d.shc.rgb, d.shc.a * a);\n"
	"  }\n"
	"  float body = cover(sd_round(p, lo, hi, r));\n"
	"  float4 f = d.c1;\n"
	"  if (kind == 2) {\n"
	"    float2 a = d.grad.xy; float2 b = d.grad.zw; float2 ab = b - a;\n"
	"    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);\n"
	"    f = mix(d.c1, d.c2, t);\n"
	"  } else if (kind == 3) {\n"
	// Two-point conical gradient with the focal circle at radius 0: find t
	// with |p - f - t (c - f)| = t R.
	"    float2 cd = d.grad.xy - d.grad.zw; float2 pd = p - d.grad.zw; float R = max(d.grad2.x, 1e-3);\n"
	"    float qa = dot(cd, cd) - R * R; float qb = dot(pd, cd); float qc = dot(pd, pd);\n"
	"    float t;\n"
	"    if (abs(qa) < 1e-4) t = qb > 0.0 ? qc / (2.0 * qb) : 1.0;\n"
	"    else t = (qb - sqrt(max(qb * qb - qa * qc, 0.0))) / qa;\n"
	"    f = mix(d.c1, d.c2, clamp(t, 0.0, 1.0));\n"
	"  }\n"
	"  if (kind > 0) o = over(o, f.rgb, f.a * body);\n"
	"  if ((flags & 2) != 0) {\n"
	"    float sp = d.inn.w; float2 off = d.inn.xy;\n"
	"    float m = blurred(p, lo + off + sp, hi + off - sp, max(r - sp, 0.0), d.inn.z);\n"
	"    o = over(o, d.inc.rgb, d.inc.a * (1.0 - m) * body);\n"
	"  }\n"
	"  float bw = d.misc.z;\n"
	"  if (bw > 0.0) {\n"
	"    float ring = clamp(body - cover(sd_round(p, lo + bw, hi - bw, max(r - bw, 0.0))), 0.0, 1.0);\n"
	"    o = over(o, d.bc.rgb, d.bc.a * ring);\n"
	"  }\n"
	"  return o;\n"
	"}\n";

static const char *COMP_VS =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct out_t { float4 pos [[position]]; float2 uv; };\n"
	"vertex out_t _main(uint vid [[vertex_id]]) {\n"
	"  float2 uv = float2((vid << 1) & 2, vid & 2);\n"
	"  out_t o; o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0); o.uv = uv;\n"
	"  return o;\n"
	"}\n";

static const char *COMP_FS =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct out_t { float4 pos [[position]]; float2 uv; };\n"
	"struct params { float2 size; float radius; float pad; };\n"
	"fragment float4 _main(out_t in [[stage_in]], constant params& p [[buffer(0)]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {\n"
	"  float4 c = tex.sample(smp, in.uv);\n"
	"  if (p.radius > 0.0) {\n"
	"    float2 q = in.uv * p.size;\n"
	"    float2 corner = clamp(q, float2(p.radius), p.size - float2(p.radius));\n"
	"    c *= 1.0 - smoothstep(p.radius - 1.0, p.radius + 1.0, length(q - corner));\n"
	"  }\n"
	"  return c;\n"
	"}\n";

// ---- state ------------------------------------------------------------------

static struct {
	bool ready;
	bool headless;
	sg_pipeline quad_pip, decor_pip, comp_pip;
	sg_sampler nearest, linear;
	sg_buffer vbuf, ibuf;
	int quad_cap;
	sg_image atlas;
	sg_view atlas_view;
	int atlas_w, atlas_h;
	sg_image target;
	sg_view target_att, target_tex;
	int target_w, target_h;
	MtVoidFn init_fn, frame_fn, cleanup_fn;
	MtEventFn event_fn;
} g;

static sg_shader make_shader(const char *vs, const char *fs, int vs_ub, int fs_ub, bool texture) {
	sg_shader_desc d = {0};
	d.vertex_func.source = vs;
	d.vertex_func.entry = "_main";
	d.fragment_func.source = fs;
	d.fragment_func.entry = "_main";
	if (vs_ub > 0) {
		d.uniform_blocks[0].stage = SG_SHADERSTAGE_VERTEX;
		d.uniform_blocks[0].size = (uint32_t)vs_ub;
		d.uniform_blocks[0].msl_buffer_n = 0;
	}
	if (fs_ub > 0) {
		d.uniform_blocks[1].stage = SG_SHADERSTAGE_FRAGMENT;
		d.uniform_blocks[1].size = (uint32_t)fs_ub;
		d.uniform_blocks[1].msl_buffer_n = 0;
	}
	if (texture) {
		d.views[0].texture.stage = SG_SHADERSTAGE_FRAGMENT;
		d.views[0].texture.image_type = SG_IMAGETYPE_2D;
		d.views[0].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
		d.views[0].texture.msl_texture_n = 0;
		d.samplers[0].stage = SG_SHADERSTAGE_FRAGMENT;
		d.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;
		d.samplers[0].msl_sampler_n = 0;
		d.texture_sampler_pairs[0].stage = SG_SHADERSTAGE_FRAGMENT;
		d.texture_sampler_pairs[0].view_slot = 0;
		d.texture_sampler_pairs[0].sampler_slot = 0;
	}
	return sg_make_shader(&d);
}

static sg_pipeline make_quad_pipeline(sg_shader shd) {
	sg_pipeline_desc p = {0};
	p.shader = shd;
	p.layout.attrs[0].format = SG_VERTEXFORMAT_FLOAT2;
	p.layout.attrs[1].format = SG_VERTEXFORMAT_FLOAT2;
	p.layout.attrs[2].format = SG_VERTEXFORMAT_UBYTE4N;
	p.index_type = SG_INDEXTYPE_UINT32;
	p.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8;
	p.colors[0].blend.enabled = true;
	p.colors[0].blend.src_factor_rgb = SG_BLENDFACTOR_ONE;
	p.colors[0].blend.dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	p.colors[0].blend.src_factor_alpha = SG_BLENDFACTOR_ONE;
	p.colors[0].blend.dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	p.depth.pixel_format = SG_PIXELFORMAT_NONE;
	p.sample_count = 1;
	return sg_make_pipeline(&p);
}

static void gfx_init(void) {
	sg_shader quad = make_shader(QUAD_VS, QUAD_FS, 16, 0, true);
	sg_shader decor = make_shader(QUAD_VS, DECOR_FS, 16, (int)sizeof(MtDecor), false);
	sg_shader comp = make_shader(COMP_VS, COMP_FS, 0, 16, true);
	g.quad_pip = make_quad_pipeline(quad);
	g.decor_pip = make_quad_pipeline(decor);
	sg_pipeline_desc cp = {0};
	cp.shader = comp;
	cp.sample_count = 1;
	if (g.headless) {
		cp.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8;
		cp.depth.pixel_format = SG_PIXELFORMAT_NONE;
	}
	g.comp_pip = sg_make_pipeline(&cp);
	g.nearest = sg_make_sampler(&(sg_sampler_desc){
		.min_filter = SG_FILTER_NEAREST, .mag_filter = SG_FILTER_NEAREST,
		.wrap_u = SG_WRAP_CLAMP_TO_EDGE, .wrap_v = SG_WRAP_CLAMP_TO_EDGE,
	});
	g.linear = sg_make_sampler(&(sg_sampler_desc){
		.min_filter = SG_FILTER_LINEAR, .mag_filter = SG_FILTER_LINEAR,
		.wrap_u = SG_WRAP_CLAMP_TO_EDGE, .wrap_v = SG_WRAP_CLAMP_TO_EDGE,
	});
	g.ready = true;
}

// ensure_quads makes the vertex and index buffers big enough for n quads.
// The vertex buffer is write-transient: it is filled and drawn in the same
// frame, which is the only way the frame uses it.
static void ensure_quads(int n) {
	if (n <= g.quad_cap) return;
	int cap = g.quad_cap > 0 ? g.quad_cap : 4096;
	while (cap < n) cap *= 2;
	if (g.vbuf.id) sg_destroy_buffer(g.vbuf);
	if (g.ibuf.id) sg_destroy_buffer(g.ibuf);
	g.vbuf = sg_make_buffer(&(sg_buffer_desc){
		.size = (size_t)cap * 4 * sizeof(MtVertex),
		.usage = { .vertex_buffer = true, .write_transient = true },
	});
	uint32_t *idx = malloc((size_t)cap * 6 * sizeof(uint32_t));
	for (int q = 0; q < cap; q++) {
		uint32_t b = (uint32_t)q * 4;
		uint32_t *o = idx + q * 6;
		o[0] = b; o[1] = b + 1; o[2] = b + 2; o[3] = b + 2; o[4] = b + 1; o[5] = b + 3;
	}
	g.ibuf = sg_make_buffer(&(sg_buffer_desc){
		.usage = { .index_buffer = true },
		.data = { idx, (size_t)cap * 6 * sizeof(uint32_t) },
	});
	free(idx);
	g.quad_cap = cap;
}

static void ensure_target(int w, int h) {
	if (g.target.id && g.target_w == w && g.target_h == h) return;
	if (g.target.id) {
		sg_destroy_view(g.target_att);
		sg_destroy_view(g.target_tex);
		sg_destroy_image(g.target);
	}
	g.target = sg_make_image(&(sg_image_desc){
		.usage = { .color_attachment = true },
		.width = w, .height = h,
		.pixel_format = SG_PIXELFORMAT_RGBA8,
		.sample_count = 1,
	});
	g.target_att = sg_make_view(&(sg_view_desc){ .color_attachment.image = g.target });
	g.target_tex = sg_make_view(&(sg_view_desc){ .texture.image = g.target });
	g.target_w = w;
	g.target_h = h;
}

// ---- API --------------------------------------------------------------------

// mt_atlas_upload replaces the glyph atlas: one byte of coverage per pixel.
// A same-sized atlas is updated in place; a new size makes a new image.
void mt_atlas_upload(const uint8_t *pixels, int w, int h) {
	if (!g.ready) return;
	if (!g.atlas.id || g.atlas_w != w || g.atlas_h != h) {
		if (g.atlas.id) {
			sg_destroy_view(g.atlas_view);
			sg_destroy_image(g.atlas);
		}
		g.atlas = sg_make_image(&(sg_image_desc){
			.usage = { .dynamic_update = true },
			.width = w, .height = h,
			.pixel_format = SG_PIXELFORMAT_R8,
		});
		g.atlas_view = sg_make_view(&(sg_view_desc){ .texture.image = g.atlas });
		g.atlas_w = w;
		g.atlas_h = h;
	}
	sg_image_data data = {0};
	data.mip_levels[0] = (sg_range){ pixels, (size_t)w * (size_t)h };
	sg_update_image(g.atlas, &data);
}

// mt_render draws one frame into the offscreen target: clear, then each
// command in order. Quads are uploaded once and every command draws a range
// of them, so a decoration between two runs of cells costs a pipeline switch,
// not another upload.
void mt_render(const MtVertex *verts, int nquads, const MtCmd *cmds, int ncmds,
	const MtDecor *decors, int fb_w, int fb_h, const float *clear) {
	if (!g.ready || fb_w < 1 || fb_h < 1) return;
	ensure_target(fb_w, fb_h);
	if (nquads > 0) {
		ensure_quads(nquads);
		sg_write_buffer_transient(&(sg_write_buffer_desc){
			.src = { .data = { verts, (size_t)nquads * 4 * sizeof(MtVertex) } },
			.dst = { .buffer = g.vbuf },
			.size = (size_t)nquads * 4 * sizeof(MtVertex),
		});
	}
	sg_begin_pass(&(sg_pass){
		.action = { .colors[0] = { .load_action = SG_LOADACTION_CLEAR,
			.clear_value = { clear[0], clear[1], clear[2], clear[3] } } },
		.attachments = { .colors[0] = g.target_att },
	});
	// Texture coordinates arrive in atlas pixels; the shader divides by its size.
	float size[4] = { (float)fb_w, (float)fb_h, (float)g.atlas_w, (float)g.atlas_h };
	int bound = -1; // 0 quad, 1 decor
	for (int i = 0; i < ncmds && nquads > 0; i++) {
		const MtCmd *c = &cmds[i];
		if (c->quad_count < 1) continue;
		if (c->kind == MT_CMD_QUADS) {
			if (!g.atlas.id) continue;
			if (bound != 0) {
				sg_apply_pipeline(g.quad_pip);
				sg_apply_bindings(&(sg_bindings){
					.vertex_buffers[0] = g.vbuf, .index_buffer = g.ibuf,
					.views[0] = g.atlas_view, .samplers[0] = g.nearest,
				});
				sg_apply_uniforms(0, &(sg_range){ size, sizeof(size) });
				bound = 0;
			}
		} else {
			if (bound != 1) {
				sg_apply_pipeline(g.decor_pip);
				sg_apply_bindings(&(sg_bindings){ .vertex_buffers[0] = g.vbuf, .index_buffer = g.ibuf });
				sg_apply_uniforms(0, &(sg_range){ size, sizeof(size) });
				bound = 1;
			}
			sg_apply_uniforms(1, &(sg_range){ &decors[c->decor], sizeof(MtDecor) });
		}
		sg_draw(c->first_quad * 6, c->quad_count * 6, 1);
	}
	sg_end_pass();
}

static void lat_present(void);

// mt_present composites the offscreen target onto the window and ends the
// frame. radius is the window's corner radius in device pixels, 0 for none.
void mt_present(float radius) {
	if (!g.ready || g.headless) return;
	sg_begin_pass(&(sg_pass){
		.action = { .colors[0] = { .load_action = SG_LOADACTION_CLEAR, .clear_value = { 0, 0, 0, 0 } } },
		.swapchain = sglue_swapchain(),
	});
	if (g.target.id) {
		float p[4] = { (float)sapp_width(), (float)sapp_height(), radius, 0 };
		sg_apply_pipeline(g.comp_pip);
		sg_apply_bindings(&(sg_bindings){ .views[0] = g.target_tex, .samplers[0] = g.linear });
		sg_apply_uniforms(1, &(sg_range){ p, sizeof(p) });
		sg_draw(0, 3, 1);
	}
	sg_end_pass();
	lat_present();
	sg_commit();
}

// mt_commit ends a frame that drew offscreen only (a screenshot run).
void mt_commit(void) {
	if (g.ready) sg_commit();
}

// mt_write_png reads the offscreen target back and writes it to path as a
// PNG. The copy goes through sokol's own command queue, so it runs after the
// frame that drew the target. Returns 0 on success.
int mt_write_png(const char *path) {
	if (!g.ready || !g.target.id) return -1;
	@autoreleasepool {
		sg_mtl_image_info info = sg_mtl_query_image_info(g.target);
		id<MTLTexture> tex = (__bridge id<MTLTexture>)info.tex[info.active_slot];
		id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)sg_mtl_command_queue();
		id<MTLDevice> dev = (__bridge id<MTLDevice>)sg_mtl_device();
		if (!tex || !queue || !dev) return -1;
		NSUInteger w = tex.width, h = tex.height, stride = w * 4;
		id<MTLBuffer> buf = [dev newBufferWithLength:stride * h options:MTLResourceStorageModeShared];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
			sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0
			destinationBytesPerRow:stride destinationBytesPerImage:stride * h];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, buf.contents, stride * h, NULL);
		CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs,
			(CGBitmapInfo)kCGImageAlphaPremultipliedLast, dp, NULL, false, kCGRenderingIntentDefault);
		CFStringRef cfpath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
		CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfpath, kCFURLPOSIXPathStyle, false);
		CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
		int rc = -1;
		if (dest) {
			CGImageDestinationAddImage(dest, img, NULL);
			rc = CGImageDestinationFinalize(dest) ? 0 : -1;
			CFRelease(dest);
		}
		CFRelease(url);
		CFRelease(cfpath);
		CGImageRelease(img);
		CGDataProviderRelease(dp);
		CGColorSpaceRelease(cs);
		[buf release];
		return rc;
	}
}

// ---- headless ---------------------------------------------------------------

// mt_headless_begin sets sokol_gfx up on the default Metal device with no
// window, for a screenshot run. Returns 0 on success.
int mt_headless_begin(void) {
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (!dev) return -1;
	g.headless = true;
	sg_setup(&(sg_desc){
		.environment = {
			.defaults = { .color_format = SG_PIXELFORMAT_RGBA8, .depth_format = SG_PIXELFORMAT_NONE, .sample_count = 1 },
			.metal = { .device = (__bridge const void *)dev },
		},
		.logger.func = slog_func,
	});
	gfx_init();
	return 0;
}

void mt_headless_end(void) {
	if (g.ready) sg_shutdown();
	memset(&g, 0, sizeof(g));
}

// ---- latency probe ------------------------------------------------------------
//
// MILKTEA_DEBUG_LATENCY=1 times each mouse move from the system event to the
// GPU finishing the frame that reacts to it. Times are seconds on the host
// clock NSEvent.timestamp and MTLCommandBuffer.GPUEndTime both use.
//
// Stages: input (event made → app handles it), wait (→ next frame starts),
// cpu (→ frame committed to the GPU), gpu (→ GPU done). What follows GPU
// completion — WindowServer compositing the window and scan-out — cannot be
// timed from inside a windowed app: CAMetalDrawable.presentedTime reads 0
// here. It is usually one more refresh.
//
// A summary goes to stderr every 200 samples, on exit and on SIGTERM.

#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#include <stdio.h>

#define LAT_MAX 4096
typedef struct { double ev, seen, start, commit, gpu_done, target, newest; } LatSample;
static struct {
	int on;
	int pending;          // 1: a move is waiting for a frame; 2: this frame has it
	LatSample cur;
	LatSample s[LAT_MAX];
	volatile int n;       // completed samples, written from the GPU completion handler
	int reported;
	double last_start;
	double newest_ev;     // timestamp of the latest move handled so far
	double refresh_sum;
	int refresh_n;
} lat;

static int cmp_double(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void lat_row(const char *name, double *v, int n) {
	qsort(v, n, sizeof(double), cmp_double);
	double sum = 0;
	for (int i = 0; i < n; i++) sum += v[i];
	fprintf(stderr, "  %-14s mean %6.2f  p50 %6.2f  p90 %6.2f  p99 %6.2f  max %6.2f ms\n", name,
		sum / n * 1000, v[n / 2] * 1000, v[(int)(n * 0.9)] * 1000, v[(int)(n * 0.99)] * 1000, v[n - 1] * 1000);
}

static void lat_report(void) {
	int n = lat.n;
	if (!lat.on || n == 0 || n == lat.reported) return;
	lat.reported = n;
	static double v[LAT_MAX];
	double refresh = lat.refresh_n > 0 ? lat.refresh_sum / lat.refresh_n : 0;
	fprintf(stderr, "milktea latency: %d mouse moves, frame interval %.2f ms\n", n, refresh * 1000);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].seen - lat.s[i].ev;
	lat_row("input", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].start - lat.s[i].seen;
	lat_row("wait", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].commit - lat.s[i].start;
	lat_row("cpu", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].gpu_done - lat.s[i].commit;
	lat_row("gpu", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].gpu_done - lat.s[i].ev;
	lat_row("event→gpu done", v, n);
	int late = 0;
	for (int i = 0; i < n; i++) {
		v[i] = lat.s[i].target - lat.s[i].gpu_done;
		if (v[i] < 0) late++;
	}
	lat_row("slack", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].target - lat.s[i].ev;
	lat_row("oldest→target", v, n);
	for (int i = 0; i < n; i++) v[i] = lat.s[i].target - lat.s[i].newest;
	lat_row("newest→target", v, n);
	fprintf(stderr, "  slack is display-link target minus GPU done; %d of %d frames finished after it\n", late, n);
	fprintf(stderr, "  →target is the move's age when the frame is due on screen (display link\n"
		"  targetTimestamp); scan-out adds a little more, not measurable here\n");
}

static void lat_event(const sapp_event *e) {
	if (!lat.on || e->type != SAPP_EVENTTYPE_MOUSE_MOVE) return;
	NSEvent *ev = [NSApp currentEvent];
	lat.newest_ev = ev ? ev.timestamp : CACurrentMediaTime();
	if (lat.pending) return;
	lat.cur.seen = CACurrentMediaTime();
	lat.cur.ev = ev ? ev.timestamp : lat.cur.seen;
	lat.pending = 1;
}

static void lat_frame_start(void) {
	if (!lat.on) return;
	double now = CACurrentMediaTime();
	lat.cur.target = _sapp.mtl.display_link ? _sapp.mtl.display_link.targetTimestamp : 0;
	if (lat.last_start > 0 && now - lat.last_start < 0.05) {
		lat.refresh_sum += now - lat.last_start;
		lat.refresh_n++;
	}
	lat.last_start = now;
	if (lat.pending == 1) {
		lat.cur.start = now;
		lat.pending = 2;
	}
}

// ---- late latching ---------------------------------------------------------
//
// The display link fires right after a vsync and the frame it draws is shown
// at targetTimestamp, a whole refresh later. Drawing at once leaves most of
// that refresh idle, and input that lands in it waits for the next frame.
// MILKTEA_LATE_LATCH_MS=<n> instead keeps handling events until n ms before
// the target and only then draws, so the frame carries input up to that
// point. n has to cover the frame's CPU and GPU work plus the compositor's
// margin, or frames miss their vsync.

static double late_latch_sec;

static void late_latch_wait(void) {
	if (late_latch_sec <= 0 || _sapp.mtl.display_link == nil) return;
	double deadline = _sapp.mtl.display_link.targetTimestamp - late_latch_sec;
	for (;;) {
		double now = CACurrentMediaTime();
		if (now >= deadline) break;
		NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
			untilDate:[NSDate dateWithTimeIntervalSinceNow:deadline - now]
			inMode:NSDefaultRunLoopMode dequeue:YES];
		if (e != nil) [NSApp sendEvent:e];
	}
}

// lat_present runs just before sg_commit and times the frame's command
// buffer when the frame carries a move.
static void lat_present(void) {
	if (!lat.on || lat.pending != 2 || _sg.mtl.cmd_buffer == nil) return;
	LatSample smp = lat.cur;
	smp.commit = CACurrentMediaTime();
	smp.newest = lat.newest_ev;
	lat.pending = 0;
	[_sg.mtl.cmd_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
		if (lat.n >= LAT_MAX) return;
		double done = cb.GPUEndTime > 0 ? cb.GPUEndTime : CACurrentMediaTime();
		lat.s[lat.n] = smp;
		lat.s[lat.n].gpu_done = done;
		lat.n++;
	}];
}

#include <signal.h>
#include <unistd.h>
static void lat_sigterm(int sig) { (void)sig; lat_report(); _exit(0); }

// ---- windowed ---------------------------------------------------------------

static void app_init(void) {
	sg_setup(&(sg_desc){ .environment = sglue_environment(), .logger.func = slog_func });
	gfx_init();
	if (g.init_fn) g.init_fn();
}

static void app_frame(void) {
	late_latch_wait();
	lat_frame_start();
	if (g.frame_fn) g.frame_fn();
	if (lat.on && lat.n - lat.reported >= 200) lat_report();
}

static void app_cleanup(void) {
	lat_report();
	if (g.cleanup_fn) g.cleanup_fn();
	sg_shutdown();
	memset(&g, 0, sizeof(g));
}

static void app_event(const sapp_event *e) {
	lat_event(e);
	if (!g.event_fn) return;
	MtEvent m = {0};
	float s = sapp_dpi_scale();
	if (s <= 0) s = 1;
	m.mods = e->modifiers;
	m.x = e->mouse_x / s;
	m.y = e->mouse_y / s;
	switch (e->type) {
		case SAPP_EVENTTYPE_KEY_DOWN: m.type = MT_EV_KEY_DOWN; break;
		case SAPP_EVENTTYPE_KEY_UP: m.type = MT_EV_KEY_UP; break;
		case SAPP_EVENTTYPE_CHAR: m.type = MT_EV_CHAR; break;
		case SAPP_EVENTTYPE_MOUSE_DOWN: m.type = MT_EV_MOUSE_DOWN; break;
		case SAPP_EVENTTYPE_MOUSE_UP: m.type = MT_EV_MOUSE_UP; break;
		case SAPP_EVENTTYPE_MOUSE_MOVE: m.type = MT_EV_MOUSE_MOVE; break;
		case SAPP_EVENTTYPE_MOUSE_LEAVE: m.type = MT_EV_MOUSE_LEAVE; break;
		case SAPP_EVENTTYPE_MOUSE_SCROLL: m.type = MT_EV_SCROLL; break;
		case SAPP_EVENTTYPE_RESIZED: m.type = MT_EV_RESIZED; break;
		case SAPP_EVENTTYPE_QUIT_REQUESTED: m.type = MT_EV_QUIT_REQUESTED; break;
		case SAPP_EVENTTYPE_FOCUSED: m.type = MT_EV_FOCUSED; break;
		case SAPP_EVENTTYPE_UNFOCUSED: m.type = MT_EV_UNFOCUSED; break;
		default: return;
	}
	m.key = (int)e->key_code;
	m.ch = e->char_code;
	m.repeat = e->key_repeat ? 1 : 0;
	m.button = (int)e->mouse_button;
	m.scroll_y = e->scroll_y;
	g.event_fn(&m);
}

// mt_run opens the window and runs until it closes. width and height are in
// points. The callbacks are C3's: init once the window and GPU are up, frame
// once per display refresh, event for each input event, cleanup before the
// GPU goes away.
void mt_run(const char *title, int width, int height, MtVoidFn init, MtVoidFn frame,
	MtEventFn event, MtVoidFn cleanup) {
	g.init_fn = init;
	g.frame_fn = frame;
	g.event_fn = event;
	g.cleanup_fn = cleanup;
	const char *ll_env = getenv("MILKTEA_LATE_LATCH_MS");
	late_latch_sec = ll_env ? atof(ll_env) / 1000.0 : 0;
	const char *lat_env = getenv("MILKTEA_DEBUG_LATENCY");
	lat.on = lat_env != NULL && lat_env[0] != 0 && lat_env[0] != '0';
	if (lat.on) {
		atexit(lat_report);
		signal(SIGTERM, lat_sigterm);
	}
	sapp_run(&(sapp_desc){
		.init_cb = app_init,
		.frame_cb = app_frame,
		.cleanup_cb = app_cleanup,
		.event_cb = app_event,
		.width = width,
		.height = height,
		.sample_count = 1,
		.high_dpi = true,
		.window_title = title,
		.logger.func = slog_func,
	});
}

void mt_quit(void) { sapp_quit(); }
void mt_cancel_quit(void) { sapp_cancel_quit(); }
float mt_dpi_scale(void) { return sapp_dpi_scale(); }
int mt_fb_width(void) { return sapp_width(); }
int mt_fb_height(void) { return sapp_height(); }
const void *mt_window(void) { return sapp_macos_get_window(); }

#endif
