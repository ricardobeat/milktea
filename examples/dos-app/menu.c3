module dos_app;

import milktea;
import glaze;
import xray;

// A DOS menu bar and the dropdown it opens. The bar and the dropdown are one
// component because they share a state — which title is selected is also which
// dropdown is showing — and splitting them would mean keeping the two in sync
// from outside.
//
// The component owns navigation. The app asks what was chosen after handing it
// a key, rather than tracking the selection itself.

struct MenuItem {
	String label;
	String key;
}

// Cells of padding on each side of a dropdown item, inside its highlight.
const int ITEM_PAD = 1;

const int MENU_COLS  = 4;
const int MENU_ITEMS = 4;

struct Menu {
	String[MENU_COLS] titles;
	// Column where each title starts in the bar, so a dropdown can open under
	// the one that owns it.
	int[MENU_COLS] title_x;
	MenuItem[MENU_COLS][MENU_ITEMS] items;

	int selected;      // which title
	int item;          // which item within the open dropdown
	bool open;

	// Width of an item's text, before the padding around it.
	int item_width;
}

// Chosen is what handle_key reports back: nothing happened, the menu was
// dismissed, or an item was picked.
enum Chosen {
	NOTHING,
	DISMISSED,
	PICKED,
}

fn Menu new_menu(String[MENU_COLS] titles, int item_width = 20) {
	Menu m = { .titles = titles, .item_width = item_width };
	// Titles sit end to end from the left edge, each as wide as its own text.
	int x = 0;
	for (int i = 0; i < MENU_COLS; i++) {
		m.title_x[i] = x;
		x += glaze::string_width(titles[i]);
	}
	return m;
}

fn void Menu.set_items(&self, int col, MenuItem[MENU_ITEMS] items) {
	if (col >= 0 && col < MENU_COLS) self.items[col] = items;
}

fn MenuItem Menu.current_item(&self) => self.items[self.selected][self.item];

// handle_key drives the menu. It reports whether the key produced a choice;
// which item that was is current_item(), read before the menu is reopened.
fn Chosen Menu.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return self.handle_bar_key(k);

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			return Chosen.DISMISSED;
		case milktea::KeyCode.UP:
			if (self.item > 0) self.item--;
		case milktea::KeyCode.DOWN:
			if (self.item < MENU_ITEMS - 1) self.item++;
		case milktea::KeyCode.LEFT:
			if (self.selected > 0) self.selected--;
			self.item = 0;
		case milktea::KeyCode.RIGHT:
			if (self.selected < MENU_COLS - 1) self.selected++;
			self.item = 0;
		case milktea::KeyCode.ENTER:
			self.open = false;
			return Chosen.PICKED;
		default:
	}
	return Chosen.NOTHING;
}

// handle_bar_key is the closed state: arrows move along the bar, and Enter or
// Down opens the dropdown under the current title.
fn Chosen Menu.handle_bar_key(&self, milktea::KeyMsg k) @local {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			if (self.selected > 0) self.selected--;
		case milktea::KeyCode.RIGHT:
			if (self.selected < MENU_COLS - 1) self.selected++;
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.ENTER:
			self.open = true;
			self.item = 0;
		case milktea::KeyCode.RUNE:
			if (k.rune == 'h' && self.selected > 0) self.selected--;
			if (k.rune == 'l' && self.selected < MENU_COLS - 1) self.selected++;
		default:
	}
	return Chosen.NOTHING;
}

// ── view ─────────────────────────────────────────────────────────────────────

fn xray::Node* Menu.bar(&self, Theme* th) {
	glaze::Style bar = { .bg = th.bar, .fg = th.bar_text };
	glaze::Style active = { .bg = th.ink, .fg = th.text, .bold = true };

	String[MENU_COLS] rendered;
	for (int i = 0; i < MENU_COLS; i++) {
		rendered[i] = (i == self.selected ? active : bar).render(self.titles[i]);
	}
	String row = glaze::join_horizontal_arr(glaze::Position.CENTER, rendered[..], 0);

	return milktea::text(bar, row).height(milktea::cells(1));
}

// dropdown returns the open panel, or null when the menu is closed — so the
// caller adds it unconditionally and an absent menu contributes nothing.
fn xray::Node* Menu.dropdown(&self, int below, Theme* th) {
	if (!self.open) return null;

	// The panel has no padding of its own: each item carries its, inside the
	// highlight, so the highlighted row reaches the border on both sides.
	glaze::Style panel = {
		.bg = th.bar, .fg = th.bar_text,
		.border = glaze::NORMAL, .border_color = th.text,
	};
	// A cell of padding on each side, so the highlight is a bar with the label
	// inset rather than text flush against the panel border.
	glaze::Style selected = {
		.bg = th.ink, .fg = th.accent, .bold = true,
		.pad_left = ITEM_PAD, .pad_right = ITEM_PAD,
	};
	glaze::Style item = {
		.bg = th.bar, .fg = th.bar_text,
		.pad_left = ITEM_PAD, .pad_right = ITEM_PAD,
	};

	String[MENU_ITEMS] rows;
	for (int i = 0; i < MENU_ITEMS; i++) {
		glaze::Style s = (i == self.item ? selected : item)
			.with_width(self.item_width + ITEM_PAD * 2);
		rows[i] = self.render_item(self.items[self.selected][i], s);
	}
	String content = glaze::join_vertical_arr(glaze::Position.LEFT, rows[..]);

	return milktea::text(panel, content)
		.at(self.title_x[self.selected], below)
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
}

// render_item lays a label against its shortcut key, the label left and the
// key pushed to the right edge of the item's width.
fn String Menu.render_item(&self, MenuItem mi, glaze::Style base) @local {
	String label = glaze::style().align_horizontal(glaze::Position.LEFT).render(mi.label);
	String key   = glaze::style()
		.align_horizontal(glaze::Position.RIGHT)
		.with_width(self.item_width - glaze::string_width(mi.label))
		.render(mi.key);
	return base.render(glaze::join_horizontal(label, key, 0));
}
