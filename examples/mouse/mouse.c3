module mouse;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct Model {
	int width;
	int height;
	int mouse_row;
	int mouse_col;
	milktea::MouseButton last_button;
	milktea::MouseAction last_action;
	bool dragging;
	String[32] trail;
	int trail_count;
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.mouse_row = 0;
	self.mouse_col = 0;
	self.last_button = milktea::MouseButton.MOUSE_NONE;
	self.last_action = milktea::MouseAction.MOUSE_PRESS;
	self.dragging = false;
	self.trail_count = 0;
	return null;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.MOUSE) {
		self.mouse_row = msg.mouse.row;
		self.mouse_col = msg.mouse.col;
		self.last_button = msg.mouse.button;
		self.last_action = msg.mouse.action;
		if (msg.mouse.action == milktea::MouseAction.MOUSE_PRESS && msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
			self.dragging = true;
			if (self.trail_count < self.trail.len) {
				self.trail[self.trail_count] = string::tformat("(%d,%d)", msg.mouse.col, msg.mouse.row);
				self.trail_count++;
			}
		}
		if (msg.mouse.action == milktea::MouseAction.MOUSE_RELEASE) {
			self.dragging = false;
		}
		if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION && self.dragging) {
			if (self.trail_count < self.trail.len) {
				self.trail[self.trail_count] = string::tformat("(%d,%d)", msg.mouse.col, msg.mouse.row);
				self.trail_count++;
			}
		}
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'c') {
				self.trail_count = 0;
			}
		default:
	}
	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);

	glaze::Style info_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff"));

	glaze::Style hint_style = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_style.render("Mouse Event Viewer"));
	out.append_string("\n\n");

	String button_name = "none";
	switch (self.last_button) {
		case milktea::MouseButton.MOUSE_LEFT: { button_name = "left"; }
		case milktea::MouseButton.MOUSE_MIDDLE: { button_name = "middle"; }
		case milktea::MouseButton.MOUSE_RIGHT: { button_name = "right"; }
		default: { }
	}

	String action_name = "press";
	switch (self.last_action) {
		case milktea::MouseAction.MOUSE_PRESS: { action_name = "press"; }
		case milktea::MouseAction.MOUSE_RELEASE: { action_name = "release"; }
		case milktea::MouseAction.MOUSE_MOTION: { action_name = "motion"; }
		default: { }
	}

	out.append_string(info_style.render(string::tformat("Position: (%d, %d)", self.mouse_col, self.mouse_row)));
	out.append_char('\n');
	out.append_string(info_style.render(string::tformat("Button: %s  Action: %s", button_name, action_name)));
	out.append_char('\n');
	out.append_string(info_style.render(string::tformat("Dragging: %s", self.dragging ? "yes" : "no")));
	out.append_char('\n');

	if (self.trail_count > 0) {
		out.append_char('\n');
		out.append_string(title_style.render("Click Trail:"));
		out.append_char('\n');
		for (int i = 0; i < self.trail_count; i++) {
			out.append_string(self.trail[i]);
			if (i < self.trail_count - 1) {
				out.append_string(" -> ");
			}
		}
	}

	out.append_string("\n\n");
	out.append_string(hint_style.render("Click/drag to track  |  c to clear  |  q to quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	Model m = { };
	milktea::enter_alt_screen();
	milktea::enable_mouse();

	if (catch err = milktea::@run_program(&m)) {
		milktea::disable_mouse();
		io::printfn("Error: %s", err);
		return 1;
	}

	milktea::disable_mouse();
	io::printn("Bye!");
	return 0;
}