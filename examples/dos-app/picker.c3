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
// Same shape as Dialog.node(): the panel is a real container sized by the
// solver from its children (min_width().center()) — the choice rows and the
// button row are individually clickable nodes, and each choice row stretches
// to the panel's own content width (ALIGN_STRETCH, the vstack default)
// instead of a widest-choice width computed by hand ahead of layout.
fn xray::Node* Picker.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::DOUBLE, .border_color = th.accent,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
	};
	glaze::Style title_s = { .fg = th.accent, .bg = th.panel, .bold = true };

	xray::Node* panel_node = milktea::text(panel, "")
		.min_width(self.min_cols)
		.with_gap(1)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(th.shadow));
	panel_node.on_click_outside(&picker_backdrop_dismissed, self);

	panel_node.add(milktea::text(title_s, self.title).height(milktea::cells(1)));

	xray::Node* list_node = xray::vstack().height(milktea::cells(self.count));
	glaze::Style row = { .fg = th.text, .bg = th.panel, .pad_left = 1, .pad_right = 1, .align_h = glaze::Position.LEFT };
	glaze::Style current = {
		.fg = th.ink, .bg = th.accent, .bold = true,
		.pad_left = 1, .pad_right = 1, .align_h = glaze::Position.LEFT,
	};
	for (int i = 0; i < self.count; i++) {
		self.choice_slots[i] = { .picker = self, .index = i };
		bool on = i == self.selected;
		String label = string::tformat("%s %s", on ? "▸" : " ", self.choices[i]);
		xray::Node* choice_node = milktea::text(on ? current : row, label).height(milktea::cells(1));
		choice_node.on_click(&picker_choice_clicked, &self.choice_slots[i]);
		list_node.add(choice_node);
	}
	panel_node.add(list_node);

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(2)); // label row + the button's own drop shadow
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
