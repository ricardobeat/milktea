module file_picker;

import tea;
import pearls;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_CLEAR_ERROR = 1;

struct PickerModel {
    pearls::FilePicker fp;
    int width;
    int height;
    bool has_error;
    String error_msg;
}

fn tea::Msg on_clear_error() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_CLEAR_ERROR };
}

fn tea::Cmd show_error(PickerModel* self, String msg) {
    self.has_error = true;
    self.error_msg = msg;
    return tea::tick(2000, &on_clear_error);
}

fn tea::Cmd PickerModel.init(PickerModel* self) @dynamic {
    self.fp = pearls::new_file_picker(".");
    self.fp.load_dir(".");
    return null;
}

fn tea::Cmd PickerModel.update(PickerModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        self.fp.width = self.width;
        self.fp.height = self.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_CLEAR_ERROR) {
        self.has_error = false;
        self.error_msg = "";
        return null;
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
    }

    if (self.fp.handle_key(k)) {
        if (self.fp.selected.len > 0) return tea::quit();
        return null;
    }

    return null;
}

fn tea::View PickerModel.view(PickerModel* self) @dynamic {
    DString out = dstring::temp();

    if (self.has_error) {
        out.append_string(self.error_msg);
        out.append_char('\n');
    }

    out.append_string(self.fp.view());
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    PickerModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    if (m.fp.selected.len > 0) {
        io::printfn("Selected: %s", m.fp.selected);
    } else {
        io::printn("No file selected.");
    }
    return 0;
}
