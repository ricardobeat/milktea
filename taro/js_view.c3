module taro;
import xray;
import glaze;
import boba;
import milktea;
import std::io;
import std::core::mem;

// ── Focused cursor tracking ───────────────────────────────────────────────────
// Set by the textarea renderer when a focused textarea is rendered.
// Read by js_model.c3 to position the native terminal cursor.

struct FocusedCursor {
	sz x;
	sz y;
	char[32] color_buf; // hex color, e.g. "#ff6600", or empty for terminal default
	bool suppress_native; // true when drawCursor vnode rendered in its place
}

FocusedCursor g_focused_cursor = { };
bool g_has_focused_cursor      = false;

fn void reset_focused_cursor() {
	g_has_focused_cursor = false;
	g_focused_cursor.suppress_native = false;
}

fn bool get_focused_cursor(sz* out_x, sz* out_y, String* out_color, bool* out_suppress) {
	if (!g_has_focused_cursor) return false;
	*out_x = g_focused_cursor.x;
	*out_y = g_focused_cursor.y;
	*out_color = ((ZString)&g_focused_cursor.color_buf).str_view();
	*out_suppress = g_focused_cursor.suppress_native;
	return true;
}

// ── Textarea registry ────────────────────────────────────────────────────────
// Global map from string ID → boba::Textarea, used by the "textarea" vnode type.
// JS calls milktea.textareaUpdate(id, msg) which routes through C → this registry.

struct TextareaEntry {
	char[64] id_buf;
	boba::Textarea ta;
}

// Simple linear-scan registry (max 16 textareas — this is a TUI, not a web app)
TextareaEntry[16] g_textareas;
sz g_textarea_count = 0;

fn boba::Textarea* textarea_get(String id) {
	for (sz i = 0; i < g_textarea_count; i++) {
		if (((ZString)&g_textareas[i].id_buf).str_view() == id) return &g_textareas[i].ta;
	}
	return null;
}

fn boba::Textarea* textarea_get_or_create(String id) {
	boba::Textarea* existing = textarea_get(id);
	if (existing) return existing;
	if (g_textarea_count >= 16) return null;
	TextareaEntry* e = &g_textareas[g_textarea_count];
	sz copy_len      = id.len < 63 ? id.len : 63;
	e.id_buf[:copy_len] = id[:copy_len];
	e.id_buf[copy_len] = 0;
	e.ta = boba::new_textarea(40, 8);
	g_textarea_count++;
	return &e.ta;
}

fn void textarea_reset() {
	g_textarea_count = 0;
}

// ── Viewport registry ─────────────────────────────────────────────────────────

struct ViewportEntry {
	char[64] id_buf;
	boba::Viewport vp;
	sz area_x;
	sz area_y;
	sz area_w;
	sz area_h;
	bool has_area;
}

ViewportEntry[16] g_viewports;
sz g_viewport_count = 0;

fn boba::Viewport* viewport_get(String id) {
	for (sz i = 0; i < g_viewport_count; i++) {
		if (((ZString)&g_viewports[i].id_buf).str_view() == id) return &g_viewports[i].vp;
	}
	return null;
}

fn boba::Viewport* viewport_get_or_create(String id) {
	boba::Viewport* existing = viewport_get(id);
	if (existing) return existing;
	if (g_viewport_count >= 16) return null;
	ViewportEntry* e = &g_viewports[g_viewport_count];
	sz copy_len      = id.len < 63 ? id.len : 63;
	e.id_buf[:copy_len] = id[:copy_len];
	e.id_buf[copy_len] = 0;
	e.vp = boba::new_viewport(80, 24).with_mouse_wheel();
	g_viewport_count++;
	return &e.vp;
}

fn void* viewport_get_ptr(ZString id) @export {
	return viewport_get(id.str_view());
}

// viewport_dispatch_mouse sends a mouse scroll event to the viewport at (row, col).
// Returns true if a viewport consumed the event.
fn bool viewport_dispatch_mouse(sz row, sz col, String button, String action) @export {
	for (sz i = 0; i < g_viewport_count; i++) {
		ViewportEntry* e = &g_viewports[i];
		if (!e.has_area) continue;
		if (row >= e.area_y && row < e.area_y + e.area_h && col >= e.area_x && col < e.area_x + e.area_w) {
			if (e.vp.handle_mouse(button, action)) return true;
		}
	}
	return false;
}

fn void viewport_handle_key_ptr(void* vp_ptr, sz code, sz ctrl, sz alt, sz shift) @export {
	if (!vp_ptr) return;
	boba::Viewport* vp = (boba::Viewport*)vp_ptr;
	milktea::KeyMsg k        = { };
	k.code = (milktea::KeyCode)code;
	k.ctrl = ctrl != 0;
	k.alt = alt != 0;
	k.shift = shift != 0;
	vp.handle_key(k);
}

fn void viewport_scroll_to_bottom_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return;
	((boba::Viewport*)vp_ptr).scroll_to_bottom();
}

fn sz viewport_offset_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return 0;
	return ((boba::Viewport*)vp_ptr).offset;
}

fn void viewport_scroll_up_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return;
	((boba::Viewport*)vp_ptr).scroll_up();
}

fn void viewport_scroll_down_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return;
	((boba::Viewport*)vp_ptr).scroll_down();
}

fn void viewport_page_up_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return;
	((boba::Viewport*)vp_ptr).page_up();
}

fn void viewport_page_down_ptr(void* vp_ptr) @export {
	if (!vp_ptr) return;
	((boba::Viewport*)vp_ptr).page_down();
}

// ── C-callable wrappers for the textarea registry ──────────────────────────

fn void* textarea_get_ptr(ZString id) @export {
	return textarea_get(id.str_view());
}

fn void textarea_handle_key_ptr(void* ta_ptr, sz code, sz rune, bool ctrl, bool alt, bool shift) @export {
	if (!ta_ptr) return;
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	milktea::KeyMsg k        = { };
	k.code = (milktea::KeyCode)code;
	k.rune = (uint)rune;
	k.ctrl = ctrl;
	k.alt = alt;
	k.shift = shift;
	ta.handle_key(k);
}

fn void textarea_clear_ptr(void* ta_ptr) @export {
	if (!ta_ptr) return;
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	ta.clear();
}

fn sz textarea_cursor_row_ptr(void* ta_ptr) @export {
	if (!ta_ptr) return 0;
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	return ta.cursor_row;
}

fn sz textarea_cursor_col_ptr(void* ta_ptr) @export {
	if (!ta_ptr) return 0;
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	return ta.cursor_col;
}

fn ZString textarea_text_ptr(void* ta_ptr) @export {
	if (!ta_ptr) return "";
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	return (ZString)(&ta.buf[0]);
}

fn sz textarea_text_len(void* ta_ptr) @export {
	if (!ta_ptr) return 0;
	boba::Textarea* ta = (boba::Textarea*)ta_ptr;
	return (sz)ta.len;
}


// is_vnode checks that val is a JS object with a string "type" property
fn bool is_vnode(Runtime* rt, void* val) {
	if (!val || rt.is_null(val) || rt.is_string(val)) return false;
	void* type_prop = rt.get_prop(val, "type");
	if (!type_prop) return false;
	bool ok = !rt.is_null(type_prop) && rt.is_string(type_prop);
	rt.free_value(type_prop);
	return ok;
}

// get_prop_string reads a string property, returning "" if absent/not-string
fn String get_prop_string(Runtime* rt, void* obj, String name) @local {
	void* prop = rt.get_prop(obj, name);
	if (!prop || rt.is_null(prop)) {
		if (prop) rt.free_value(prop);
		return "";
	}
	if (!rt.is_string(prop)) {
		rt.free_value(prop);
		return "";
	}
	ZString cstr = taro_to_cstring(rt.ctx, prop);
	rt.free_value(prop);
	if (!cstr) return "";
	String s = string::tformat("%s", cstr.str_view());
	taro_free_cstring(rt.ctx, cstr);
	return s;
}

// get_prop_int reads an sz property, returning default_val if absent/not-sz
fn sz get_prop_int(Runtime* rt, void* obj, String name, sz default_val) @local {
	void* prop = rt.get_prop(obj, name);
	if (!prop || rt.is_null(prop)) {
		if (prop) rt.free_value(prop);
		return default_val;
	}
	ZString cstr = taro_to_cstring(rt.ctx, prop);
	rt.free_value(prop);
	if (!cstr) return default_val;
	sz val = default_val;
	if (try parsed = cstr.str_view().to_int()) val = parsed;
	taro_free_cstring(rt.ctx, cstr);
	return val;
}

// get_prop_bool reads a bool property
fn bool get_prop_bool(Runtime* rt, void* obj, String name) @local {
	void* prop = rt.get_prop(obj, name);
	if (!prop || rt.is_null(prop)) {
		if (prop) rt.free_value(prop);
		return false;
	}
	ZString cstr = taro_to_cstring(rt.ctx, prop);
	rt.free_value(prop);
	if (!cstr) return false;
	bool val = cstr.str_view() == "true";
	taro_free_cstring(rt.ctx, cstr);
	return val;
}

// props_to_style converts JS props object to a glaze Style.
// width/height props are treated as outer (layout) dimensions; border overhead is subtracted
// so that the rendered block exactly fits the allocated rect.
fn glaze::Style props_to_style(Runtime* rt, void* props) @local {
	glaze::Style s = glaze::style();
	if (!props || rt.is_null(props)) return s;

	String fg = get_prop_string(rt, props, "fg");
	if (fg.len > 0) s = s.foreground(glaze::color_hex(fg));

	String bg = get_prop_string(rt, props, "bg");
	if (bg.len > 0) s = s.background(glaze::color_hex(bg));

	if (get_prop_bool(rt, props, "bold")) s = s.with_bold(true);
	if (get_prop_bool(rt, props, "italic")) s = s.with_italic(true);
	if (get_prop_bool(rt, props, "underline")) s = s.with_underline(true);

	String border   = get_prop_string(rt, props, "border");
	bool has_border = false;
	if (border == "rounded") {
		s = s.with_border(glaze::ROUNDED);
		has_border = true;
	} else if (border == "normal" || border == "single") {
		s = s.with_border(glaze::NORMAL);
		has_border = true;
	} else if (border == "thick") {
		s = s.with_border(glaze::THICK);
		has_border = true;
	} else if (border == "double") {
		s = s.with_border(glaze::DOUBLE);
		has_border = true;
	}

	String border_color = get_prop_string(rt, props, "borderColor");
	if (border_color.len > 0) s = s.border_fg(glaze::color_hex(border_color));

	String border_anim = get_prop_string(rt, props, "borderAnimation");
	if (border_anim == "pulse") {
		s = s.border_anim(glaze::BorderAnimation.PULSE);
	} else if (border_anim == "rainbow") {
		s = s.border_anim(glaze::BorderAnimation.RAINBOW);
	} else if (border_anim == "race") {
		s = s.border_anim(glaze::BorderAnimation.RACE);
	}

	sz anim_speed = get_prop_int(rt, props, "borderAnimSpeed", 0);
	if (anim_speed > 0) s = s.border_anim_speed(anim_speed);

	sz pad   = get_prop_int(rt, props, "pad", 0);
	sz pad_x = get_prop_int(rt, props, "pad_x", pad);
	sz pad_y = get_prop_int(rt, props, "pad_y", pad);
	if (pad > 0 || pad_x > 0 || pad_y > 0) {
		s = s.padding(pad_y, pad_x, pad_y, pad_x);
	}

	// set_width/set_height in our glaze mean total outer size (border + padding + content),
	// matching Go glaze Width(N) semantics — render() subtracts border and padding internally.
	sz w = get_prop_int(rt, props, "width", 0);
	if (w > 0) s = s.with_width(w);

	sz h = get_prop_int(rt, props, "height", 0);
	if (h > 0) s = s.with_height(h);

	return s;
}

// collect_text concatenates all string children of a vnode into one string
fn String collect_text(Runtime* rt, void* vnode) @local {
	void* children = rt.get_prop(vnode, "children");
	if (!children || rt.is_null(children) || !rt.is_array(children)) {
		if (children) rt.free_value(children);
		return "";
	}
	sz n = rt.array_length(children);
	DString ds;
	ds.tinit();
	for (sz i = 0; i < n; i++) {
		void* child = rt.array_item(children, (int)i);
		if (!child) continue;
		if (is_vnode(rt, child)) {
			String sub = collect_text(rt, child);
			ds.append(sub);
		} else if (!rt.is_null(child)) {
			// stringify anything — strings, numbers, booleans
			ZString cstr = taro_to_cstring(rt.ctx, child);
			if (cstr) {
				ds.append(cstr.str_view());
				taro_free_cstring(rt.ctx, cstr);
			}
		}
		rt.free_value(child);
	}
	rt.free_value(children);
	return ds.str_view();
}

// BoxMeasureCtx holds the data needed to measure a box vnode's height on demand.
struct BoxMeasureCtx {
	Runtime* rt;
	void* vnode; // borrowed — valid for the duration of layout
}

fn sz _measure_box_height(void* raw_ctx, sz cross) @local {
	BoxMeasureCtx* ctx    = (BoxMeasureCtx*)raw_ctx;
	void* props           = ctx.rt.get_prop(ctx.vnode, "props");
	glaze::Style style = props_to_style(ctx.rt, props);
	if (props) ctx.rt.free_value(props);
	String content = collect_text(ctx.rt, ctx.vnode);
	return style.measure_height(content, cross);
}

// child_constraint returns the layout constraint for a child vnode along the main axis.
// For col layout, box/text children with no explicit height get CFIT so the layout
// engine measures them at the available width before distributing fill space.
fn xray::Constraint child_constraint(Runtime* rt, void* child, bool is_col, xray::Rect parent_area) @local {
	if (!child || rt.is_null(child)) return xray::fill(1);
	void* props = rt.get_prop(child, "props");
	if (!props || rt.is_null(props)) {
		if (props) rt.free_value(props);
		return xray::fill(1);
	}
	sz size = is_col ? get_prop_int(rt, props, "height", 0) : get_prop_int(rt, props, "width", 0);

	if (size > 0) {
		bool has_border = get_prop_string(rt, props, "border").len > 0;
		if (has_border) size += 2;
		sz pad = is_col ? get_prop_int(
			rt,
			props,
			"pad_y",
			get_prop_int(rt, props, "pad", 0)
		) : get_prop_int(rt, props, "pad_x", get_prop_int(rt, props, "pad", 0));
		size += pad * 2;
	}

	rt.free_value(props);

	if (size > 0) return xray::cells(size);

	if (is_col && is_vnode(rt, child)) {
		void* type_prop = rt.get_prop(child, "type");
		String t        = "";
		if (type_prop && !rt.is_null(type_prop) && rt.is_string(type_prop)) {
			ZString ts = taro_to_cstring(rt.ctx, type_prop);
			if (ts) {
				t = string::tformat("%s", ts.str_view());
				taro_free_cstring(rt.ctx, ts);
			}
		}
		if (type_prop) rt.free_value(type_prop);

		// spinner is always 1 row
		if (t == "spinner") return xray::cells(1);

		// text with fit:true measures itself; plain text is 1 row
		if (t == "text") {
			void* fprops   = rt.get_prop(child, "props");
			bool wants_fit = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "fit");
			if (fprops) rt.free_value(fprops);
			if (wants_fit) {
				BoxMeasureCtx* ctx = mem::tnew(BoxMeasureCtx);
				ctx.rt = rt;
				ctx.vnode = child;
				return xray::fit(&_measure_box_height, ctx);
			}
			return xray::cells(1);
		}

		// horizontal stack (row or stack{horizontal:true}) is 1 row when no height set
		if (t == "row") return xray::cells(1);
		if (t == "stack") {
			void* fprops = rt.get_prop(child, "props");
			bool horiz   = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "horizontal");
			if (fprops) rt.free_value(fprops);
			if (horiz) return xray::cells(1);
		}

		// box with fit:true measures itself
		if (t == "box") {
			void* fprops   = rt.get_prop(child, "props");
			bool wants_fit = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "fit");
			if (fprops) rt.free_value(fprops);
			if (wants_fit) {
				BoxMeasureCtx* ctx = mem::tnew(BoxMeasureCtx);
				ctx.rt = rt;
				ctx.vnode = child;
				return xray::fit(&_measure_box_height, ctx);
			}
		}
	}

	return xray::fill(1);
}

// ── Draw animation cache ──────────────────────────────────────────────────────
// When a <draw> vnode has animate={fps}, rendered cells are cached and only
// re-invoked at the target rate. Intermediate frames replay the cache.

const sz DRAW_CACHE_MAX = 8;
const sz DRAW_CACHE_MAX_CELLS = 16384; // max ~128x128 cells per entry

struct DrawCacheEntry {
	sz x, y, w, h;
	sz last_ms;
	sz interval_ms;
	sz cell_count;
	xray::Cell[DRAW_CACHE_MAX_CELLS] cells;
	bool active;
}

DrawCacheEntry[DRAW_CACHE_MAX] g_draw_cache = { };
sz g_draw_cache_count = 0;

fn DrawCacheEntry* draw_cache_find(sz x, sz y, sz w, sz h) @local {
	for (sz i = 0; i < g_draw_cache_count; i++) {
		DrawCacheEntry* e = &g_draw_cache[i];
		if (e.active && e.x == x && e.y == y && e.w == w && e.h == h) return e;
	}
	return null;
}

fn DrawCacheEntry* draw_cache_get_or_create(sz x, sz y, sz w, sz h, sz interval_ms) @local {
	sz total = w * h;
	if (total > DRAW_CACHE_MAX_CELLS) return null;
	DrawCacheEntry* existing = draw_cache_find(x, y, w, h);
	if (existing) {
		existing.interval_ms = interval_ms;
		return existing;
	}
	if (g_draw_cache_count >= DRAW_CACHE_MAX) return null;
	DrawCacheEntry* e = &g_draw_cache[g_draw_cache_count++];
	e.x = x;
	e.y = y;
	e.w = w;
	e.h = h;
	e.interval_ms = interval_ms;
	e.last_ms = 0;
	e.cell_count = 0;
	e.active = true;
	return e;
}

fn void draw_cache_store(DrawCacheEntry* e, xray::ScreenBuffer* screen) @local {
	sz total = e.w * e.h;
	e.cell_count = total;
	for (sz row = 0; row < e.h; row++) {
		for (sz col = 0; col < e.w; col++) {
			sz src_idx = (sz)((e.y + row) * (sz)screen.width + (e.x + col));
			e.cells[row * e.w + col] = screen.cells[src_idx];
		}
	}
}

fn void draw_cache_replay(DrawCacheEntry* e, xray::ScreenBuffer* screen) @local {
	for (sz row = 0; row < e.h; row++) {
		for (sz col = 0; col < e.w; col++) {
			sz dst_idx = (sz)((e.y + row) * (sz)screen.width + (e.x + col));
			screen.cells[dst_idx] = e.cells[row * e.w + col];
		}
	}
}

// render_vnode walks a vnode tree, filling screen with content in area.
// key is the position hash for this node — used to look up component state.
fn void render_vnode(Runtime* rt, void* vnode, xray::ScreenBuffer* screen, xray::Rect area) {
	if (!vnode || rt.is_null(vnode)) return;

	// Plain string: render directly
	if (rt.is_string(vnode)) {
		ZString cstr = taro_to_cstring(rt.ctx, vnode);
		if (cstr) {
			screen.render_ansi_string((sz)area.x, (sz)area.y, cstr.str_view(), xray::default_style());
			taro_free_cstring(rt.ctx, cstr);
		}
		return;
	}

	if (!is_vnode(rt, vnode)) return;

	void* type_prop = rt.get_prop(vnode, "type");
	if (!type_prop) return;
	ZString type_cstr = taro_to_cstring(rt.ctx, type_prop);
	rt.free_value(type_prop);
	if (!type_cstr) return;
	String type = string::tformat("%s", type_cstr.str_view());
	taro_free_cstring(rt.ctx, type_cstr);

	void* props        = rt.get_prop(vnode, "props");
	void* children_arr = rt.get_prop(vnode, "children");

	if (type == "row" || type == "col" || type == "stack") {
		bool is_col            = type == "col" || (type == "stack" && !get_prop_bool(rt, props, "horizontal"));
		sz gap                = 0;
		xray::AlignItems align = xray::AlignItems.ALIGN_START;
		if (props && !rt.is_null(props)) {
			gap = get_prop_int(rt, props, "gap", 0);
			String align_str = get_prop_string(rt, props, "align");
			if (align_str == "center") {
				align = xray::AlignItems.ALIGN_CENTER;
			}
			if (align_str == "end") {
				align = xray::AlignItems.ALIGN_END;
			}
			if (align_str == "stretch") {
				align = xray::AlignItems.ALIGN_STRETCH;
			}
		}

		sz n = 0;
		if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
			n = rt.array_length(children_arr);
		}

		if (n > 0 && n <= 64) {
			xray::Constraint[64] cs;
			xray::Rect[64] rects;
			void*[64] children_refs; // keep fit children alive until after layout

			for (sz i = 0; i < n; i++) {
				void* child = rt.array_item(children_arr, (int)i);
				children_refs[i] = null;
				if (!child || rt.is_null(child)) {
					cs[i] = xray::fill(1);
					if (child) rt.free_value(child);
				} else {
					cs[i] = child_constraint(rt, child, is_col, area);
					if (cs[i].kind == xray::ConstraintKind.CFIT) {
						children_refs[i] = child; // keep alive for measure callback
					} else {
						rt.free_value(child);
					}
				}
			}

			sz computed;
			if (is_col) {
				computed = xray::layout_v_gap(area, cs[0:n], gap, rects[0:n]);
			} else {
				computed = xray::layout_h_gap(area, cs[0:n], gap, rects[0:n]);
			}

			// Free fit children now that layout is done
			for (sz i = 0; i < n; i++) {
				if (children_refs[i]) rt.free_value(children_refs[i]);
			}

			// Apply cross-axis alignment: for row → vertical; for col → horizontal
			sz cross_total = is_col ? area.w : area.h;
			for (sz i = 0; i < computed; i++) {
				// Natural cross size: read height/width prop; default to 1 for leaves, full for fill
				void* child = rt.array_item(children_arr, (int)i);
				sz natural = 1;
				if (child) {
					natural = is_col ? get_prop_int(
						rt,
						child,
						"width",
						cross_total
					) : get_prop_int(rt, child, "height", cross_total);
					rt.free_value(child);
				}
				if (natural <= 0 || natural > cross_total) natural = cross_total;

				switch (align) {
					case xray::AlignItems.ALIGN_STRETCH:
						break; // leave rect as-is (full cross extent already set by layout)
					case xray::AlignItems.ALIGN_START:
						if (is_col) {
							rects[i].x = area.x;
							rects[i].w = natural;
						} else {
							rects[i].y = area.y;
							rects[i].h = natural;
						}
					case xray::AlignItems.ALIGN_CENTER:
						sz extra_c = cross_total - natural;
						if (is_col) {
							rects[i].x = area.x + extra_c / 2;
							rects[i].w = natural;
						} else {
							rects[i].y = area.y + extra_c / 2;
							rects[i].h = natural;
						}
					case xray::AlignItems.ALIGN_END:
						if (is_col) {
							rects[i].x = area.x + cross_total - natural;
							rects[i].w = natural;
						} else {
							rects[i].y = area.y + cross_total - natural;
							rects[i].h = natural;
						}
					default:
				}
			}

			for (sz i = 0; i < computed; i++) {
				void* child = rt.array_item(children_arr, (int)i);
				if (child) {
					render_vnode(rt, child, screen, rects[i]);
					rt.free_value(child);
				}
			}
		}
	} else if (type == "box") {
		glaze::Style style = props_to_style(rt, props);
		bool has_border       = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
		sz border_pad        = has_border ? 2 : 0;

		// Check whether any child is a vnode (vs all strings)
		bool has_vnode_children = false;
		if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
			sz cn = rt.array_length(children_arr);
			for (sz i = 0; i < cn; i++) {
				void* ch = rt.array_item(children_arr, (int)i);
				if (ch && is_vnode(rt, ch)) {
					has_vnode_children = true;
					rt.free_value(ch);
					break;
				}
				if (ch) rt.free_value(ch);
			}
		}

		if (has_vnode_children) {
			// Draw border frame via glaze on empty content, then recurse into inner rect.
			// set_width/set_height = total outer size; render() subtracts border+pad internally.
			sz pad      = props ? get_prop_int(rt, props, "pad", 0) : 0;
			sz pad_x    = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
			sz pad_y    = props ? get_prop_int(rt, props, "pad_y", pad) : 0;
			sz offset_x = border_pad / 2 + pad_x;
			sz offset_y = border_pad / 2 + pad_y;
			sz inner_w  = area.w - border_pad - pad_x * 2;
			sz inner_h  = area.h - border_pad - pad_y * 2;
			if (inner_w < 1) inner_w = 1;
			if (inner_h < 1) inner_h = 1;
			style = style.with_width(area.w).with_height(area.h);
			String frame = style.render("");
			screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
			// Animated border overlay (if borderAnimation is set)
			if (has_border && style.border_animation != glaze::BorderAnimation.NONE) {
				String anim_frame = style.border.wrap_animated(
					area.w - border_pad,
					area.h - border_pad,
					style.border_animation,
					style,
					now_ms()
				);
				screen.render_ansi_string(
					(sz)area.x,
					(sz)area.y,
					anim_frame,
					xray::default_style(),
					(sz)(area.y + area.h)
				);
				request_render_tick(glaze::border_anim_tick_ms(style.border_animation));
			}
			// Inner rect sits inside border + padding
			xray::Rect inner = xray::new_rect(area.x + offset_x, area.y + offset_y, inner_w, inner_h);
			// Treat children as a col container (stack vertically)



			sz n = rt.array_length(children_arr);
			if (n > 0 && n <= 64) {
				xray::Constraint[64] cs;
				xray::Rect[64] rects;
				for (sz i = 0; i < n; i++) {
					void* ch = rt.array_item(children_arr, (int)i);
					cs[i] = ch ? child_constraint(rt, ch, true, inner) : xray::fill(1);
					if (ch) rt.free_value(ch);
				}
				sz computed = xray::layout_v_gap(inner, cs[0:n], 0, rects[0:n]);
				for (sz i = 0; i < computed; i++) {
					void* ch = rt.array_item(children_arr, (int)i);
					if (ch) {
						render_vnode(rt, ch, screen, rects[i]);
						rt.free_value(ch);
					}
				}
			}
		} else {
			// All-text path: collect and render via glaze.
			// set_width/set_height mean total outer size; render() subtracts border internally.
			sz content_w = area.w - border_pad;
			sz content_h = area.h - border_pad;
			if (content_w < 1) content_w = 1;
			if (content_h < 1) content_h = 1;
			String content = collect_text(rt, vnode);
			if (has_border && style.border_animation != glaze::BorderAnimation.NONE) {
				// Animated: render content without border, then wrap with animated border.
				if (get_prop_int(rt, props, "width", 0) == 0) {
					style = style.with_width(area.w);
				}
				if (get_prop_int(rt, props, "height", 0) == 0) {
					style = style.with_height(area.h);
				}
				String content_rendered = style.render_content_only(content);
				String anim_border = style.border.wrap_animated(
					content_w,
					content_h,
					style.border_animation,
					style,
					now_ms()
				);
				// Render content, then overlay animated border on top.
				screen.render_ansi_string(
					(sz)area.x,
					(sz)area.y,
					content_rendered,
					xray::default_style(),
					(sz)(area.y + area.h)
				);
				screen.render_ansi_string(
					(sz)area.x,
					(sz)area.y,
					anim_border,
					xray::default_style(),
					(sz)(area.y + area.h)
				);
				request_render_tick(glaze::border_anim_tick_ms(style.border_animation));
			} else {
				if (get_prop_int(rt, props, "width", 0) == 0) {
					style = style.with_width(area.w);
				}
				if (get_prop_int(rt, props, "height", 0) == 0) {
					style = style.with_height(area.h);
				}
				String rendered = style.render(content);
				screen.render_ansi_string(
					(sz)area.x,
					(sz)area.y,
					rendered,
					xray::default_style(),
					(sz)(area.y + area.h)
				);
			}
		}
	} else if (type == "spinner") {
		String kind_str          = props ? get_prop_string(rt, props, "kind") : "";
		boba::SpinnerKind kind = boba::SpinnerKind.DOTS;
		if (kind_str == "line") kind = boba::SpinnerKind.LINE;
		if (kind_str == "arrow") kind = boba::SpinnerKind.ARROW;
		if (kind_str == "pulse") kind = boba::SpinnerKind.PULSE;
		if (kind_str == "moon") kind = boba::SpinnerKind.MOON;

		glaze::Color fg = { };
		if (props) {
			String fg_str = get_prop_string(rt, props, "fg");
			if (fg_str.len > 0) fg = glaze::color_hex(fg_str);
		}

		boba::SpinnerFrames fs = boba::spinner_frames(kind);
		sz frame                = (now_ms() / fs.interval_ms) % fs.count;
		String frame_str         = fs.frames[frame];
		if (fg.kind != glaze::ColorKind.NONE) {
			frame_str = glaze::style().foreground(fg).render(frame_str);
		}
		screen.render_ansi_string((sz)area.x, (sz)area.y, frame_str, xray::default_style());
		request_render_tick(fs.interval_ms);
	} else if (type == "textarea") {
		// Textarea: stateful component backed by boba::Textarea
		// Props: id (required), focused (bool), placeholder (string),
		//        prompt (string prefix, default ""), show_line_numbers (bool, default false),
		//        border/fg/bg/pad/pad_x/pad_y/height — same as "box"
		String id = props ? get_prop_string(rt, props, "id") : "";
		if (id.len == 0) id = "_default";

		boba::Textarea* ta = textarea_get_or_create(id);
		if (ta) {
			bool has_border = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
			sz border_pad  = has_border ? 2 : 0;
			sz pad         = props ? get_prop_int(rt, props, "pad", 0) : 0;
			sz pad_x       = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
			sz pad_y       = props ? get_prop_int(rt, props, "pad_y", pad) : 0;

			// Inner area after border and padding
			sz inner_w = area.w - border_pad - pad_x * 2;
			sz inner_h = area.h - border_pad - pad_y * 2;
			if (inner_w < 1) inner_w = 1;
			if (inner_h < 1) inner_h = 1;

			ta.width = inner_w;
			ta.height = inner_h;

			if (props) {
				String ph = get_prop_string(rt, props, "placeholder");
				if (ph.len > 0) ta.placeholder = ph;
				String prompt = get_prop_string(rt, props, "prompt");
				ta.prompt = prompt;
				ta.show_line_numbers = get_prop_bool(rt, props, "show_line_numbers");
				ta.show_cursor = get_prop_bool(rt, props, "showCursor");
				ta.focused = get_prop_bool(rt, props, "focused");

				String fg_str = get_prop_string(rt, props, "fg");
				if (fg_str.len > 0) {
					glaze::Color fg_col = glaze::color_hex(fg_str);
					ta.focused_style = glaze::style().foreground(fg_col);
					ta.prompt_style = glaze::style().foreground(fg_col);
				}

				// Fake cursor style: cursorBg / cursorFg props override defaults
				String cursor_bg = get_prop_string(rt, props, "cursorBg");
				String cursor_fg = get_prop_string(rt, props, "cursorFg");
				if (cursor_bg.len > 0 || cursor_fg.len > 0) {
					glaze::Style cs = glaze::style();
					if (cursor_bg.len > 0) cs = cs.background(glaze::color_hex(cursor_bg));
					if (cursor_fg.len > 0) cs = cs.foreground(glaze::color_hex(cursor_fg));
					ta.cursor_style = cs;
				}
			}

			// Draw border frame (if any) by rendering an empty box of the full area size.
			// Then write ta.view() directly into the inner rect, bypassing glaze render()
			// so the content height is exactly what ta.view() produces (no padding/clipping issues).
			if (has_border || pad_x > 0 || pad_y > 0) {
				glaze::Style frame_style = props_to_style(rt, props);
				frame_style = frame_style.with_width(area.w).with_height(area.h);
				String frame = frame_style.render("");
				screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
				if (has_border && frame_style.border_animation != glaze::BorderAnimation.NONE) {
					String anim_frame = frame_style.border.wrap_animated(
						area.w - border_pad,
						area.h - border_pad,
						frame_style.border_animation,
						frame_style,
						now_ms()
					);
					screen.render_ansi_string(
						(sz)area.x,
						(sz)area.y,
						anim_frame,
						xray::default_style(),
						(sz)(area.y + area.h)
					);
					request_render_tick(glaze::border_anim_tick_ms(frame_style.border_animation));
				}
			}
			// Write content lines directly into the inner rect
			xray::Rect inner = xray::new_rect(
				area.x + border_pad / 2 + pad_x,
				area.y + border_pad / 2 + pad_y,
				inner_w,
				inner_h
			);
			String content = ta.view();
			screen.render_ansi_string(
				(sz)inner.x,
				(sz)inner.y,
				content,
				xray::default_style(),
				(sz)(inner.y + inner_h),
				(sz)(inner.x + inner_w)
			);

			// Record screen-space cursor position for the native terminal cursor.
			if (ta.focused) {
				sz prompt_w = (sz)ta.prompt.len;
				g_focused_cursor.x = inner.x + prompt_w + ta.cursor_col;
				g_focused_cursor.y = inner.y + (ta.cursor_row - ta.scroll_offset);
				// Store cursor color from the cursorColor prop (or clear it)
				String cc   = props ? get_prop_string(rt, props, "cursorColor") : "";
				sz copy_len = cc.len < 31 ? cc.len : 31;
				g_focused_cursor.color_buf[:copy_len] = cc[:copy_len];
				g_focused_cursor.color_buf[copy_len] = 0;
				g_has_focused_cursor = true;

				// drawCursor prop: fn(x, y, blink) -> string | null
				// Renders a custom string at the cursor position and suppresses the native cursor.
				void* draw_fn = props ? rt.get_prop(props, "drawCursor") : null;
				if (draw_fn && !rt.is_null(draw_fn) && rt.is_function(draw_fn)) {
					sz interval_ms = props ? get_prop_int(rt, props, "cursorInterval", 500) : 500;
					if (interval_ms < 16) interval_ms = 16;
					sz now   = now_ms();
					bool blink = ((now / interval_ms) % 2) == 0;
					request_render_tick(interval_ms);

					void* x_arg       = rt.new_int32((int)g_focused_cursor.x);
					void* y_arg       = rt.new_int32((int)g_focused_cursor.y);
					void* b_arg       = rt.new_int32((int)blink);
					void* draw_result = rt.call3(draw_fn, null, x_arg, y_arg, b_arg);
					if (x_arg) rt.free_value(x_arg);
					if (y_arg) rt.free_value(y_arg);
					if (b_arg) rt.free_value(b_arg);
					if (draw_result && !rt.is_null(draw_result) && rt.is_string(draw_result)) {
						ZString cstr = taro_to_cstring(rt.ctx, draw_result);
						if (cstr) {
							screen.overlay_char(
								(sz)g_focused_cursor.x,
								(sz)g_focused_cursor.y,
								cstr.str_view(),
								xray::default_style()
							);
							taro_free_cstring(rt.ctx, cstr);
						}
					}
					if (draw_result) rt.free_value(draw_result);
					g_focused_cursor.suppress_native = true;
				}
				if (draw_fn) rt.free_value(draw_fn);
			}
		}
	} else if (type == "viewport") {
		// Viewport: stateful scrollable content area backed by boba::Viewport.
		// Props: id (required), border/fg/bg/pad — same as box.
		// Children: string content (lines separated by \n).
		String id = props ? get_prop_string(rt, props, "id") : "";
		if (id.len == 0) id = "_vp_default";

		boba::Viewport* vp = viewport_get_or_create(id);
		if (vp) {
			// Store the rendered area for mouse event dispatch
			for (sz vi = 0; vi < g_viewport_count; vi++) {
				if (&g_viewports[vi].vp == vp) {
					g_viewports[vi].area_x = area.x;
					g_viewports[vi].area_y = area.y;
					g_viewports[vi].area_w = area.w;
					g_viewports[vi].area_h = area.h;
					g_viewports[vi].has_area = true;
					break;
				}
			}

			bool has_border = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
			sz border_pad  = has_border ? 2 : 0;
			sz pad         = props ? get_prop_int(rt, props, "pad", 0) : 0;
			sz pad_x       = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
			sz pad_y       = props ? get_prop_int(rt, props, "pad_y", pad) : 0;

			sz inner_w = area.w - border_pad - pad_x * 2;
			sz inner_h = area.h - border_pad - pad_y * 2;
			if (inner_w < 1) inner_w = 1;
			if (inner_h < 1) inner_h = 1;

			vp.width = inner_w;
			vp.height = inner_h;

			// inner rect needed for child measurement below
			xray::Rect inner = xray::new_rect(
				area.x + border_pad / 2 + pad_x,
				area.y + border_pad / 2 + pad_y,
				inner_w,
				inner_h
			);

			// Collect only string (non-vnode) children as text content — vnode children are
			// rendered separately below and must not be included in the text stream.
			DString content_ds;
			content_ds.tinit();
			if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
				sz cn = rt.array_length(children_arr);
				for (sz ci = 0; ci < cn; ci++) {
					void* ch = rt.array_item(children_arr, (int)ci);
					if (!ch) continue;
					if (!is_vnode(rt, ch) && !rt.is_null(ch)) {
						ZString cstr = taro_to_cstring(rt.ctx, ch);
						if (cstr) {
							content_ds.append(cstr.str_view());
							taro_free_cstring(rt.ctx, cstr);
						}
					}
					rt.free_value(ch);
				}
			}
			String content      = content_ds.str_view();
			sz text_line_count = 1;
			for (sz ci = 0; ci < content.len; ci++) {
				if (content[ci] == '\n') text_line_count++;
			}

			// Collect vnode children and measure each one's height at inner_w
			sz vnode_child_count = 0;
			void*[16] vnode_children;
			sz[16] vnode_heights;
			if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
				sz cn = rt.array_length(children_arr);
				for (sz ci = 0; ci < cn && vnode_child_count < 16; ci++) {
					void* ch = rt.array_item(children_arr, (int)ci);
					if (ch && is_vnode(rt, ch)) {
						// measure height: explicit height prop, else 1 for inline types, else measure
						void* ch_props = rt.get_prop(ch, "type");
						sz h_explicit = 0;
						void* cp       = rt.get_prop(ch, "props");
						if (cp && !rt.is_null(cp)) h_explicit = get_prop_int(rt, cp, "height", 0);
						if (cp) rt.free_value(cp);
						if (ch_props) rt.free_value(ch_props);
						sz ch_h;
						if (h_explicit > 0) {
							ch_h = h_explicit;
						} else {
							// use child_constraint in col mode to detect fixed-height types
							xray::Constraint cc = child_constraint(rt, ch, true, inner);
							if (cc.kind == xray::ConstraintKind.CLEN) {
								ch_h = (sz)cc.value;
							} else {
								ch_h = 1; // fill/fit defaults to 1 inside viewport
							}
						}
						vnode_children[vnode_child_count] = ch;
						vnode_heights[vnode_child_count] = ch_h;
						vnode_child_count++;
					} else {
						if (ch) rt.free_value(ch);
					}
				}
			}

			sz vnode_total_lines = 0;
			for (sz vi = 0; vi < vnode_child_count; vi++) vnode_total_lines += vnode_heights[vi];
			sz total_lines = text_line_count + vnode_total_lines;
			vp.set_content(total_lines);

			// Draw border frame
			if (has_border || pad_x > 0 || pad_y > 0) {
				glaze::Style frame_style = props_to_style(rt, props);
				frame_style = frame_style.with_width(area.w).with_height(area.h);
				String frame = frame_style.render("");
				screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
				if (has_border && frame_style.border_animation != glaze::BorderAnimation.NONE) {
					String anim_frame = frame_style.border.wrap_animated(
						area.w - border_pad,
						area.h - border_pad,
						frame_style.border_animation,
						frame_style,
						now_ms()
					);
					screen.render_ansi_string(
						(sz)area.x,
						(sz)area.y,
						anim_frame,
						xray::default_style(),
						(sz)(area.y + area.h)
					);
					request_render_tick(glaze::border_anim_tick_ms(frame_style.border_animation));
				}
			}

			// Render visible lines into inner rect
			sz start = vp.view_line_start();
			sz end   = vp.view_line_end();

			// Walk text content to find the start line, then render each visible text line
			sz pos       = 0;
			sz cur_line = 0;
			while (pos < content.len && cur_line < start) {
				if (content[pos] == '\n') cur_line++;
				pos++;
			}
			for (sz r = start; r < end && r < text_line_count; r++) {
				if (pos > content.len) break;
				sz line_end = pos;
				while (line_end < content.len && content[line_end] != '\n') line_end++;
				String line                = content[pos:line_end - pos];
				glaze::Style line_style = glaze::style();
				if (props) {
					String fg_str = get_prop_string(rt, props, "fg");
					if (fg_str.len > 0) line_style = line_style.foreground(glaze::color_hex(fg_str));
				}
				line_style = line_style.with_width(inner_w);
				String rendered_line = line_style.render(line);
				screen.render_ansi_string(
					(sz)inner.x,
					(sz)(inner.y + r - start),
					rendered_line,
					xray::default_style(),
					0,
					(sz)(inner.x + inner_w)
				);
				pos = line_end < content.len ? line_end + 1 : content.len + 1;
			}

			// Render vnode children that fall within the visible range (appended after text lines)
			sz vnode_line = text_line_count;
			for (sz vi = 0; vi < vnode_child_count; vi++) {
				sz ch_h   = vnode_heights[vi];
				sz ch_end = vnode_line + ch_h;
				// visible if any part of this child overlaps [start, end)



				if (ch_end > start && vnode_line < end) {
					sz screen_y = inner.y + vnode_line - start;
					sz clip_h   = ch_h;
					// clip to inner rect



					if (screen_y < inner.y) {
						clip_h -= inner.y - screen_y;
						screen_y = inner.y;
					}
					if (screen_y + clip_h > inner.y + inner_h) clip_h = inner.y + inner_h - screen_y;
					if (clip_h > 0) {
						void* ch_props = rt.get_prop(vnode_children[vi], "props");
						sz ch_w       = ch_props ? get_prop_int(rt, ch_props, "width", inner_w) : inner_w;
						if (ch_props) rt.free_value(ch_props);
						if (ch_w <= 0 || ch_w > inner_w) ch_w = inner_w;
						xray::Rect ch_rect = xray::new_rect(inner.x, screen_y, ch_w, clip_h);
						render_vnode(rt, vnode_children[vi], screen, ch_rect);
					}
				}
				rt.free_value(vnode_children[vi]);
				vnode_line += ch_h;
			}
		}
	} else if (type == "text") {
		glaze::Style style = props_to_style(rt, props);
		String content        = collect_text(rt, vnode);
		String rendered       = style.render(content);
		screen.render_ansi_string((sz)area.x, (sz)area.y, rendered, xray::default_style(), (sz)(area.y + area.h));
	} else if (type == "draw") {
		// draw: calls a JS function fn(width, height) -> string for each row in the rect.
		// If props.fn is a function, call it once per visible row with (row_width, row_index).
		// Props.animate: bool → auto-tick at ~60fps (16ms).
		//                number → target fps (e.g. 30 = 30fps, 5 = 5fps).
		//                When animate is set, drawing is throttled to the target rate;
		//                intermediate frames replay the last cached render.
		if (props && !rt.is_null(props)) {
			sz fps = get_prop_int(rt, props, "animate", 0);
			bool anim_bool = !fps ? get_prop_bool(rt, props, "animate") : false;
			bool has_animate = fps > 0 || anim_bool;
			sz interval_ms = has_animate ? (fps > 0 ? 1000 / fps : 16) : 0;
			if (interval_ms < 1) interval_ms = 1;

			DrawCacheEntry* cache = null;
			bool should_redraw = true;
			if (has_animate) {
				cache = draw_cache_get_or_create(area.x, area.y, area.w, area.h, interval_ms);
				if (cache) {
					sz now = now_ms();
					if (cache.last_ms > 0 && (now - cache.last_ms) < interval_ms) {
						should_redraw = false;
					}
				}
				request_render_tick(interval_ms);
			}

			if (should_redraw) {
				void* fn_val = rt.get_prop(props, "fn");
				if (fn_val && !rt.is_null(fn_val) && rt.is_function(fn_val)) {
					void* undef = null; // null this
					for (sz r = 0; r < area.h; r++) {
						void* w_arg  = rt.new_int32((int)area.w);
						void* r_arg  = rt.new_int32((int)r);
						void* result = rt.call2(fn_val, undef, w_arg, r_arg);
						if (w_arg) rt.free_value(w_arg);
						if (r_arg) rt.free_value(r_arg);
						if (result && !rt.is_null(result)) {
							// Fast path: Uint8Array — direct cell writes, no ANSI parsing
							if (rt.is_uint8_array(result)) {
								char[] data = rt.get_uint8_array_data(result);
								sz cell_count = data.len / 6;
								sz sx = (sz)area.x;
								sz sy = (sz)(area.y + r);
								// The array length is chosen by the JS script, so it
								// cannot be trusted to match the draw area. Clamp to the
								// node's width and to what is actually on screen —
								// writing cell_count cells unchecked let a script return
								// an oversized array and walk off the cell buffer.
								if (sy < 0 || sy >= screen.height || sx >= screen.width) cell_count = 0;
								if (sx < 0) sx = 0;
								if (cell_count > (sz)area.w) cell_count = (sz)area.w;
								sz room = screen.width - sx;
								if (cell_count > room) cell_count = room;
								sz row_base = sy * screen.width + sx;
								for (sz ci = 0; ci < cell_count; ci++) {
									sz off = ci * 6;
									xray::Cell cell;
									cell.content[0] = (char)0xe2;
									cell.content[1] = (char)0x96;
									cell.content[2] = (char)0x80;
									cell.content_len = 3;
									cell.width = 1;
									cell.style = {
										.fg = { .kind = xray::ColorKind.TRUECOLOR, .r = data[off], .g = data[off + 1], .b = data[off + 2] },
										.bg = { .kind = xray::ColorKind.TRUECOLOR, .r = data[off + 3], .g = data[off + 4], .b = data[off + 5] },
									};
									screen.cells[row_base + ci] = cell;
								}
							} else {
								// String path (backward compatible)
								ZString cstr = taro_to_cstring(rt.ctx, result);
								if (cstr) {
									screen.render_ansi_string(
										(sz)area.x,
										(sz)(area.y + r),
										cstr.str_view(),
										xray::default_style()
									);
									taro_free_cstring(rt.ctx, cstr);
								}
							}
							rt.free_value(result);
						}
					}
				}
				if (fn_val) rt.free_value(fn_val);

				if (cache) {
					draw_cache_store(cache, screen);
					cache.last_ms = now_ms();
				}
			} else if (cache && cache.cell_count > 0) {
				draw_cache_replay(cache, screen);
			}
		}
	}

	if (props) rt.free_value(props);
	if (children_arr) rt.free_value(children_arr);
}