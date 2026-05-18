module jsrt;
import tea;
import xray;
import lipgloss;
import std::io;

struct JsModel {
    Runtime rt;
    void* js_model_obj;
    int term_w;
    int term_h;
}

// Requested tick delay from the last render pass. -1 means no tick requested.
// Components call request_render_tick() during render_vnode to register a wakeup.
long g_render_tick_ms = -1;

fn void request_render_tick(long delay_ms) {
    if (g_render_tick_ms < 0 || delay_ms < g_render_tick_ms) {
        g_render_tick_ms = delay_ms;
    }
}

fn tea::Cmd JsModel.init(&self) @dynamic {
    void* fn_val = self.rt.get_prop(self.js_model_obj, "init");
    if (fn_val != null) {
        if (self.rt.is_function(fn_val)) {
            void* result = self.rt.call0(fn_val, self.js_model_obj);
            self.rt.execute_jobs();
            if (result != null) self.rt.free_value(result);
        }
        self.rt.free_value(fn_val);
    }
    return self.js_tick_cmd();
}

fn tea::Cmd JsModel.update(&self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.MOUSE) return self.js_tick_cmd();

    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.term_w = msg.window_size.width;
        self.term_h = msg.window_size.height;
    }

    // On every tick, run timers and drain fetch responses
    if (msg.kind == tea::MsgKind.TICK) {
        self.rt.run_timers();
        self.rt.drain_fetch();
        // If a timer/fetch callback called tea.quit(), honor it
        void* quit_flag = self.rt.get_global_prop("__jsrt_quit");
        bool should_quit = quit_flag != null && !self.rt.is_null(quit_flag) && self.rt.to_string(quit_flag) == "true";
        if (quit_flag != null) self.rt.free_value(quit_flag);
        if (should_quit) return tea::quit();
    }

    // If there's a pending JS error, only allow esc/q to quit (clears error and quits)
    ZString pending_err = jsrt_last_error();
    if (pending_err) {
        if (msg.kind == tea::MsgKind.KEY) {
            tea::KeyMsg k = msg.key;
            bool is_quit = k.code == tea::KeyCode.ESC
                || (k.code == tea::KeyCode.RUNE && k.rune == 'q');
            if (is_quit) {
                jsrt_clear_error();
                return tea::quit();
            }
        }
        return self.js_tick_cmd();
    }

    void* fn_val = self.rt.get_prop(self.js_model_obj, "update");
    if (fn_val == null || !self.rt.is_function(fn_val)) {
        if (fn_val != null) self.rt.free_value(fn_val);
        return self.js_tick_cmd();
    }

    void* js_msg = msg_to_js(&self.rt, msg);
    void* result = self.rt.call1(fn_val, self.js_model_obj, js_msg);
    self.rt.free_value(fn_val);
    self.rt.free_value(js_msg);
    self.rt.execute_jobs();

    tea::Cmd cmd = js_value_to_cmd(&self.rt, result);
    if (cmd != null) return cmd;
    return self.js_tick_cmd();
}

// js_tick_cmd schedules the next tick based on JS runtime state and render requests.
// Returns null (idle) when nothing needs a wakeup.
fn tea::Cmd JsModel.js_tick_cmd(&self) @inline {
    if (self.rt.is_job_pending()) return tea::tick(1);
    if (self.rt.has_pending_fetch()) return tea::tick(1);
    long next_ms = self.rt.next_timer_ms();
    // Take the minimum of JS timer deadline and render-requested tick
    if (g_render_tick_ms >= 0) {
        if (next_ms < 0 || g_render_tick_ms < next_ms) next_ms = g_render_tick_ms;
    }
    if (next_ms < 0) return null;
    sz delay = next_ms < 1 ? 1 : (sz)next_ms;
    return tea::tick(delay);
}

fn tea::View JsModel.view(&self) @dynamic {
    int w = self.term_w > 0 ? self.term_w : 80;
    int h = self.term_h > 0 ? self.term_h : 24;

    void* fn_val = self.rt.get_prop(self.js_model_obj, "view");
    void* result = null;
    if (fn_val != null && self.rt.is_function(fn_val)) {
        result = self.rt.call0(fn_val, self.js_model_obj);
        self.rt.free_value(fn_val);
    } else {
        if (fn_val != null) self.rt.free_value(fn_val);
    }

    // vnode path: walk the tree, fill a ScreenBuffer, return cell view
    // Always use screen buffer so we can overlay errors on top
    xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);
    xray::Rect area = xray::new_rect(0, 0, w, h);

    if (result != null && is_vnode(&self.rt, result)) {
        g_render_tick_ms = -1;
        render_vnode(&self.rt, result, screen, area);
        self.rt.free_value(result);
    } else if (result != null) {
        // string path (legacy): render as text into screen buffer
        ZString cstr = jsrt_to_cstring(self.rt.ctx, result);
        self.rt.free_value(result);
        if (cstr) {
            String content = string::tformat("%s", cstr.str_view());
            jsrt_free_cstring(self.rt.ctx, cstr);
            screen.render_ansi_string(0, 0, content, xray::default_style());
        }
    }

    // Error overlay: always render last JS error as a red bordered box at the bottom
    ZString err = jsrt_last_error();
    if (err) {
        String err_str = err.str_view();
        lipgloss::Style err_style = lipgloss::new_style()
            .set_border(lipgloss::rounded_border())
            .set_border_fg(lipgloss::color_hex("#ff0000"))
            .foreground(lipgloss::color_hex("#ff6666"))
            .set_width(w - 2);
        String rendered = err_style.render(err_str);
        int line_count = 1;
        for (sz i = 0; i < rendered.len; i++) {
            if (rendered[i] == '\n') line_count++;
        }
        int overlay_y = h - line_count;
        if (overlay_y < 0) overlay_y = 0;
        screen.render_ansi_string(1, (sz)overlay_y, rendered, xray::default_style());
    }

    tea::View view = tea::new_alt_cell_view(screen.cells[0:screen.width * screen.height], screen.width, screen.height);
    screen.destroy();
    mem::free(screen);
    return view;
}

fn void JsModel.on_destroy(&self) @dynamic {
    self.rt.free_value(self.js_model_obj);
    self.rt.free();
}

fn JsModel? load_js_model(String js_src, String filename = "<input>") {
    Runtime rt = jsrt::new_runtime()!;

    jsrt_fetch_init();
    rt.register_globals();

    // Always evaluate tea.js as a global script first — sets up globalThis.tea,
    // globalThis.h, console, setInterval, etc. The "tea" ES module re-exports
    // these same objects, so both script and module users share one instance.
    String stdlib_str = (String)$embed("tea.js");
    if (!rt.eval(stdlib_str)) {
        rt.free();
        return JS_ERROR~;
    }

    bool ok;
    if (rt.is_module(js_src)) {
        ok = rt.eval_module(js_src, filename);
    } else {
        ok = rt.eval(js_src);
    }
    if (!ok) {
        rt.free();
        return JS_ERROR~;
    }

    // Module-mode scripts call tea.run(model) which sets globalThis.__jsrt_model,
    // same as script mode — the global object is shared.
    void* model_obj = rt.get_global_prop("__jsrt_model");
    if (model_obj == null || rt.is_null(model_obj)) {
        if (model_obj != null) rt.free_value(model_obj);
        io::eprintfn("jsrt: script did not call tea.run(model)");
        rt.free();
        return JS_ERROR~;
    }

    return { .rt = rt, .js_model_obj = model_obj };
}
