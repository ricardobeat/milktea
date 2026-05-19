module jsrt_main;

import tea;
import jsrt;
import std::io;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: jsrt [--debug] <script.js>");
        return 1;
    }

    // Parse --debug flag from args
    bool debug = false;
    int script_idx = 1;
    for (int i = 1; i < args.len; i++) {
        if (args[i] == "--debug") {
            debug = true;
        } else {
            script_idx = i;
        }
    }

    char[]? src_opt = file::load_temp(args[script_idx]);
    if (catch err = src_opt) {
        io::eprintfn("Error loading '%s': %s", args[script_idx], err);
        return 1;
    }

    JsModel? model_opt = jsrt::load_js_model((String)src_opt, args[script_idx]);
    if (catch err = model_opt) {
        io::eprintfn("Error loading JavaScript model: %s", err);
        return 1;
    }

    JsModel model = model_opt;

    // Inject __debug flag into JS globalThis before Run()
    if (debug) {
        model.rt.eval("globalThis.__debug = true");
    }

    tea::Program p = tea::@program(&model);
    p.debug = debug;
    if (catch err = p.run()) {
        io::eprintfn("Runtime error: %s", err);
        return 1;
    }

    return 0;
}
