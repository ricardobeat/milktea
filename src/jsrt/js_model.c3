module jsrt;
import tea;
import xray;
import std::io;

struct JsModel {
    Runtime rt;
    void* js_model_obj;
    int term_w;
    int term_h;
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
    // Start the 60fps tick loop
    return tea::tick();
}

fn tea::Cmd JsModel.update(&self, tea::Msg msg) @dynamic {
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

    void* fn_val = self.rt.get_prop(self.js_model_obj, "update");
    if (fn_val == null || !self.rt.is_function(fn_val)) {
        if (fn_val != null) self.rt.free_value(fn_val);
        if (msg.kind == tea::MsgKind.TICK) return tea::tick();
        return null;
    }

    void* js_msg = msg_to_js(&self.rt, msg);
    void* result = self.rt.call1(fn_val, self.js_model_obj, js_msg);
    self.rt.free_value(fn_val);
    self.rt.free_value(js_msg);
    self.rt.execute_jobs();

    tea::Cmd cmd = js_value_to_cmd(&self.rt, result);
    // Keep the tick loop alive unless quitting
    if (msg.kind == tea::MsgKind.TICK && cmd == null) return tea::tick();
    return cmd;
}

fn tea::View JsModel.view(&self) @dynamic {
    void* fn_val = self.rt.get_prop(self.js_model_obj, "view");
    if (fn_val == null || !self.rt.is_function(fn_val)) {
        if (fn_val != null) self.rt.free_value(fn_val);
        return tea::new_view("");
    }

    void* result = self.rt.call0(fn_val, self.js_model_obj);
    self.rt.free_value(fn_val);
    if (!result) return tea::new_view("");

    // vnode path: walk the tree, fill a ScreenBuffer, return cell view
    if (is_vnode(&self.rt, result)) {
        int w = self.term_w > 0 ? self.term_w : 80;
        int h = self.term_h > 0 ? self.term_h : 24;
        xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);
        xray::Rect area = xray::new_rect(0, 0, w, h);
        render_vnode(&self.rt, result, screen, area);
        self.rt.free_value(result);
        tea::View view = tea::new_alt_cell_view(screen.cells[0:screen.width * screen.height], screen.width, screen.height);
        screen.destroy();
        mem::free(screen);
        return view;
    }

    // string path (legacy): return raw string view
    ZString cstr = jsrt_to_cstring(self.rt.ctx, result);
    self.rt.free_value(result);
    if (!cstr) return tea::new_view("");
    String temp_content = string::tformat("%s", cstr.str_view());
    jsrt_free_cstring(self.rt.ctx, cstr);
    return tea::new_view(temp_content);
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
