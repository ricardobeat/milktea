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

	// Set by a button's on_click (see ButtonSlot/button_clicked) or the
	// backdrop's on_click_outside; update() reads and clears it once per
	// frame — the click path's version of what handle_key returns directly.
	Pressed pending;

	ButtonSlot[DIALOG_BUTTONS] button_slots;
}

// Pressed is what handle_key reports: nothing yet, dismissed without choosing,
// or a button was pressed — which one is `focused`.
enum Pressed {
	NOTHING,
	DISMISSED,
	CONFIRMED,
}

// ButtonSlot is the on_click context for one dialog button: which index, and
// a back-pointer to the Dialog. Lives inside Dialog (not the per-frame node
// tree) so its address survives past the frame that registered it — see
// Menu's TitleSlot/ItemSlot for the same pattern.
struct ButtonSlot {
	Dialog* dialog;
	int index;
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

// take_pending returns and clears whatever a mouse click reported since the
// last call — the click path's counterpart to handle_key's return value.
fn Pressed Dialog.take_pending(&self) {
	Pressed p = self.pending;
	self.pending = Pressed.NOTHING;
	return p;
}

fn void button_clicked(void* id, String id_str, int col, int row) @local {
	ButtonSlot* slot = (ButtonSlot*)id;
	slot.dialog.focused = slot.index;
	slot.dialog.open = false;
	slot.dialog.pending = slot.index == 0 ? Pressed.CONFIRMED : Pressed.DISMISSED;
}

fn void backdrop_dismissed(void* id, String id_str, int col, int row) @local {
	Dialog* d = (Dialog*)id;
	d.open = false;
	d.pending = Pressed.DISMISSED;
}

// node returns the dialog, or null when it is closed, so the caller can add
// it unconditionally.
//
// The panel is a styled box sized by the layout: its border and padding frame
// the title, body and button row, and it hugs them, no narrower than the
// min_width its style carries.
fn xray::Node* Dialog.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::DOUBLE, .border_color = th.accent,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
		.min_width = self.min_cols,
	};
	glaze::Style title_s = { .fg = th.accent, .bold = true };

	xray::Node* panel_node = milktea::vbox(panel)
		.with_gap(1)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
	panel_node.id_with(self).on_click_outside(&backdrop_dismissed);

	// Text carries the panel's bg, or it would paint on the renderer's
	// default (black) instead of showing the panel through.
	panel_node.add(milktea::text(title_s.background(th.panel), self.title).fit_height());
	panel_node.add(milktea::text({ .fg = th.text, .bg = th.panel }, self.body).fit_height());

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(2)); // label row + the button's own drop shadow
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		self.button_slots[i] = { .dialog = self, .index = i };
		String label = self.buttons[i].themed(th).with_focus(i == self.focused).view();
		xray::Node* btn = milktea::text({ .bg = th.panel }, label).width(milktea::cells(self.buttons[i].measure_width(2)));
		btn.id_with(&self.button_slots[i]).on_click(&button_clicked);
		buttons_row.add(btn);
	}
	panel_node.add(buttons_row);

	return panel_node;
}
