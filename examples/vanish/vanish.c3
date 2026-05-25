module vanish;

import milktea;
import std::io;

struct VanishModel {
	bool quitting;
}

fn milktea::Cmd VanishModel.init(VanishModel* self) @dynamic {
	return null;
}

fn milktea::Cmd VanishModel.update(VanishModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.KEY) {
		self.quitting = true;
		return milktea::quit();
	}
	return null;
}

fn milktea::View VanishModel.view(VanishModel* self) @dynamic {
	if (self.quitting) return milktea::new_alt_screen_view("");
	return milktea::new_alt_screen_view("Press any key to quit. Your terminal will be clean.");
}

fn int main() {
	VanishModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	// Nothing printed after exit — terminal is clean
	return 0;
}