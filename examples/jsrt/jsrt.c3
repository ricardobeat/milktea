module jsrt_main;

import tea;
import jsrt;
import std::io;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: jsrt <script.js>");
        return 1;
    }

    char[]? src_opt = file::load_temp(args[1]);
    if (catch err = src_opt) {
        io::eprintfn("Error loading '%s': %s", args[1], err);
        return 1;
    }

    JsModel? model_opt = jsrt::load_js_model((String)src_opt, args[1]);
    if (catch err = model_opt) {
        io::eprintfn("Error loading JavaScript model: %s", err);
        return 1;
    }

    JsModel model = model_opt;
    if (catch err = tea::@run_program(&model)) {
        io::eprintfn("Runtime error: %s", err);
        return 1;
    }

    return 0;
}
