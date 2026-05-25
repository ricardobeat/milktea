module file_picker;

import milktea;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_CLEAR_ERROR = 1;

struct PickerModel {
	boba::FilePicker fp;
	int width;
	int height;
	bool has_error;
	String error_msg;
}

fn milktea::Msg on_clear_error() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_CLEAR_ERROR };
}

fn milktea::Cmd show_error(PickerModel* self, String msg) {
	self.has_error = true;
	self.error_msg = msg;
	return milktea::tick(2000, &on_clear_error);
}

fn milktea::Cmd PickerModel.init(PickerModel* self) @dynamic {
	self.fp = boba::new_file_picker(".");
	self.fp.load_dir(".");
	return null;
}

fn milktea::Cmd PickerModel.update(PickerModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		self.fp.width = self.width;
		self.fp.height = self.height;
		return null;
	}
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_CLEAR_ERROR) {
		self.has_error = false;
		self.error_msg = "";
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}

	if (self.fp.handle_key(k)) {
		if (self.fp.selected.len > 0) return milktea::quit();
		return null;
	}

	return null;
}

fn milktea::View PickerModel.view(PickerModel* self) @dynamic {
	DString out = dstring::temp();

	if (self.has_error) {
		out.append_string(self.error_msg);
		out.append_char('\n');
	}

	out.append_string(self.fp.view());
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	PickerModel m = { };
	if (catch err = milktea::@run_program(&m)) {
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