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
}

fn milktea::Cmd InputsModel.init(InputsModel* self) @dynamic {
	self.inputs[0] = boba::new_text_input().with_placeholder("Nickname");
	self.inputs[0].focused = true;
	self.inputs[1] = boba::new_text_input().with_placeholder("Email");
	self.inputs[2] = boba::new_text_input().with_placeholder("Password").with_password();
	// No blink timer: the terminal blinks its own cursor, and the layout
	// tells it where to sit.
	return null;
}

fn milktea::Cmd InputsModel.update(InputsModel* self, milktea::Msg msg) @dynamic {
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

const String[3] LABELS = { "Nickname:", "Email:", "Password:" };

// Rows the form leaves between its parts: after the title, before the button,
// and before the hint line.
const int SECTION_GAP = 1;
// Columns between a label and its input.
const int LABEL_GAP = 1;

fn milktea::View InputsModel.view(InputsModel* self) @dynamic {
	glaze::Style title_s = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	glaze::Style label_s = glaze::style().align(glaze::Position.LEFT, glaze::Position.TOP);
	glaze::Style hint_s  = glaze::style().foreground(glaze::color_hex("#666666"));

	milktea::Node* form = milktea::vstack();
	for (int i = 0; i < 3; i++) {
		self.inputs[i].focused = i == self.focus;
		form.add(milktea::hstack()
			.height(milktea::cells(1))
			.with_gap(LABEL_GAP)
			.add(milktea::text(label_s, LABELS[i]).width(milktea::cells(label_cols())))
			.add(self.inputs[i].node().fill(1)));
	}

	glaze::Style btn_s = self.focus == 2
		? glaze::style().foreground(glaze::color_hex("#ffffff"))
			.background(glaze::color_hex("#00d7ff")).with_bold(true)
		: glaze::style().foreground(glaze::color_hex("#888888"));

	return milktea::draw(milktea::root()
		.add(milktea::vstack()
			.with_gap(SECTION_GAP)
			.add(milktea::text(title_s, "Sign Up").height(milktea::cells(1)))
			.add(form.height(milktea::cells(3)))
			.add(milktea::text(btn_s, "  Submit  ").height(milktea::cells(1)))
			.add(milktea::text(hint_s, "TAB/Shift+TAB switch | ENTER submit | ESC quit")
				.height(milktea::cells(1)))));
}

// label_cols is the width of the label column: the longest label, so the
// inputs line up without anyone counting characters.
fn int label_cols() {
	int widest = 0;
	foreach (l : LABELS) {
		int w = glaze::string_width(l);
		if (w > widest) widest = w;
	}
	return widest;
}

fn int main() {
	InputsModel m = { };
	milktea::@run(&m);
	return 0;
}