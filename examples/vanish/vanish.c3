module vanish;

import tea;
import std::io;

struct VanishModel {
    bool quitting;
}

fn tea::Cmd VanishModel.init(VanishModel* self) @dynamic {
    return null;
}

fn tea::Cmd VanishModel.update(VanishModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.KEY) {
        self.quitting = true;
        return tea::quit();
    }
    return null;
}

fn String VanishModel.view(VanishModel* self) @dynamic {
    if (self.quitting) return "";
    return "Press any key to quit. Your terminal will be clean.";
}

fn int main() {
    VanishModel m = {};
    tea::enter_alt_screen();

    if (catch err = tea::run((tea::Model)&m)) {
        tea::exit_alt_screen();
        io::printfn("Error: %s", err);
        return 1;
    }

    tea::exit_alt_screen();
    // Nothing printed after exit — terminal is clean
    return 0;
}