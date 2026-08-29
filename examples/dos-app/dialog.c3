module dos_app;

import milktea;
import glaze;
import xray;

// A modal dialog: a centered panel with a title, a body, and a row of buttons
// along the bottom. It owns which button is focused and reports which one was
// pressed, so the app does not track the selection itself.

const int DIALOG_BUTTONS = 2;

struct Dialog {
	String title;
	String body;
	Button[DIALOG_BUTTONS] buttons;
	int focused;
	bool open;

	// Narrowest the panel will be. It grows past this to fit its content;
	// without a floor a short message would give a cramped dialog.
	int min_cols;
}

// Pressed is what handle_key reports: nothing yet, dismissed without choosing,
// or a button was pressed — which one is `focused`.
enum Pressed {
	NOTHING,
	DISMISSED,
	CONFIRMED,
}

fn Dialog new_dialog(String title, String body, String ok, String cancel) {
	return {
		.title = title,
		.body = body,
		.buttons = { new_button(ok), new_button(cancel) },
		.min_cols = 40,
	};
}

fn void Dialog.show(&self) {
	self.open = true;
	self.focused = 0;
}

fn Pressed Dialog.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return Pressed.NOTHING;

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			return Pressed.DISMISSED;
		case milktea::KeyCode.LEFT:
		case milktea::KeyCode.RIGHT:
		case milktea::KeyCode.TAB:
			self.focused = (self.focused + 1) % DIALOG_BUTTONS;
		case milktea::KeyCode.ENTER:
			self.open = false;
			return Pressed.CONFIRMED;
		default:
	}
	return Pressed.NOTHING;
}

// node returns the dialog, or null when it is closed, so the caller can add it
// unconditionally.
fn xray::Node* Dialog.node(&self) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = glaze::color_hex(C_DARK), .fg = glaze::color_hex(C_WHITE),
		.border = glaze::DOUBLE, .border_color = glaze::color_hex(C_YELLOW),
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
		.align_h = glaze::Position.CENTER, .align_v = glaze::Position.CENTER,
	};
	glaze::Style title_s = { .fg = glaze::color_hex(C_YELLOW), .bold = true };

	String[DIALOG_BUTTONS] rendered;
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		rendered[i] = self.buttons[i].with_focus(i == self.focused).view();
	}
	String buttons = glaze::join_horizontal_arr(glaze::Position.CENTER, rendered[..], 2);

	String inner = glaze::join_vertical_arr(glaze::Position.LEFT, {
		title_s.render(self.title), "", self.body, "", buttons,
	});

	// center() fits the panel to its content on both axes, so the dialog is
	// exactly as big as what it holds. Only the floor is stated here.
	return milktea::text(panel, inner)
		.width(milktea::at_least(self.min_cols))
		.center()
		.shadow(milktea::shadow(2, 1));
}
