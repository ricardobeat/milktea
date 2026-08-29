module dos_app;

import milktea;
import glaze;
import xray;

// A modal that offers a list of choices: a title, the options one per row with
// the current one highlighted, and OK/Cancel along the bottom.
//
// Up and down move the highlight, left and right move between the buttons, so
// the list and the buttons are navigated at once without a focus mode. That
// suits a short list, which is what a picker is for.

const int MAX_CHOICES = 8;
// PANEL_PAD_TOP/SIDE/BOTTOM, PANEL_BORDER, HEADER_GAP, BUTTON_ROW_H are
// shared with Dialog — see dialog.c3, same module.

struct Picker {
	String title;
	String[MAX_CHOICES] choices;
	int count;

	// Which option is highlighted, and which was highlighted when the picker
	// opened — restored if the user cancels.
	int selected;
	int opening;

	Button[DIALOG_BUTTONS] buttons;
	int focused_button;
	bool open;

	int min_cols;

	// Click-path counterpart to what handle_key returns — see Dialog.pending.
	Pressed pending;

	PickerButtonSlot[DIALOG_BUTTONS] button_slots;
	ChoiceSlot[MAX_CHOICES] choice_slots;
}

struct ChoiceSlot {
	Picker* picker;
	int index;
}

struct PickerButtonSlot {
	Picker* picker;
	int index;
}

fn Picker new_picker(String title, String ok, String cancel) {
	return {
		.title = title,
		.buttons = { new_button(ok), new_button(cancel) },
		.min_cols = 34,
	};
}

fn void Picker.add_choice(&self, String label) {
	if (self.count < MAX_CHOICES) self.choices[self.count++] = label;
}

// show opens the picker on `current`, remembering it so a cancel can put it
// back.
fn void Picker.show(&self, int current) {
	self.open = true;
	self.selected = current;
	self.opening = current;
	self.focused_button = 0;
}

// handle_key reports what the key did. On CONFIRMED the choice is `selected`;
// on DISMISSED it has already been restored to what it was when the picker
// opened, so a caller previewing the selection live needs no undo of its own.
fn Pressed Picker.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return Pressed.NOTHING;

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			self.selected = self.opening;
			return Pressed.DISMISSED;
		case milktea::KeyCode.UP:
			if (self.selected > 0) self.selected--;
		case milktea::KeyCode.DOWN:
			if (self.selected < self.count - 1) self.selected++;
		case milktea::KeyCode.LEFT:
		case milktea::KeyCode.RIGHT:
		case milktea::KeyCode.TAB:
			self.focused_button = (self.focused_button + 1) % DIALOG_BUTTONS;
		case milktea::KeyCode.ENTER:
			self.open = false;
			// Button 1 is Cancel, which discards the highlight like ESC does.
			if (self.focused_button == 1) {
				self.selected = self.opening;
				return Pressed.DISMISSED;
			}
			return Pressed.CONFIRMED;
		default:
	}
	return Pressed.NOTHING;
}

// take_pending returns and clears whatever a mouse click reported since the
// last call — the click path's counterpart to handle_key's return value.
fn Pressed Picker.take_pending(&self) {
	Pressed p = self.pending;
	self.pending = Pressed.NOTHING;
	return p;
}

fn void picker_choice_clicked(void* ctx, int col, int row) @local {
	ChoiceSlot* slot = (ChoiceSlot*)ctx;
	// A click on a choice previews it, same as arrowing to it — it does not
	// confirm on its own, matching how Up/Down behave for the keyboard path.
	slot.picker.selected = slot.index;
}

fn void picker_button_clicked(void* ctx, int col, int row) @local {
	PickerButtonSlot* slot = (PickerButtonSlot*)ctx;
	Picker* p = slot.picker;
	p.focused_button = slot.index;
	p.open = false;
	if (slot.index == 1) {
		p.selected = p.opening;
		p.pending = Pressed.DISMISSED;
	} else {
		p.pending = Pressed.CONFIRMED;
	}
}

fn void picker_backdrop_dismissed(void* ctx, int col, int row) @local {
	Picker* p = (Picker*)ctx;
	p.open = false;
	p.selected = p.opening;
	p.pending = Pressed.DISMISSED;
}

// node returns the picker, or null when it is closed.
//
// Same shape as Dialog.node(): the panel paints an empty-content bordered
// background sized to fit its children, which are real nodes (the choice
// list rows and the button row) rather than one joined string, so both stay
// individually clickable.
fn xray::Node* Picker.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::DOUBLE, .border_color = th.accent,
	};
	glaze::Style title_s = { .fg = th.accent, .bg = th.panel, .bold = true };

	int list_w = self.choice_list_width();
	int btn_w = self.buttons_width();
	int content_w = list_w > btn_w ? list_w : btn_w;
	if (content_w < self.min_cols - PANEL_PAD_SIDE * 2 - PANEL_BORDER * 2) {
		content_w = self.min_cols - PANEL_PAD_SIDE * 2 - PANEL_BORDER * 2;
	}
	// title (1) + blank (1) + choice rows + blank (HEADER_GAP handles this
	// via with_gap, so just title + rows here) + button row.
	int content_h = 1 + self.count + BUTTON_ROW_H;

	int panel_w = content_w + PANEL_PAD_SIDE * 2 + PANEL_BORDER * 2;
	int panel_h = content_h + PANEL_PAD_TOP + PANEL_PAD_BOTTOM + PANEL_BORDER * 2 + HEADER_GAP * 2;

	xray::Node* panel_node = milktea::text(panel, "")
		.width(milktea::cells(panel_w))
		.height(milktea::cells(panel_h))
		.with_padding(PANEL_PAD_TOP, PANEL_PAD_SIDE, PANEL_PAD_BOTTOM, PANEL_PAD_SIDE)
		.with_gap(HEADER_GAP)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
	panel_node.on_click_outside(&picker_backdrop_dismissed, self);

	panel_node.add(milktea::text(title_s, self.title).height(milktea::cells(1)));

	xray::Node* list_node = xray::vstack().height(milktea::cells(self.count));
	int widest = self.widest_choice();
	glaze::Style row = { .fg = th.text, .bg = th.panel, .pad_left = 1, .pad_right = 1, .align_h = glaze::Position.LEFT };
	glaze::Style current = {
		.fg = th.ink, .bg = th.accent, .bold = true,
		.pad_left = 1, .pad_right = 1, .align_h = glaze::Position.LEFT,
	};
	for (int i = 0; i < self.count; i++) {
		self.choice_slots[i] = { .picker = self, .index = i };
		bool on = i == self.selected;
		String label = string::tformat("%s %s", on ? "▸" : " ", self.choices[i]);
		String rendered = (on ? current : row).with_width(widest + 4).render(label);
		xray::Node* choice_node = milktea::text({ .bg = th.panel }, rendered).height(milktea::cells(1));
		choice_node.on_click(&picker_choice_clicked, &self.choice_slots[i]);
		list_node.add(choice_node);
	}
	panel_node.add(list_node);

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(BUTTON_ROW_H));
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		self.button_slots[i] = { .picker = self, .index = i };
		String label = self.buttons[i].themed(th).with_focus(i == self.focused_button).view();
		xray::Node* btn = milktea::text({ .bg = th.panel }, label).width(milktea::cells(self.buttons[i].measure_width(2)));
		btn.on_click(&picker_button_clicked, &self.button_slots[i]);
		buttons_row.add(btn);
	}
	panel_node.add(buttons_row);

	return panel_node;
}

fn int Picker.widest_choice(&self) {
	int widest = 0;
	for (int i = 0; i < self.count; i++) {
		int w = glaze::string_width(self.choices[i]);
		if (w > widest) widest = w;
	}
	return widest;
}

fn int Picker.choice_list_width(&self) => self.widest_choice() + 4;

fn int Picker.buttons_width(&self) {
	int total = 0;
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		total += self.buttons[i].measure_width(2);
	}
	return total + 2 * (DIALOG_BUTTONS - 1);
}
