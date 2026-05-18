module jsrt;
import xray;
import lipgloss;
import pearls;
import tea;
import std::io;
import std::core::mem;

// ── Textarea registry ────────────────────────────────────────────────────────
// Global map from string ID → pearls::Textarea, used by the "textarea" vnode type.
// JS calls tea.textareaUpdate(id, msg) which routes through C → this registry.

struct TextareaEntry {
    char[64] id_buf;
    pearls::Textarea ta;
}

// Simple linear-scan registry (max 16 textareas — this is a TUI, not a web app)
TextareaEntry[16] g_textareas;
int g_textarea_count = 0;

fn pearls::Textarea* textarea_get(String id) {
    for (int i = 0; i < g_textarea_count; i++) {
        if (((ZString)&g_textareas[i].id_buf).str_view() == id) return &g_textareas[i].ta;
    }
    return null;
}

fn pearls::Textarea* textarea_get_or_create(String id) {
    pearls::Textarea* existing = textarea_get(id);
    if (existing) return existing;
    if (g_textarea_count >= 16) return null;
    TextareaEntry* e = &g_textareas[g_textarea_count];
    sz copy_len = id.len < 63 ? id.len : 63;
    e.id_buf[:copy_len] = id[:copy_len];
    e.id_buf[copy_len] = 0;
    e.ta = pearls::new_textarea(40, 8);
    g_textarea_count++;
    return &e.ta;
}

fn void textarea_reset() {
    g_textarea_count = 0;
}

// ── Viewport registry ─────────────────────────────────────────────────────────

struct ViewportEntry {
    char[64] id_buf;
    pearls::Viewport vp;
}

ViewportEntry[16] g_viewports;
int g_viewport_count = 0;

fn pearls::Viewport* viewport_get(String id) {
    for (int i = 0; i < g_viewport_count; i++) {
        if (((ZString)&g_viewports[i].id_buf).str_view() == id) return &g_viewports[i].vp;
    }
    return null;
}

fn pearls::Viewport* viewport_get_or_create(String id) {
    pearls::Viewport* existing = viewport_get(id);
    if (existing) return existing;
    if (g_viewport_count >= 16) return null;
    ViewportEntry* e = &g_viewports[g_viewport_count];
    sz copy_len = id.len < 63 ? id.len : 63;
    e.id_buf[:copy_len] = id[:copy_len];
    e.id_buf[copy_len] = 0;
    e.vp = pearls::new_viewport(80, 24);
    g_viewport_count++;
    return &e.vp;
}

fn void* viewport_get_ptr(ZString id) @export {
    return viewport_get(id.str_view());
}

fn void viewport_handle_key_ptr(void* vp_ptr, int code, int ctrl, int alt, int shift) @export {
    if (!vp_ptr) return;
    pearls::Viewport* vp = (pearls::Viewport*)vp_ptr;
    tea::KeyMsg k = {};
    k.code = (tea::KeyCode)code;
    k.ctrl = ctrl != 0;
    k.alt = alt != 0;
    k.shift = shift != 0;
    vp.handle_key(k);
}

fn void viewport_scroll_to_bottom_ptr(void* vp_ptr) @export {
    if (!vp_ptr) return;
    ((pearls::Viewport*)vp_ptr).scroll_to_bottom();
}

fn int viewport_offset_ptr(void* vp_ptr) @export {
    if (!vp_ptr) return 0;
    return ((pearls::Viewport*)vp_ptr).offset;
}

// ── C-callable wrappers for the textarea registry ──────────────────────────

fn void* textarea_get_ptr(ZString id) @export {
    return textarea_get(id.str_view());
}

fn void textarea_handle_key_ptr(void* ta_ptr, int code, int rune, bool ctrl, bool alt, bool shift) @export {
    if (!ta_ptr) return;
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    tea::KeyMsg k = {};
    k.code = (tea::KeyCode)code;
    k.rune = (char)rune;
    k.ctrl = ctrl;
    k.alt = alt;
    k.shift = shift;
    ta.handle_key(k);
}

fn void textarea_clear_ptr(void* ta_ptr) @export {
    if (!ta_ptr) return;
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    ta.clear();
}

fn int textarea_cursor_row_ptr(void* ta_ptr) @export {
    if (!ta_ptr) return 0;
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    return ta.cursor_row;
}

fn int textarea_cursor_col_ptr(void* ta_ptr) @export {
    if (!ta_ptr) return 0;
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    return ta.cursor_col;
}

fn ZString textarea_text_ptr(void* ta_ptr) @export {
    if (!ta_ptr) return "";
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    return (ZString)(&ta.buf[0]);
}

fn int textarea_text_len(void* ta_ptr) @export {
    if (!ta_ptr) return 0;
    pearls::Textarea* ta = (pearls::Textarea*)ta_ptr;
    return (int)ta.len;
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
    ZString cstr = jsrt_to_cstring(rt.ctx, prop);
    rt.free_value(prop);
    if (!cstr) return "";
    String s = string::tformat("%s", cstr.str_view());
    jsrt_free_cstring(rt.ctx, cstr);
    return s;
}

// get_prop_int reads an int property, returning default_val if absent/not-int
fn int get_prop_int(Runtime* rt, void* obj, String name, int default_val) @local {
    void* prop = rt.get_prop(obj, name);
    if (!prop || rt.is_null(prop)) {
        if (prop) rt.free_value(prop);
        return default_val;
    }
    ZString cstr = jsrt_to_cstring(rt.ctx, prop);
    rt.free_value(prop);
    if (!cstr) return default_val;
    int val = default_val;
    if (try parsed = cstr.str_view().to_int()) val = parsed;
    jsrt_free_cstring(rt.ctx, cstr);
    return val;
}

// get_prop_bool reads a bool property
fn bool get_prop_bool(Runtime* rt, void* obj, String name) @local {
    void* prop = rt.get_prop(obj, name);
    if (!prop || rt.is_null(prop)) {
        if (prop) rt.free_value(prop);
        return false;
    }
    ZString cstr = jsrt_to_cstring(rt.ctx, prop);
    rt.free_value(prop);
    if (!cstr) return false;
    bool val = cstr.str_view() == "true";
    jsrt_free_cstring(rt.ctx, cstr);
    return val;
}

// props_to_style converts JS props object to a lipgloss Style.
// width/height props are treated as outer (layout) dimensions; border overhead is subtracted
// so that the rendered block exactly fits the allocated rect.
fn lipgloss::Style props_to_style(Runtime* rt, void* props) @local {
    lipgloss::Style s = lipgloss::new_style();
    if (!props || rt.is_null(props)) return s;

    String fg = get_prop_string(rt, props, "fg");
    if (fg.len > 0) s = s.foreground(lipgloss::color_hex(fg));

    String bg = get_prop_string(rt, props, "bg");
    if (bg.len > 0) s = s.background(lipgloss::color_hex(bg));

    if (get_prop_bool(rt, props, "bold"))      s = s.set_bold(true);
    if (get_prop_bool(rt, props, "italic"))    s = s.set_italic(true);
    if (get_prop_bool(rt, props, "underline")) s = s.set_underline(true);

    String border = get_prop_string(rt, props, "border");
    bool has_border = false;
    if (border == "rounded") {
        s = s.set_border(lipgloss::rounded_border());
        has_border = true;
    } else if (border == "normal" || border == "single") {
        s = s.set_border(lipgloss::normal_border());
        has_border = true;
    } else if (border == "thick") {
        s = s.set_border(lipgloss::thick_border());
        has_border = true;
    } else if (border == "double") {
        s = s.set_border(lipgloss::double_border());
        has_border = true;
    }

    String border_color = get_prop_string(rt, props, "borderColor");
    if (border_color.len > 0) s = s.set_border_fg(lipgloss::color_hex(border_color));

    int pad = get_prop_int(rt, props, "pad", 0);
    int pad_x = get_prop_int(rt, props, "pad_x", pad);
    int pad_y = get_prop_int(rt, props, "pad_y", pad);
    if (pad > 0 || pad_x > 0 || pad_y > 0) {
        s = s.padding(pad_y, pad_x, pad_y, pad_x);
    }

    // set_width/set_height in our lipgloss mean total outer size (border + padding + content),
    // matching Go lipgloss Width(N) semantics — render() subtracts border and padding internally.
    int w = get_prop_int(rt, props, "width", 0);
    if (w > 0) s = s.set_width(w);

    int h = get_prop_int(rt, props, "height", 0);
    if (h > 0) s = s.set_height(h);

    return s;
}

// collect_text concatenates all string children of a vnode into one string
fn String collect_text(Runtime* rt, void* vnode) @local {
    void* children = rt.get_prop(vnode, "children");
    if (!children || rt.is_null(children) || !rt.is_array(children)) {
        if (children) rt.free_value(children);
        return "";
    }
    int n = rt.array_length(children);
    DString ds;
    ds.tinit();
    for (int i = 0; i < n; i++) {
        void* child = rt.array_item(children, i);
        if (!child) continue;
        if (is_vnode(rt, child)) {
            String sub = collect_text(rt, child);
            ds.append(sub);
        } else if (!rt.is_null(child)) {
            // stringify anything — strings, numbers, booleans
            ZString cstr = jsrt_to_cstring(rt.ctx, child);
            if (cstr) {
                ds.append(cstr.str_view());
                jsrt_free_cstring(rt.ctx, cstr);
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
    void*    vnode;  // borrowed — valid for the duration of layout
}

fn int _measure_box_height(void* raw_ctx, int cross) @local {
    BoxMeasureCtx* ctx = (BoxMeasureCtx*)raw_ctx;
    void* props = ctx.rt.get_prop(ctx.vnode, "props");
    lipgloss::Style style = props_to_style(ctx.rt, props);
    if (props) ctx.rt.free_value(props);
    String content = collect_text(ctx.rt, ctx.vnode);
    return style.measure_height(content, cross);
}

// child_constraint returns the layout constraint for a child vnode along the main axis.
// For col layout, box/text children with no explicit height get CFIT so the layout
// engine measures them at the available width before distributing fill space.
fn xray::Constraint child_constraint(Runtime* rt, void* child, bool is_col, xray::Rect parent_area) @local {
    if (!child || rt.is_null(child)) return xray::constraint_fill(1);
    void* props = rt.get_prop(child, "props");
    if (!props || rt.is_null(props)) {
        if (props) rt.free_value(props);
        return xray::constraint_fill(1);
    }
    int size = is_col
        ? get_prop_int(rt, props, "height", 0)
        : get_prop_int(rt, props, "width", 0);

    if (size > 0) {
        bool has_border = get_prop_string(rt, props, "border").len > 0;
        if (has_border) size += 2;
        int pad = is_col
            ? get_prop_int(rt, props, "pad_y", get_prop_int(rt, props, "pad", 0))
            : get_prop_int(rt, props, "pad_x", get_prop_int(rt, props, "pad", 0));
        size += pad * 2;
    }

    rt.free_value(props);

    if (size > 0) return xray::constraint_len(size);

    if (is_col && is_vnode(rt, child)) {
        void* type_prop = rt.get_prop(child, "type");
        String t = "";
        if (type_prop && !rt.is_null(type_prop) && rt.is_string(type_prop)) {
            ZString ts = jsrt_to_cstring(rt.ctx, type_prop);
            if (ts) {
                t = string::tformat("%s", ts.str_view());
                jsrt_free_cstring(rt.ctx, ts);
            }
        }
        if (type_prop) rt.free_value(type_prop);

        // spinner is always 1 row
        if (t == "spinner") return xray::constraint_len(1);

        // text with fit:true measures itself; plain text is 1 row
        if (t == "text") {
            void* fprops = rt.get_prop(child, "props");
            bool wants_fit = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "fit");
            if (fprops) rt.free_value(fprops);
            if (wants_fit) {
                BoxMeasureCtx* ctx = mem::tnew(BoxMeasureCtx);
                ctx.rt    = rt;
                ctx.vnode = child;
                return xray::constraint_fit(&_measure_box_height, ctx);
            }
            return xray::constraint_len(1);
        }

        // horizontal stack (row or stack{horizontal:true}) is 1 row when no height set
        if (t == "row") return xray::constraint_len(1);
        if (t == "stack") {
            void* fprops = rt.get_prop(child, "props");
            bool horiz = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "horizontal");
            if (fprops) rt.free_value(fprops);
            if (horiz) return xray::constraint_len(1);
        }

        // box with fit:true measures itself
        if (t == "box") {
            void* fprops = rt.get_prop(child, "props");
            bool wants_fit = fprops && !rt.is_null(fprops) && get_prop_bool(rt, fprops, "fit");
            if (fprops) rt.free_value(fprops);
            if (wants_fit) {
                BoxMeasureCtx* ctx = mem::tnew(BoxMeasureCtx);
                ctx.rt    = rt;
                ctx.vnode = child;
                return xray::constraint_fit(&_measure_box_height, ctx);
            }
        }
    }

    return xray::constraint_fill(1);
}

// render_vnode walks a vnode tree, filling screen with content in area.
// key is the position hash for this node — used to look up component state.
fn void render_vnode(Runtime* rt, void* vnode, xray::ScreenBuffer* screen, xray::Rect area) {
    if (!vnode || rt.is_null(vnode)) return;

    // Plain string: render directly
    if (rt.is_string(vnode)) {
        ZString cstr = jsrt_to_cstring(rt.ctx, vnode);
        if (cstr) {
            screen.render_ansi_string((sz)area.x, (sz)area.y, cstr.str_view(), xray::default_style());
            jsrt_free_cstring(rt.ctx, cstr);
        }
        return;
    }

    if (!is_vnode(rt, vnode)) return;

    void* type_prop = rt.get_prop(vnode, "type");
    if (!type_prop) return;
    ZString type_cstr = jsrt_to_cstring(rt.ctx, type_prop);
    rt.free_value(type_prop);
    if (!type_cstr) return;
    String type = string::tformat("%s", type_cstr.str_view());
    jsrt_free_cstring(rt.ctx, type_cstr);

    void* props = rt.get_prop(vnode, "props");
    void* children_arr = rt.get_prop(vnode, "children");

    if (type == "row" || type == "col" || type == "stack") {
        bool is_col = type == "col" || (type == "stack" && !get_prop_bool(rt, props, "horizontal"));
        int gap = 0;
        xray::AlignItems align = xray::AlignItems.ALIGN_START;
        if (props && !rt.is_null(props)) {
            gap = get_prop_int(rt, props, "gap", 0);
            String align_str = get_prop_string(rt, props, "align");
            if (align_str == "center")  { align = xray::AlignItems.ALIGN_CENTER; }
            if (align_str == "end")     { align = xray::AlignItems.ALIGN_END; }
            if (align_str == "stretch") { align = xray::AlignItems.ALIGN_STRETCH; }
        }

        int n = 0;
        if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
            n = rt.array_length(children_arr);
        }

        if (n > 0 && n <= 64) {
            xray::Constraint[64] cs;
            xray::Rect[64] rects;
            void*[64] children_refs; // keep fit children alive until after layout

            for (int i = 0; i < n; i++) {
                void* child = rt.array_item(children_arr, i);
                children_refs[i] = null;
                if (!child || rt.is_null(child)) {
                    cs[i] = xray::constraint_fill(1);
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

            int computed;
            if (is_col) {
                computed = xray::layout_v_gap(area, cs[0:n], gap, rects[0:n]);
            } else {
                computed = xray::layout_h_gap(area, cs[0:n], gap, rects[0:n]);
            }

            // Free fit children now that layout is done
            for (int i = 0; i < n; i++) {
                if (children_refs[i]) rt.free_value(children_refs[i]);
            }

            // Apply cross-axis alignment: for row → vertical; for col → horizontal
            int cross_total = is_col ? area.w : area.h;
            for (int i = 0; i < computed; i++) {
                // Natural cross size: read height/width prop; default to 1 for leaves, full for fill
                void* child = rt.array_item(children_arr, i);
                int natural = 1;
                if (child) {
                    natural = is_col
                        ? get_prop_int(rt, child, "width",  cross_total)
                        : get_prop_int(rt, child, "height", cross_total);
                    rt.free_value(child);
                }
                if (natural <= 0 || natural > cross_total) natural = cross_total;

                switch (align) {
                    case xray::AlignItems.ALIGN_STRETCH:
                        break; // leave rect as-is (full cross extent already set by layout)
                    case xray::AlignItems.ALIGN_START:
                        if (is_col) { rects[i].x = area.x; rects[i].w = natural; }
                        else        { rects[i].y = area.y; rects[i].h = natural; }
                    case xray::AlignItems.ALIGN_CENTER:
                        int extra_c = cross_total - natural;
                        if (is_col) { rects[i].x = area.x + extra_c / 2; rects[i].w = natural; }
                        else        { rects[i].y = area.y + extra_c / 2; rects[i].h = natural; }
                    case xray::AlignItems.ALIGN_END:
                        if (is_col) { rects[i].x = area.x + cross_total - natural; rects[i].w = natural; }
                        else        { rects[i].y = area.y + cross_total - natural; rects[i].h = natural; }
                    default:
                }
            }

            for (int i = 0; i < computed; i++) {
                void* child = rt.array_item(children_arr, i);
                if (child) {
                    render_vnode(rt, child, screen, rects[i]);
                    rt.free_value(child);
                }
            }
        }

    } else if (type == "box") {
        lipgloss::Style style = props_to_style(rt, props);
        bool has_border = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
        int border_pad = has_border ? 2 : 0;

        // Check whether any child is a vnode (vs all strings)
        bool has_vnode_children = false;
        if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
            int cn = rt.array_length(children_arr);
            for (int i = 0; i < cn; i++) {
                void* ch = rt.array_item(children_arr, i);
                if (ch && is_vnode(rt, ch)) { has_vnode_children = true; rt.free_value(ch); break; }
                if (ch) rt.free_value(ch);
            }
        }

        if (has_vnode_children) {
            // Draw border frame via lipgloss on empty content, then recurse into inner rect.
            // lipgloss height/width = content size; border adds 2, padding handled by frame.
            int pad   = props ? get_prop_int(rt, props, "pad",   0) : 0;
            int pad_x = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
            int pad_y = props ? get_prop_int(rt, props, "pad_y", pad) : 0;
            int offset_x = border_pad / 2 + pad_x;
            int offset_y = border_pad / 2 + pad_y;
            int inner_w = area.w - border_pad - pad_x * 2;
            int inner_h = area.h - border_pad - pad_y * 2;
            if (inner_w < 1) inner_w = 1;
            if (inner_h < 1) inner_h = 1;
            style = style.set_width(area.w - border_pad).set_height(area.h - border_pad);
            String frame = style.render("");
            screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
            // Inner rect sits inside border + padding
            xray::Rect inner = xray::new_rect(area.x + offset_x, area.y + offset_y, inner_w, inner_h);
            // Treat children as a col container (stack vertically)
            int n = rt.array_length(children_arr);
            if (n > 0 && n <= 64) {
                xray::Constraint[64] cs;
                xray::Rect[64] rects;
                for (int i = 0; i < n; i++) {
                    void* ch = rt.array_item(children_arr, i);
                    cs[i] = ch ? child_constraint(rt, ch, true, inner) : xray::constraint_fill(1);
                    if (ch) rt.free_value(ch);
                }
                int computed = xray::layout_v_gap(inner, cs[0:n], 0, rects[0:n]);
                for (int i = 0; i < computed; i++) {
                    void* ch = rt.array_item(children_arr, i);
                    if (ch) { render_vnode(rt, ch, screen, rects[i]); rt.free_value(ch); }
                }
            }
        } else {
            // All-text path: collect and render via lipgloss.
            // lipgloss height/width = content size; border adds 2 on each axis.
            int content_w = area.w - border_pad;
            int content_h = area.h - border_pad;
            if (content_w < 1) content_w = 1;
            if (content_h < 1) content_h = 1;
            if (get_prop_int(rt, props, "width", 0) == 0) {
                style = style.set_width(content_w);
            }
            if (get_prop_int(rt, props, "height", 0) == 0) {
                style = style.set_height(content_h);
            }
            String content = collect_text(rt, vnode);
            String rendered = style.render(content);
            screen.render_ansi_string((sz)area.x, (sz)area.y, rendered, xray::default_style(), (sz)(area.y + area.h));
        }

    } else if (type == "spinner") {
        String kind_str = props ? get_prop_string(rt, props, "kind") : "";
        pearls::SpinnerKind kind = pearls::SpinnerKind.DOTS;
        if (kind_str == "line")  kind = pearls::SpinnerKind.LINE;
        if (kind_str == "arrow") kind = pearls::SpinnerKind.ARROW;
        if (kind_str == "pulse") kind = pearls::SpinnerKind.PULSE;
        if (kind_str == "moon")  kind = pearls::SpinnerKind.MOON;

        lipgloss::Color fg = {};
        if (props) {
            String fg_str = get_prop_string(rt, props, "fg");
            if (fg_str.len > 0) fg = lipgloss::color_hex(fg_str);
        }

        pearls::SpinnerFrames fs = pearls::spinner_frames(kind);
        int frame = (int)((jsrt_now_ms() / (long)fs.interval_ms) % (long)fs.count);
        String frame_str = fs.frames[frame];
        if (fg.kind != lipgloss::ColorKind.NONE) {
            frame_str = lipgloss::new_style().foreground(fg).render(frame_str);
        }
        screen.render_ansi_string((sz)area.x, (sz)area.y, frame_str, xray::default_style());
        request_render_tick((long)fs.interval_ms);

    } else if (type == "textarea") {
        // Textarea: stateful component backed by pearls::Textarea
        // Props: id (required), focused (bool), placeholder (string),
        //        prompt (string prefix, default ""), show_line_numbers (bool, default false),
        //        border/fg/bg/pad/pad_x/pad_y/height — same as "box"
        String id = props ? get_prop_string(rt, props, "id") : "";
        if (id.len == 0) id = "_default";

        pearls::Textarea* ta = textarea_get_or_create(id);
        if (ta) {
            bool has_border = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
            int border_pad = has_border ? 2 : 0;
            int pad   = props ? get_prop_int(rt, props, "pad",   0) : 0;
            int pad_x = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
            int pad_y = props ? get_prop_int(rt, props, "pad_y", pad) : 0;

            // Inner area after border and padding
            int inner_w = area.w - border_pad - pad_x * 2;
            int inner_h = area.h - border_pad - pad_y * 2;
            if (inner_w < 1) inner_w = 1;
            if (inner_h < 1) inner_h = 1;

            ta.width  = inner_w;
            ta.height = inner_h;

            if (props) {
                String ph = get_prop_string(rt, props, "placeholder");
                if (ph.len > 0) ta.placeholder = ph;
                String prompt = get_prop_string(rt, props, "prompt");
                ta.prompt = prompt;
                ta.show_line_numbers = get_prop_bool(rt, props, "show_line_numbers");
                ta.focused = get_prop_bool(rt, props, "focused");

                String fg_str = get_prop_string(rt, props, "fg");
                if (fg_str.len > 0) {
                    lipgloss::Color fg_col = lipgloss::color_hex(fg_str);
                    ta.focused_style = lipgloss::new_style().foreground(fg_col);
                    ta.prompt_style  = lipgloss::new_style().foreground(fg_col);
                }
            }

            // Draw border frame (if any) by rendering an empty box of the full area size.
            // Then write ta.view() directly into the inner rect, bypassing lipgloss render()
            // so the content height is exactly what ta.view() produces (no padding/clipping issues).
            if (has_border || pad_x > 0 || pad_y > 0) {
                lipgloss::Style frame_style = props_to_style(rt, props);
                frame_style = frame_style.set_width(area.w - border_pad).set_height(area.h - border_pad);
                String frame = frame_style.render("");
                screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
            }
            // Write content lines directly into the inner rect
            xray::Rect inner = xray::new_rect(
                area.x + border_pad / 2 + pad_x,
                area.y + border_pad / 2 + pad_y,
                inner_w, inner_h);
            String content = ta.view();
            screen.render_ansi_string((sz)inner.x, (sz)inner.y, content, xray::default_style(), (sz)(inner.y + inner_h), (sz)(inner.x + inner_w));
        }

    } else if (type == "viewport") {
        // Viewport: stateful scrollable content area backed by pearls::Viewport.
        // Props: id (required), border/fg/bg/pad — same as box.
        // Children: string content (lines separated by \n).
        String id = props ? get_prop_string(rt, props, "id") : "";
        if (id.len == 0) id = "_vp_default";

        pearls::Viewport* vp = viewport_get_or_create(id);
        if (vp) {
            bool has_border = props && !rt.is_null(props) && get_prop_string(rt, props, "border").len > 0;
            int border_pad = has_border ? 2 : 0;
            int pad   = props ? get_prop_int(rt, props, "pad",   0) : 0;
            int pad_x = props ? get_prop_int(rt, props, "pad_x", pad) : 0;
            int pad_y = props ? get_prop_int(rt, props, "pad_y", pad) : 0;

            int inner_w = area.w - border_pad - pad_x * 2;
            int inner_h = area.h - border_pad - pad_y * 2;
            if (inner_w < 1) inner_w = 1;
            if (inner_h < 1) inner_h = 1;

            vp.width  = inner_w;
            vp.height = inner_h;

            // inner rect needed for child measurement below
            xray::Rect inner = xray::new_rect(
                area.x + border_pad / 2 + pad_x,
                area.y + border_pad / 2 + pad_y,
                inner_w, inner_h);

            // Collect only string (non-vnode) children as text content — vnode children are
            // rendered separately below and must not be included in the text stream.
            DString content_ds;
            content_ds.tinit();
            if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
                int cn = rt.array_length(children_arr);
                for (int ci = 0; ci < cn; ci++) {
                    void* ch = rt.array_item(children_arr, ci);
                    if (!ch) continue;
                    if (!is_vnode(rt, ch) && !rt.is_null(ch)) {
                        ZString cstr = jsrt_to_cstring(rt.ctx, ch);
                        if (cstr) { content_ds.append(cstr.str_view()); jsrt_free_cstring(rt.ctx, cstr); }
                    }
                    rt.free_value(ch);
                }
            }
            String content = content_ds.str_view();
            int text_line_count = 1;
            for (sz ci = 0; ci < content.len; ci++) {
                if (content[ci] == '\n') text_line_count++;
            }

            // Collect vnode children and measure each one's height at inner_w
            int vnode_child_count = 0;
            void*[16] vnode_children;
            int[16]   vnode_heights;
            if (children_arr && !rt.is_null(children_arr) && rt.is_array(children_arr)) {
                int cn = rt.array_length(children_arr);
                for (int ci = 0; ci < cn && vnode_child_count < 16; ci++) {
                    void* ch = rt.array_item(children_arr, ci);
                    if (ch && is_vnode(rt, ch)) {
                        // measure height: explicit height prop, else 1 for inline types, else measure
                        void* ch_props = rt.get_prop(ch, "type");
                        int h_explicit = 0;
                        void* cp = rt.get_prop(ch, "props");
                        if (cp && !rt.is_null(cp)) h_explicit = get_prop_int(rt, cp, "height", 0);
                        if (cp) rt.free_value(cp);
                        if (ch_props) rt.free_value(ch_props);
                        int ch_h;
                        if (h_explicit > 0) {
                            ch_h = h_explicit;
                        } else {
                            // use child_constraint in col mode to detect fixed-height types
                            xray::Constraint cc = child_constraint(rt, ch, true, inner);
                            if (cc.kind == xray::ConstraintKind.CLEN) {
                                ch_h = (int)cc.value;
                            } else {
                                ch_h = 1; // fill/fit defaults to 1 inside viewport
                            }
                        }
                        vnode_children[vnode_child_count] = ch;
                        vnode_heights[vnode_child_count]  = ch_h;
                        vnode_child_count++;
                    } else {
                        if (ch) rt.free_value(ch);
                    }
                }
            }

            int vnode_total_lines = 0;
            for (int vi = 0; vi < vnode_child_count; vi++) vnode_total_lines += vnode_heights[vi];
            int total_lines = text_line_count + vnode_total_lines;
            vp.set_content(total_lines);

            // Draw border frame
            if (has_border || pad_x > 0 || pad_y > 0) {
                lipgloss::Style frame_style = props_to_style(rt, props);
                frame_style = frame_style.set_width(area.w - border_pad).set_height(area.h - border_pad);
                String frame = frame_style.render("");
                screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
            }

            // Render visible lines into inner rect
            int start = vp.view_line_start();
            int end   = vp.view_line_end();

            // Walk text content to find the start line, then render each visible text line
            sz pos = 0;
            int cur_line = 0;
            while (pos < content.len && cur_line < start) {
                if (content[pos] == '\n') cur_line++;
                pos++;
            }
            for (int r = start; r < end && r < text_line_count; r++) {
                sz line_end = pos;
                while (line_end < content.len && content[line_end] != '\n') line_end++;
                String line = content[pos:line_end - pos];
                lipgloss::Style line_style = lipgloss::new_style();
                if (props) {
                    String fg_str = get_prop_string(rt, props, "fg");
                    if (fg_str.len > 0) line_style = line_style.foreground(lipgloss::color_hex(fg_str));
                }
                line_style = line_style.set_width(inner_w);
                String rendered_line = line_style.render(line);
                screen.render_ansi_string((sz)inner.x, (sz)(inner.y + r - start), rendered_line, xray::default_style(), 0, (sz)(inner.x + inner_w));
                pos = line_end + 1;
            }

            // Render vnode children that fall within the visible range (appended after text lines)
            int vnode_line = text_line_count;
            for (int vi = 0; vi < vnode_child_count; vi++) {
                int ch_h = vnode_heights[vi];
                int ch_end = vnode_line + ch_h;
                // visible if any part of this child overlaps [start, end)
                if (ch_end > start && vnode_line < end) {
                    int screen_y = inner.y + vnode_line - start;
                    int clip_h = ch_h;
                    // clip to inner rect
                    if (screen_y < inner.y) { clip_h -= inner.y - screen_y; screen_y = inner.y; }
                    if (screen_y + clip_h > inner.y + inner_h) clip_h = inner.y + inner_h - screen_y;
                    if (clip_h > 0) {
                        void* ch_props = rt.get_prop(vnode_children[vi], "props");
                        int ch_w = ch_props ? get_prop_int(rt, ch_props, "width", inner_w) : inner_w;
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
        lipgloss::Style style = props_to_style(rt, props);
        String content = collect_text(rt, vnode);
        String rendered = style.render(content);
        screen.render_ansi_string((sz)area.x, (sz)area.y, rendered, xray::default_style(), (sz)(area.y + area.h));

    } else if (type == "draw") {
        // draw: calls a JS function fn(width, height) -> string for each row in the rect.
        // If props.fn is a function, call it once per visible row with (row_width, row_index).
        if (props && !rt.is_null(props)) {
            void* fn_val = rt.get_prop(props, "fn");
            if (fn_val && !rt.is_null(fn_val) && rt.is_function(fn_val)) {
                void* undef = null; // null this
                for (int r = 0; r < area.h; r++) {
                    void* w_arg = rt.new_int32(area.w);
                    void* r_arg = rt.new_int32(r);
                    void* result = rt.call2(fn_val, undef, w_arg, r_arg);
                    if (w_arg) rt.free_value(w_arg);
                    if (r_arg) rt.free_value(r_arg);
                    if (result && !rt.is_null(result)) {
                        ZString cstr = jsrt_to_cstring(rt.ctx, result);
                        if (cstr) {
                            screen.render_ansi_string((sz)area.x, (sz)(area.y + r), cstr.str_view(), xray::default_style());
                            jsrt_free_cstring(rt.ctx, cstr);
                        }
                        rt.free_value(result);
                    }
                }
            }
            if (fn_val) rt.free_value(fn_val);
        }
    }

    if (props) rt.free_value(props);
    if (children_arr) rt.free_value(children_arr);
}
