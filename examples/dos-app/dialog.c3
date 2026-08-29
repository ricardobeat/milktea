module dos_app;

import milktea;
import glaze;
import xray;

// A modal dialog: a centered panel with a title, a body, and a row of buttons
// along the bottom. It owns which button is focused and reports which one was
// pressed, so the app does not track the selection itself.

const int DIALOG_BUTTONS = 2;
// Panel padding inside its DOUBLE border (1 cell) — matches the old style's
// pad_top/right/bottom/left.
const int PANEL_PAD_TOP = 1;
const int PANEL_PAD_SIDE = 2;
const int PANEL_PAD_BOTTOM = 1;
const int PANEL_BORDER = 1;
// Blank row between the header text and the button row.
const int HEADER_GAP = 1;
// A button is its label plus a one-row drop shadow underneath.
const int BUTTON_ROW_H = 2;

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

fn void button_clicked(void* ctx, int col, int row) @local {
	ButtonSlot* slot = (ButtonSlot*)ctx;
	slot.dialog.focused = slot.index;
	slot.dialog.open = false;
	slot.dialog.pending = slot.index == 0 ? Pressed.CONFIRMED : Pressed.DISMISSED;
}

fn void backdrop_dismissed(void* ctx, int col, int row) @local {
	Dialog* d = (Dialog*)ctx;
	d.open = false;
	d.pending = Pressed.DISMISSED;
}

// header_dims measures the title+body block's rendered size (before the
// button row), matching join_vertical_arr(Position.LEFT, {title, "", body}).
fn int[2] Dialog.header_dims(&self) {
	String header = glaze::join_vertical_arr(glaze::Position.LEFT, { self.title, "", self.body });
	int width = 0;
	int height = 1;
	usz start = 0;
	for (usz i = 0; i <= header.len; i++) {
		if (i < header.len && header[i] != '\n') continue;
		int w = glaze::string_width(header[start:i - start]);
		if (w > width) width = w;
		if (i < header.len) height++;
		start = i + 1;
	}
	return { width, height };
}

fn int Dialog.buttons_width(&self) {
	int total = 0;
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		total += self.buttons[i].measure_width(2);
	}
	return total + 2 * (DIALOG_BUTTONS - 1); // gaps between buttons
}

// node returns the dialog, or null when it is closed, so the caller can add
// it unconditionally.
//
// The panel is one node whose own content is the bordered background,
// painted from an empty string so nothing is baked into a single opaque
// blob — the header text and the button row are its children instead, each
// a real node so the buttons stay individually clickable. The panel is
// explicitly sized (not auto-fit via center()) because auto-fit only
// measures a node's own content string, which does not account for
// children.
fn xray::Node* Dialog.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::DOUBLE, .border_color = th.accent,
	};
	glaze::Style title_s = { .fg = th.accent, .bold = true };

	int[2] hdr = self.header_dims();
	int content_w = hdr[0];
	int btn_w = self.buttons_width();
	if (btn_w > content_w) content_w = btn_w;
	if (content_w < self.min_cols - PANEL_PAD_SIDE * 2 - PANEL_BORDER * 2) {
		content_w = self.min_cols - PANEL_PAD_SIDE * 2 - PANEL_BORDER * 2;
	}
	int content_h = hdr[1] + HEADER_GAP + BUTTON_ROW_H;

	int panel_w = content_w + PANEL_PAD_SIDE * 2 + PANEL_BORDER * 2;
	int panel_h = content_h + PANEL_PAD_TOP + PANEL_PAD_BOTTOM + PANEL_BORDER * 2;

	xray::Node* panel_node = milktea::text(panel, "")
		.width(milktea::cells(panel_w))
		.height(milktea::cells(panel_h))
		.with_padding(PANEL_PAD_TOP, PANEL_PAD_SIDE, PANEL_PAD_BOTTOM, PANEL_PAD_SIDE)
		.with_gap(HEADER_GAP)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
	panel_node.on_click_outside(&backdrop_dismissed, self);

	// Body text has no bg of its own — without one it paints on the
	// renderer's default (black) instead of showing the panel through, so it
	// carries the same bg as the panel. title_s stays a separate style baked
	// into the string (render() below) since only the title is accented.
	glaze::Style body_s = { .fg = th.text, .bg = th.panel };
	String header = glaze::join_vertical_arr(glaze::Position.LEFT, {
		title_s.background(th.panel).render(self.title), "", body_s.render(self.body),
	});
	panel_node.add(milktea::text(body_s, header).height(milktea::cells(hdr[1])));

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(BUTTON_ROW_H));
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		self.button_slots[i] = { .dialog = self, .index = i };
		String label = self.buttons[i].themed(th).with_focus(i == self.focused).view();
		xray::Node* btn = milktea::text({ .bg = th.panel }, label).width(milktea::cells(self.buttons[i].measure_width(2)));
		btn.on_click(&button_clicked, &self.button_slots[i]);
		buttons_row.add(btn);
	}
	panel_node.add(buttons_row);

	return panel_node;
}
