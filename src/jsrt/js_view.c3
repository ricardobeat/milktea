module jsrt;
import xray;
import lipgloss;
import pearls;
import std::io;
import std::core::mem;

// One spinner instance per SpinnerKind, lazily advanced by time.
struct SpinnerSlot {
    pearls::Spinner spinner;
    long            last_ms;   // last time frame was advanced
    bool            init;
}
SpinnerSlot[5] _spinner_slots;

fn pearls::Spinner* get_spinner(pearls::SpinnerKind kind, lipgloss::Color fg) @local {
    int idx = (int)kind;
    SpinnerSlot* slot = &_spinner_slots[idx];
    if (!slot.init) {
        slot.spinner = pearls::new_spinner(kind).with_color(fg);
        slot.last_ms = 0;
        slot.init    = true;
    } else {
        slot.spinner.fg = fg;
    }
    // Advance frame based on elapsed time
    pearls::SpinnerFrames fs = pearls::spinner_frames(kind);
    long now = (long)jsrt_now_ms();
    if (now - slot.last_ms >= (long)fs.interval_ms) {
        slot.spinner.advance();
        slot.last_ms = now;
    }
    return &slot.spinner;
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

    int pad = get_prop_int(rt, props, "pad", 0);
    int pad_x = get_prop_int(rt, props, "pad_x", pad);
    int pad_y = get_prop_int(rt, props, "pad_y", pad);
    if (pad > 0 || pad_x > 0 || pad_y > 0) {
        s = s.padding(pad_y, pad_x, pad_y, pad_x);
    }

    // width/height are outer dimensions; set_width/set_height control inner content size.
    // Subtract border overhead (1 char per side = 2 total) so the rendered block fits the rect.
    int border_pad = has_border ? 2 : 0;

    int w = get_prop_int(rt, props, "width", 0);
    if (w > 0) s = s.set_width(w - border_pad > 0 ? w - border_pad : 1);

    int h = get_prop_int(rt, props, "height", 0);
    if (h > 0) s = s.set_height(h - border_pad > 0 ? h - border_pad : 1);

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
    rt.free_value(props);

    if (size > 0) return xray::constraint_len(size);

    if (is_col && is_vnode(rt, child)) {
        void* type_prop = rt.get_prop(child, "type");
        bool measurable = false;
        if (type_prop && !rt.is_null(type_prop) && rt.is_string(type_prop)) {
            ZString ts = jsrt_to_cstring(rt.ctx, type_prop);
            if (ts) {
                String t = ts.str_view();
                measurable = t == "box" || t == "text";
                jsrt_free_cstring(rt.ctx, ts);
            }
        }
        if (type_prop) rt.free_value(type_prop);

        if (measurable) {
            // Only CFIT when the vnode explicitly opts in with fit:true
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

// render_vnode walks a vnode tree, filling screen with content in area
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
            // Draw border frame via lipgloss on empty content, then recurse into inner rect
            int inner_w = area.w - border_pad;
            int inner_h = area.h - border_pad;
            if (inner_w < 1) inner_w = 1;
            if (inner_h < 1) inner_h = 1;
            style = style.set_width(inner_w).set_height(inner_h);
            String frame = style.render("");
            screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style(), (sz)(area.y + area.h));
            // Inner rect sits 1 cell inside the border on each side
            xray::Rect inner = xray::new_rect(area.x + border_pad / 2, area.y + border_pad / 2, inner_w, inner_h);
            // Treat children as a col container
            int n = rt.array_length(children_arr);
            if (n > 0 && n <= 64) {
                xray::Constraint[64] cs;
                xray::Rect[64] rects;
                for (int i = 0; i < n; i++) {
                    void* ch = rt.array_item(children_arr, i);
                    cs[i] = ch ? child_constraint(rt, ch, false, inner) : xray::constraint_fill(1);
                    if (ch) rt.free_value(ch);
                }
                int computed = xray::layout_h_gap(inner, cs[0:n], 0, rects[0:n]);
                for (int i = 0; i < computed; i++) {
                    void* ch = rt.array_item(children_arr, i);
                    if (ch) { render_vnode(rt, ch, screen, rects[i]); rt.free_value(ch); }
                }
            }
        } else {
            // All-text path: collect and render via lipgloss
            if (get_prop_int(rt, props, "width", 0) == 0) {
                int inner_w = area.w - border_pad;
                style = style.set_width(inner_w > 0 ? inner_w : 1);
            }
            if (get_prop_int(rt, props, "height", 0) == 0) {
                int inner_h = area.h - border_pad;
                style = style.set_height(inner_h > 0 ? inner_h : 1);
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

        pearls::Spinner* sp = get_spinner(kind, fg);
        String frame = sp.view();
        screen.render_ansi_string((sz)area.x, (sz)area.y, frame, xray::default_style());

    } else if (type == "text") {
        lipgloss::Style style = props_to_style(rt, props);
        String content = collect_text(rt, vnode);
        String rendered = style.render(content);
        screen.render_ansi_string((sz)area.x, (sz)area.y, rendered, xray::default_style(), (sz)(area.y + area.h));
    }

    if (props) rt.free_value(props);
    if (children_arr) rt.free_value(children_arr);
}
