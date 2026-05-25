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

fn tea::View VanishModel.view(VanishModel* self) @dynamic {
	if (self.quitting) return tea::new_alt_screen_view("");
	return tea::new_alt_screen_view("Press any key to quit. Your terminal will be clean.");
}

fn int main() {
	VanishModel m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	// Nothing printed after exit — terminal is clean
	return 0;
}