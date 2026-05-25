module textinputs;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

struct InputsModel {
	boba::TextInput[3] inputs;
	int focus;
	bool submitted;
	int width;
	int height;
	int cursor_blink;
}

fn milktea::Cmd InputsModel.init(InputsModel* self) @dynamic {
	self.inputs[0] = boba::new_text_input().with_placeholder("Nickname");
	self.inputs[0].focused = true;
	self.inputs[1] = boba::new_text_input().with_placeholder("Email");
	self.inputs[2] = boba::new_text_input().with_placeholder("Password").with_password();
	return milktea::tick(500, &on_blink);
}

fn milktea::Msg on_blink() {
	return { .kind = milktea::MsgKind.USER, .tag = 10 };
}

fn milktea::Cmd InputsModel.update(InputsModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind == milktea::MsgKind.USER && msg.tag == 10) {
		self.cursor_blink = 1 - self.cursor_blink;
		return milktea::tick(500, &on_blink);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.TAB:
			self.inputs[self.focus].focused = false;
			if (k.shift) {
				self.focus--;
				if (self.focus < 0) self.focus = 2;
			} else {
				self.focus = (self.focus + 1) % 3;
			}
			self.inputs[self.focus].focused = true;
		case milktea::KeyCode.UP:
			self.inputs[self.focus].focused = false;
			self.focus = (self.focus - 1 + 3) % 3;
			self.inputs[self.focus].focused = true;
		case milktea::KeyCode.DOWN:
			self.inputs[self.focus].focused = false;
			self.focus = (self.focus + 1) % 3;
			self.inputs[self.focus].focused = true;
		case milktea::KeyCode.ENTER:
			if (self.focus < 2) {
				self.inputs[self.focus].focused = false;
				self.focus++;
				self.inputs[self.focus].focused = true;
			} else {
				self.submitted = true;
				return milktea::quit();
			}
		case milktea::KeyCode.ESC:
			return milktea::quit();
		default:
	}
	if (self.inputs[self.focus].handle_key(k)) return null;
	return null;
}

fn milktea::View InputsModel.view(InputsModel* self) @dynamic {
	glaze::Style title = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true)
		.padding(0, 0, 1, 0);
	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title.render("Sign Up"));
	out.append_char('\n');
	out.append_char('\n');

	String[3] labels  = { "Nickname:", "Email:", "Password:" };
	int[3] label_cols = { 10, 7, 10 };

	int base_row = 3;

	int cursor_x = 0;
	int cursor_y = 0;

	for (int i = 0; i < 3; i++) {
		out.append_string(labels[i]);
		out.append_char(' ');

		if (i == self.focus) {
			cursor_y = base_row + i;
			cursor_x = label_cols[i] + self.inputs[i].cursor_col();
		}

		out.append_string(self.inputs[i].view());
		out.append_char('\n');
	}

	out.append_char('\n');

	if (self.focus == 2) {
		glaze::Style btn = glaze::new_style().foreground(glaze::color_hex("#ffffff"))
			.background(glaze::color_hex("#00d7ff"))
			.padding(0, 2, 0, 2)
			.set_bold(true);
		out.append_string(btn.render(" Submit "));
	} else {
		glaze::Style btn = glaze::new_style().foreground(glaze::color_hex("#888888")).padding(0, 2, 0, 2);
		out.append_string(btn.render(" Submit "));
	}
	out.append_char('\n');
	out.append_char('\n');
	out.append_string(hint.render("TAB/Shift+TAB switch | ENTER submit | ESC quit"));

	milktea::View v = milktea::new_alt_screen_view(out.str_view());
	v.has_cursor = true;
	v.cursor = milktea::new_cursor(cursor_x, cursor_y);
	return v;
}

fn int main() {
	InputsModel m = { };

	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	if (m.submitted) {
		io::printfn("Submitted!");
		io::printfn("  Nickname: %s", m.inputs[0].text());
		io::printfn("  Email: %s", m.inputs[1].text());
		io::printfn("  Password: %s", m.inputs[2].text());
	} else {
		io::printn("Cancelled.");
	}
	return 0;
}