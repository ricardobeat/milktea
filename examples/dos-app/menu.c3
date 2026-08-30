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

// TitleSlot/ItemSlot are the click contexts passed as the void* ctx to
// on_click — one struct per bar title / dropdown row, holding the index and
// a back-pointer to the Menu. They live inside Menu itself (not the per-frame
// node tree) so their addresses stay valid across frames: the tree rebuilt
// each view() only ever points at these existing slots, never allocates its
// own click context.
struct TitleSlot {
	Menu* menu;
	int index;
}

struct ItemSlot {
	Menu* menu;
	int index;
}

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
fn Chosen Menu.handle_bar_key(&self, milktea::KeyMsg k) {
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

// dismiss closes the menu without picking anything — fired by a click
// outside the bar and the dropdown, same effect as ESC.
fn void Menu.dismiss(&self) {
	self.open = false;
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
// transitions to xray::ClickFn's (ctx, col, row) shape. ctx is a TitleSlot*/
// ItemSlot*/Menu* — see the slot fields on Menu for why these addresses stay
// valid across the frame boundary where the node tree that registered them
// does not.
fn void title_clicked(void* ctx, int col, int row) @local {
	TitleSlot* slot = (TitleSlot*)ctx;
	slot.menu.selected = slot.index;
	slot.menu.open = true;
	slot.menu.item = 0;
}

fn void item_clicked(void* ctx, int col, int row) @local {
	ItemSlot* slot = (ItemSlot*)ctx;
	slot.menu.item = slot.index;
	slot.menu.open = false;
	slot.menu.pending = Chosen.PICKED;
}

fn void dropdown_dismissed(void* ctx, int col, int row) @local {
	Menu* m = (Menu*)ctx;
	m.dismiss();
	m.pending = Chosen.DISMISSED;
}

// ── view ─────────────────────────────────────────────────────────────────────

fn xray::Node* Menu.bar(&self, Theme* th) {
	glaze::Style bar = { .bg = th.bar, .fg = th.bar_text };
	glaze::Style active = { .bg = th.ink, .fg = th.text, .bold = true };

	xray::Node* row = milktea::hstack().height(milktea::cells(1));
	for (int i = 0; i < MENU_COLS; i++) {
		self.title_slots[i] = { .menu = self, .index = i };
		String label = (i == self.selected ? active : bar).render(self.titles[i]);
		xray::Node* title_node = milktea::text(bar, label)
			.width(milktea::cells(glaze::string_width(self.titles[i])));
		title_node.on_click(&title_clicked, &self.title_slots[i]);
		row.add(title_node);
	}
	return row;
}

// dropdown returns the open panel, or null when the menu is closed — so the
// caller adds it unconditionally and an absent menu contributes nothing.
//
// The panel is one node: milktea::text() paints the bordered background from
// an empty string (giving the frame without baking any content into it), and
// the item rows are its children, padded 1 cell in to clear the border —
// NORMAL's border glyphs are always exactly 1 cell thick on every side. Each
// row is its own clickable node, and a click anywhere on the panel that
// isn't a row (the border, the padding) falls through to on_click_outside,
// which is exactly the dismiss behavior wanted there too.
fn xray::Node* Menu.dropdown(&self, int below, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.bar, .fg = th.bar_text,
		.border = glaze::NORMAL, .border_color = th.text,
	};
	// No pad_left/pad_right here: label and key are now separate leaf nodes
	// (see item_row), each sized to exactly its own text width — style-level
	// padding would make Style.render's content wider than that solved
	// width and overflow into the neighboring column. The inset that used
	// to come from this padding is now node-level padding on the row itself.
	glaze::Style selected = { .bg = th.ink, .fg = th.accent, .bold = true };
	glaze::Style item = { .bg = th.bar, .fg = th.bar_text };

	xray::Node* panel_node = milktea::text(panel, "")
		.width(milktea::cells(self.item_width + ITEM_PAD * 2 + 2))
		.height(milktea::cells(MENU_ITEMS + 2))
		.with_padding(1, 1, 1, 1)
		.at(self.title_x[self.selected], below)
		.shadow(milktea::shadow(1, 1).with_color(th.shadow));
	panel_node.on_click_outside(&dropdown_dismissed, self);

	for (int i = 0; i < MENU_ITEMS; i++) {
		self.item_slots[i] = { .menu = self, .index = i };
		glaze::Style s = i == self.item ? selected : item;
		xray::Node* row_node = self.item_row(self.items[self.selected][i], s);
		row_node.on_click(&item_clicked, &self.item_slots[i]);
		panel_node.add(row_node);
	}
	return panel_node;
}

// item_row lays a label against its shortcut key, label left and key pushed
// to the row's right edge — a real hstack with JUSTIFY_SPACE_BETWEEN, so the
// gap between them grows or shrinks with the row's solved width instead of
// a width computed ahead of layout (self.item_width - string_width(label))
// that has to happen to match whatever the panel ends up being.
//
// The hstack itself paints nothing (a pure layout node has no content), so
// it sits inside a background leaf sized to the same row — otherwise the
// gap JUSTIFY_SPACE_BETWEEN opens up between label and key would show
// whatever is behind the dropdown instead of the row's own highlight.
fn xray::Node* Menu.item_row(&self, MenuItem mi, glaze::Style base) {
	xray::Node* bg = milktea::text(base, "").height(milktea::cells(1));
	xray::Node* row = xray::hstack()
		.with_justify(xray::JustifyContent.JUSTIFY_SPACE_BETWEEN)
		.with_padding(0, ITEM_PAD, 0, ITEM_PAD);
	// Both children need an explicit (shrink-to-content) width: hstack's
	// default is fill, which would split the row 50/50 between them and
	// leave JUSTIFY_SPACE_BETWEEN nothing to push apart, since two fill
	// children already consume the whole row between them.
	row.add(milktea::text(base, mi.label).width(milktea::cells(glaze::string_width(mi.label))));
	row.add(milktea::text(base, mi.key).width(milktea::cells(glaze::string_width(mi.key))));
	bg.add(row);
	return bg;
}
