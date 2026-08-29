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

// node returns the picker, or null when it is closed.
fn xray::Node* Picker.node(&self, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::DOUBLE, .border_color = th.accent,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
		.align_h = glaze::Position.CENTER, .align_v = glaze::Position.CENTER,
	};
	glaze::Style title_s = { .fg = th.accent, .bold = true };

	String list = self.choice_list(th);

	String[DIALOG_BUTTONS] rendered;
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		rendered[i] = self.buttons[i].themed(th).with_focus(i == self.focused_button).view();
	}
	String buttons = glaze::join_horizontal_arr(glaze::Position.CENTER, rendered[..], 2);

	String inner = glaze::join_vertical_arr(glaze::Position.CENTER, {
		title_s.render(self.title), "", list, "", buttons,
	});

	return milktea::text(panel, inner)
		.width(milktea::at_least(self.min_cols))
		.center()
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
}

// choice_list draws the options one per row, the highlighted one marked and
// inverted. Every row is padded to the widest label so the highlight is a
// solid bar rather than ragged.
fn String Picker.choice_list(&self, Theme* th) @local {
	int widest = 0;
	for (int i = 0; i < self.count; i++) {
		int w = glaze::string_width(self.choices[i]);
		if (w > widest) widest = w;
	}

	// Every row is the same width and left-aligned, so the highlight is an
	// even bar and the marker column does not shift the labels.
	glaze::Style row = {
		.fg = th.text, .pad_left = 1, .pad_right = 1,
		.align_h = glaze::Position.LEFT,
	};
	glaze::Style current = {
		.fg = th.ink, .bg = th.accent, .bold = true, .pad_left = 1, .pad_right = 1,
		.align_h = glaze::Position.LEFT,
	};

	String[MAX_CHOICES] rows;
	for (int i = 0; i < self.count; i++) {
		bool on = i == self.selected;
		String label = string::tformat("%s %s", on ? "▸" : " ", self.choices[i]);
		rows[i] = (on ? current : row).with_width(widest + 4).render(label);
	}
	return glaze::join_vertical_arr(glaze::Position.LEFT, rows[:self.count]);
}
