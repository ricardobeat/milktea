module dos_app;

import milktea;
import glaze;
import xray;

// A modal dialog: a centered panel with a title, a body, and a row of buttons
// along the bottom. It reports which button was pressed; which one has the
// keyboard is the runtime's focus (see milktea::focus), not dialog state.

const sz DIALOG_BUTTONS = 2;

struct Dialog {
	String title;
	String body;
	Button[DIALOG_BUTTONS] buttons;
	bool open;

	// Narrowest the panel will be. It grows past this to fit its content;
	// without a floor a short message would give a cramped dialog.
	sz min_cols;

	// Set by a button's on_click (see ButtonSlot/button_clicked) or the
	// backdrop's on_click_outside; update() reads and clears it once per
	// frame — the click path's version of what handle_key returns directly.
	Pressed pending;

	ButtonSlot[DIALOG_BUTTONS] button_slots;
}

// Pressed is what handle_key reports: nothing yet, dismissed without choosing,
// or a button was pressed — which one is focused_button().
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
	sz index;
}

fn Dialog new_dialog(String title, String body, String ok, String cancel) {
	return {
		.title = title,
		.body = body,
		.buttons = { new_button(ok), new_button(cancel) },
		.min_cols = 40,
	};
}

// show opens the dialog. The panel blocks the pointer, so the runtime keeps
// focus inside it and starts it on the first button.
fn void Dialog.show(&self) {
	self.open = true;
}

// focused_button is the index of the button with keyboard focus.
fn sz Dialog.focused_button(&self) => milktea::is_focused(&self.button_slots[1]) ? 1 : 0;

fn Pressed Dialog.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return Pressed.NOTHING;

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			return Pressed.DISMISSED;
		// Tab is the runtime's; the arrows move focus between the two too.
		case milktea::KeyCode.LEFT:
		case milktea::KeyCode.RIGHT:
			milktea::focus(&self.button_slots[1 - self.focused_button()]);
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

fn void button_clicked(void* id, String id_str, sz col, sz row) @local {
	ButtonSlot* slot = (ButtonSlot*)id;
	slot.dialog.open = false;
	slot.dialog.pending = slot.index == 0 ? Pressed.CONFIRMED : Pressed.DISMISSED;
}

fn void backdrop_dismissed(void* id, String id_str, sz col, sz row) @local {
	Dialog* d = (Dialog*)id;
	d.open = false;
	d.pending = Pressed.DISMISSED;
}

// Space between a modal panel's border and its content.
const sz PANEL_PAD_ROWS = 1;
const sz PANEL_PAD_COLS = 2;

// modal_panel is the box dialogs and the picker are built in: bordered,
// centered and with a drop shadow. It blocks the pointer, which also keeps
// keyboard focus inside it while it is open.
fn xray::Node* modal_panel(Theme* th, sz min_cols) {
	glaze::Style frame = { .bg = th.panel, .border = glaze::DOUBLE, .border_color = th.accent };
	return milktea::vstack().style(frame)
		.block_pointer()
		.min_width(min_cols)
		.with_padding(PANEL_PAD_ROWS, PANEL_PAD_COLS, PANEL_PAD_ROWS, PANEL_PAD_COLS)
		.with_gap(1)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(th.shadow));
}

// node returns the dialog, or null when it is closed, so the caller can add
// it unconditionally.
//
// The panel is a styled box sized by the layout: its border and padding frame
// the title, body and button row, and it hugs them, no narrower than the
// min_width its style carries.
fn xray::Node* Dialog.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style title_s = { .fg = th.accent, .bold = true };

	xray::Node* panel_node = modal_panel(th, self.min_cols);
	panel_node.id_with(self).on_click_outside(&backdrop_dismissed);

	// Body text has no bg of its own — without one it paints on the
	// renderer's default (black) instead of showing the panel through, so it
	// carries the same bg as the panel. title_s stays a separate style baked
	// into the string (render() below) since only the title is accented.
	glaze::Style body_s = { .fg = th.text, .bg = th.panel };
	String header = glaze::join_vertical_arr(glaze::Position.LEFT, {
		title_s.background(th.panel).render(self.title), "", body_s.render(self.body),
	});
	panel_node.add(milktea::text(header, body_s));

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(2)); // label row + the button's own drop shadow
	for (sz i = 0; i < DIALOG_BUTTONS; i++) {
		self.button_slots[i] = { .dialog = self, .index = i };
		buttons_row.add(self.buttons[i].themed(th).focus_node(&self.button_slots[i]).on_click(&button_clicked));
	}
	panel_node.add(buttons_row);

	return panel_node;
}
