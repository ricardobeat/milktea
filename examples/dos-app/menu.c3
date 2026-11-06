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
const sz ITEM_PAD = 1;
// Least space between an item's label and its key.
const sz ITEM_GAP = 2;

const sz MENU_COLS  = 4;
const sz MENU_ITEMS = 4;

// TitleSlot/ItemSlot are the click contexts passed as the void* ctx to
// on_click — one struct per bar title / dropdown row, holding the index and
// a back-pointer to the Menu. They live inside Menu itself (not the per-frame
// node tree) so their addresses stay valid across frames: the tree rebuilt
// each view() only ever points at these existing slots, never allocates its
// own click context.
struct TitleSlot {
	Menu* menu;
	sz index;
}

struct ItemSlot {
	Menu* menu;
	sz index;
}

struct Menu {
	String[MENU_COLS] titles;
	// Column where each title starts in the bar, so a dropdown can open under
	// the one that owns it.
	sz[MENU_COLS] title_x;
	MenuItem[MENU_COLS][MENU_ITEMS] items;

	sz selected;      // which title
	sz item;          // which item within the open dropdown
	bool open;
	// The bar has the keyboard: the current title is highlighted and the
	// arrows move along the bar. F10, an arrow, Enter or a click turns it
	// on; Esc, a pick or a click elsewhere turns it off.
	bool active;

	// Narrowest a dropdown gets, border included; longer items widen it.
	sz item_width;

	TitleSlot[MENU_COLS] title_slots;
	ItemSlot[MENU_ITEMS] item_slots;

	// Click-path counterpart to what handle_key returns synchronously — see
	// take_pending(). A click can't return a value the way handle_key does,
	// so item_clicked/dropdown_dismissed stash the outcome here for update()
	// to pick up right after dispatch_click() runs the hooks.
	Chosen pending;
}

// Chosen is what handle_key reports back: nothing happened, the menu was
// dismissed, or an item was picked.
enum Chosen {
	NOTHING,
	DISMISSED,
	PICKED,
}

fn Menu new_menu(String[MENU_COLS] titles, sz item_width = 24) {
	Menu m = { .titles = titles, .item_width = item_width };
	// Titles sit end to end from the left edge, each as wide as its own text.
	sz x = 0;
	for (sz i = 0; i < MENU_COLS; i++) {
		m.title_x[i] = x;
		x += glaze::string_width(titles[i]);
	}
	return m;
}

fn void Menu.set_items(&self, sz col, MenuItem[MENU_ITEMS] items) {
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
			self.active = false;
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
			self.active = false;
			return Chosen.PICKED;
		default:
	}
	return Chosen.NOTHING;
}

// handle_bar_key is the closed state: arrows move along the bar, and Enter or
// Down opens the dropdown under the current title.
//
// An inactive bar only wakes up: the key that turns it on does not also move
// it, so the first arrow shows where the highlight is before moving it.
fn Chosen Menu.handle_bar_key(&self, milktea::KeyMsg k) {
	if (!self.active) {
		switch (k.code) {
			case milktea::KeyCode.F10:
			case milktea::KeyCode.LEFT:
			case milktea::KeyCode.RIGHT:
				self.active = true;
			case milktea::KeyCode.DOWN:
			case milktea::KeyCode.ENTER:
				self.active = true;
				self.open = true;
				self.item = 0;
			default:
		}
		return Chosen.NOTHING;
	}
	switch (k.code) {
		case milktea::KeyCode.ESC:
		case milktea::KeyCode.F10:
			self.active = false;
			return Chosen.DISMISSED;
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

// dismiss closes the menu without picking anything — fired by a click
// outside the bar and the dropdown, same effect as ESC.
fn void Menu.dismiss(&self) {
	self.open = false;
	self.active = false;
}

// take_pending returns and clears whatever a mouse click reported since the
// last call — the click path's counterpart to handle_key's return value.
fn Chosen Menu.take_pending(&self) {
	Chosen p = self.pending;
	self.pending = Chosen.NOTHING;
	return p;
}

// ── mouse ────────────────────────────────────────────────────────────────────

// title_clicked/item_clicked/dropdown_dismissed adapt Menu's own state
// transitions to xray::ClickFn's (id, id_str, col, row) shape. id carries a
// TitleSlot*/ItemSlot*/Menu* set via .id_with(&slot) at registration time —
// the slot addresses stay valid because they live on Menu itself, which
// outlives the node tree that registered them.
fn void title_clicked(void* id, String id_str, sz col, sz row) @local {
	TitleSlot* slot = (TitleSlot*)id;
	slot.menu.selected = slot.index;
	slot.menu.open = true;
	slot.menu.active = true;
	slot.menu.item = 0;
}

// title_hovered moves an open menu to the title under the pointer, the way
// a menu bar does once one menu is down. A closed menu only highlights the
// title, which its hover style already does.
fn void title_hovered(void* id, String id_str, sz col, sz row) @local {
	TitleSlot* slot = (TitleSlot*)id;
	if (!slot.menu.open || slot.menu.selected == slot.index) return;
	slot.menu.selected = slot.index;
	slot.menu.item = 0;
}

// item_hovered makes the item under the pointer the current one, so the
// pointer and the arrow keys move the same highlight.
fn void item_hovered(void* id, String id_str, sz col, sz row) @local {
	ItemSlot* slot = (ItemSlot*)id;
	slot.menu.item = slot.index;
}

fn void item_clicked(void* id, String id_str, sz col, sz row) @local {
	ItemSlot* slot = (ItemSlot*)id;
	slot.menu.item = slot.index;
	slot.menu.open = false;
	slot.menu.active = false;
	slot.menu.pending = Chosen.PICKED;
}

fn void dropdown_dismissed(void* id, String id_str, sz col, sz row) @local {
	Menu* m = (Menu*)id;
	m.dismiss();
	m.pending = Chosen.DISMISSED;
}

// ── view ─────────────────────────────────────────────────────────────────────

fn xray::Node* Menu.bar(&self, Theme* th) {
	glaze::Style bar = { .bg = th.bar, .fg = th.bar_text };
	glaze::Style active = { .bg = th.ink, .fg = th.text };

	xray::Node* row = milktea::hstack().style(bar).height(milktea::cells(1));
	for (sz i = 0; i < MENU_COLS; i++) {
		self.title_slots[i] = { .menu = self, .index = i };
		bool on = self.active && i == self.selected;
		// The label sets no colour, so it takes the title's, hover included.
		xray::Node* title_node = milktea::text(self.titles[i], { .bold = on })
			.style(on ? active : bar, hover: active)
			.width(milktea::cells(glaze::string_width(self.titles[i])));
		title_node.id_with(&self.title_slots[i])
			.on_click(&title_clicked)
			.on_hover_in(&title_hovered);
		row.add(title_node);
	}
	return row;
}

// dropdown returns the open panel, or null when the menu is closed — so the
// caller adds it unconditionally and an absent menu contributes nothing.
//
// The panel is a styled vstack holding one clickable node per item. A click
// on the border is a click outside every row, so on_click_outside dismisses
// the menu.
fn xray::Node* Menu.dropdown(&self, sz below, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = { .bg = th.bar, .border = glaze::NORMAL, .border_color = th.text };
	glaze::Style selected = { .bg = th.ink, .fg = th.accent, .bold = true };
	glaze::Style item = { .bg = th.bar, .fg = th.bar_text };

	xray::Node* panel_node = milktea::vstack().style(panel)
		.width(milktea::cells(self.item_width + ITEM_PAD * 2 + 2))
		.height(milktea::cells(MENU_ITEMS + 2))
		.at(self.title_x[self.selected], below)
		.shadow(milktea::shadow(2, 1).with_color(th.shadow));
	panel_node.id_with(self).on_click_outside(&dropdown_dismissed);

	for (sz i = 0; i < MENU_ITEMS; i++) {
		self.item_slots[i] = { .menu = self, .index = i };
		glaze::Style s = i == self.item ? selected : item;
		xray::Node* row_node = self.item_row(self.items[self.selected][i], s);
		row_node.id_with(&self.item_slots[i])
			.on_click(&item_clicked)
			.on_hover_in(&item_hovered);
		panel_node.add(row_node);
	}
	return panel_node;
}

// item_row lays a label against its shortcut key, label left and key pushed
// to the row's right edge with JUSTIFY_SPACE_BETWEEN, so the gap between them
// follows the row's solved width. The row's style paints its highlight
// across that gap.
fn xray::Node* Menu.item_row(&self, MenuItem mi, glaze::Style base) {
	xray::Node* row = xray::hstack().style(base).height(milktea::cells(1))
		.with_justify(xray::JustifyContent.JUSTIFY_SPACE_BETWEEN)
		.with_padding(0, ITEM_PAD, 0, ITEM_PAD);
	// Both children need an explicit (shrink-to-content) width: hstack's
	// default is fill, which would split the row 50/50 between them and
	// leave JUSTIFY_SPACE_BETWEEN nothing to push apart, since two fill
	// children already consume the whole row between them.
	// The labels set no colour or background, so they take the row's.
	glaze::Style label = { .bold = base.bold };
	row.add(milktea::text(mi.label, label).width(milktea::cells(glaze::string_width(mi.label))));
	row.add(milktea::text(mi.key, label).width(milktea::cells(glaze::string_width(mi.key))));
	return row;
}
