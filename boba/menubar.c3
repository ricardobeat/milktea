// MenuBar is an application's top bar: its menus, room for the window's
// controls, and content of the app's own at either end.
//
//   boba::MenuBar bar = boba::menu_bar({
//       boba::menu("File", { boba::item("New", 'n', CMD_NEW), boba::separator(),
//                            boba::item("Quit", 'q', CMD_QUIT) }),
//       boba::menu("Edit", { ... }),
//   });
//
//   // view():   root.add(vstack().add(bar.node(lead, trail))...).add(bar.dropdown())
//   // update(): boba::MenuEvent ev = bar.update(msg);
//   //           if (ev.kind == PICKED) run(ev.id);
//
// The same item reaches update() as PICKED whichever way it was chosen: a
// click, the keyboard, its shortcut, or the platform's own menu bar, where a
// GUI build on macOS also puts the menus (see milktea::set_native_menus).
//
// In a window with no title bar the platform's controls are kept clear of
// (macOS, at the left) or drawn at the right where the platform has none of
// its own there; a terminal has neither. The empty part of the bar moves the
// window.
//
// The look is the app's: *_style fields are glaze styles for colour and text,
// used in a terminal and a window alike, and *_shape fields are
// xray::Decorations that give the same backgrounds a shape in a window —
// xray::solid() takes its colour from the matching style, hover included, so
// solid().round(4) is the style's background with rounded corners. A
// terminal ignores the shapes.
module boba;

import milktea;
import glaze;
import xray;
import std::core::mem;
import std::core::string;
import std::core::string::conv;

// ---- menus as data ---------------------------------------------------------

// MenuItem is one entry of a menu. key is its shortcut's character (0 for
// none): Ctrl+key in a terminal, ⌘key in the macOS menu bar. id is what
// update() reports when the item is chosen.
struct MenuItem {
	String label;
	uint key;
	int id;
	bool separator;
}

fn MenuItem item(String label, uint key = 0, int id = 0) => { .label = label, .key = key, .id = id };
fn MenuItem separator() => { .separator = true };

struct Menu {
	String title;
	MenuItem[] items;
}

fn Menu menu(String title, MenuItem[] items) => { .title = title, .items = items };

enum MenuEventKind : char {
	NONE,       // the message was not for the menu bar
	CONSUMED,   // the menu bar used it (moved, opened, ...); nothing to do
	PICKED,     // an item was chosen: see id and item
	DISMISSED,  // the menus were closed without choosing
}

struct MenuEvent {
	MenuEventKind kind;
	int id;
	MenuItem item;
}

// ---- the component ----------------------------------------------------------

// Points of the bar's height below which it is not made, so the platform's
// window buttons (14 points on macOS) always fit.
const sz MENU_BAR_MIN_HEIGHT @private = 14;
// Space either side of an item's label and between it and its shortcut.
const sz MENU_ITEM_PAD @private = 1;
const sz MENU_ITEM_GAP @private = 2;

struct MenuTitleSlot @private {
	MenuBar* bar;
	sz index;
}

struct MenuItemSlot @private {
	MenuBar* bar;
	sz index;
}

struct MenuBar {
	// Owned copies of the menus and their item lists. The strings are not
	// copied: titles and labels must outlive the bar, as literals do.
	Menu[] menus;

	sz selected;  // the current title
	sz item;      // the current item of the open menu
	bool open;
	// The app gives the bar the keyboard (for example while its own focus is
	// on the bar); see also with_keyboard_focus.
	bool active;

	glaze::Style bar_style;
	glaze::Style title_style;
	glaze::Style title_hover_style;
	glaze::Style title_open_style;   // the current title while the bar has the keyboard or a menu is open
	glaze::Style panel_style;
	glaze::Style item_style;
	glaze::Style item_selected_style;
	glaze::Style shortcut_style;
	glaze::Style controls_style;     // drawn window controls, where the platform has none

	xray::Decoration bar_shape;      // its padding makes the bar taller than a row in a window
	xray::Decoration title_shape;
	xray::Decoration item_shape;
	xray::Decoration panel_shape;    // drawn in a window instead of panel_style's border
	xray::Shadow panel_shadow;       // the dropdown's shadow where panel_shape is not drawn

	sz min_panel_width;
	// The bar is a focusable node (milktea::focus), so Tab and a click give
	// it the keyboard.
	bool keyboard_focus;
	// Where the platform has a menu bar of its own, keep the titles in the
	// window too (the default) or leave the bar to the controls and content.
	bool titles_with_native;

	bool published;
	bool title_press;
	MenuEvent pending;
	MenuTitleSlot[] title_slots;
	MenuItemSlot[] item_slots;
}

// menu_bar copies the menus into a new bar. Free it with free().
fn MenuBar menu_bar(Menu[] menus) {
	MenuBar b = {
		.titles_with_native = true,
		.title_open_style = { .bold = true },
		.item_selected_style = { .bold = true },
		.min_panel_width = 12,
	};
	b.set_menus(menus);
	return b;
}

// set_menus replaces the menus, and the platform's menu bar with them.
fn void MenuBar.set_menus(&self, Menu[] menus) {
	self.free_menus();
	self.menus = mem::new_array(Menu, menus.len);
	sz most = 0;
	foreach (i, m : menus) {
		self.menus[i] = { .title = m.title, .items = mem::new_array(MenuItem, m.items.len) };
		self.menus[i].items[..] = m.items[..];
		if (m.items.len > most) most = m.items.len;
	}
	self.title_slots = mem::new_array(MenuTitleSlot, menus.len);
	self.item_slots = mem::new_array(MenuItemSlot, most);
	self.selected = 0;
	self.item = 0;
	self.open = false;
	self.published = false;
}

fn void MenuBar.free_menus(&self) @private {
	foreach (m : self.menus) mem::free(m.items);
	if (self.menus.len > 0) mem::free(self.menus);
	if (self.title_slots.len > 0) mem::free(self.title_slots);
	if (self.item_slots.len > 0) mem::free(self.item_slots);
	self.menus = {};
	self.title_slots = {};
	self.item_slots = {};
}

fn void MenuBar.free(&self) => self.free_menus();

// with_styles sets the bar's own colours: the bar, its titles, a title under
// the pointer, and the current title.
fn MenuBar MenuBar.with_styles(self, glaze::Style bar, glaze::Style title, glaze::Style title_hover,
		glaze::Style title_open) {
	MenuBar b = self;
	b.bar_style = bar;
	b.title_style = title;
	b.title_hover_style = title_hover;
	b.title_open_style = title_open;
	return b;
}

// with_panel_styles sets the dropdown's colours: the panel, an item, the
// current item and the shortcuts.
fn MenuBar MenuBar.with_panel_styles(self, glaze::Style panel, glaze::Style item_s,
		glaze::Style item_selected, glaze::Style shortcut) {
	MenuBar b = self;
	b.panel_style = panel;
	b.item_style = item_s;
	b.item_selected_style = item_selected;
	b.shortcut_style = shortcut;
	return b;
}

// with_shapes sets the shapes a window draws the bar, titles, items and
// dropdown with.
fn MenuBar MenuBar.with_shapes(self, xray::Decoration bar, xray::Decoration title, xray::Decoration item_d,
		xray::Decoration panel) {
	MenuBar b = self;
	b.bar_shape = bar;
	b.title_shape = title;
	b.item_shape = item_d;
	b.panel_shape = panel;
	return b;
}

fn MenuBar MenuBar.with_panel_shadow(self, xray::Shadow s) {
	MenuBar b = self;
	b.panel_shadow = s;
	return b;
}

fn MenuBar MenuBar.with_keyboard_focus(self, bool on = true) {
	MenuBar b = self;
	b.keyboard_focus = on;
	return b;
}

fn MenuBar MenuBar.with_titles_with_native(self, bool on) {
	MenuBar b = self;
	b.titles_with_native = on;
	return b;
}

// is_active reports whether the bar has the keyboard: the current title is
// highlighted and the arrows move along the bar.
fn bool MenuBar.is_active(&self) {
	return self.open || self.active || (self.keyboard_focus && milktea::is_focused(self));
}

// activate gives the bar the keyboard, and deactivate takes it away.
fn void MenuBar.activate(&self) {
	self.active = true;
	if (self.keyboard_focus) milktea::focus(self);
}

fn void MenuBar.deactivate(&self) {
	self.active = false;
	self.open = false;
	if (self.keyboard_focus && milktea::is_focused(self)) milktea::blur();
}

fn void MenuBar.dismiss(&self) => self.deactivate();

// current_item is the highlighted item of the open menu.
fn MenuItem MenuBar.current_item(&self) {
	if (self.selected >= self.menus.len) return {};
	MenuItem[] items = self.menus[self.selected].items;
	return self.item < items.len ? items[self.item] : (MenuItem){};
}

// ---- update ----------------------------------------------------------------

// update is the bar's part of the model's update: call it first and act on
// PICKED. It handles a platform menu pick, a click or hover on the bar (whose
// outcome it reports on the next message, the mouse one), the keyboard
// while the bar has it, and items' shortcuts at any time.
fn MenuEvent MenuBar.update(&self, milktea::Msg msg) {
	switch (msg.kind) {
		case milktea::MsgKind.MENU:
			return self.picked_by_id(msg.tag);
		case milktea::MsgKind.MOUSE:
			MenuEvent p = self.pending;
			self.pending = {};
			return p;
		case milktea::MsgKind.KEY:
			return self.key(msg.key);
		default:
			return {};
	}
}

fn MenuEvent MenuBar.picked_by_id(&self, int id) @private {
	foreach (m : self.menus) {
		foreach (it : m.items) {
			if (!it.separator && it.id == id) return { .kind = PICKED, .id = id, .item = it };
		}
	}
	return {};
}

fn MenuEvent MenuBar.picked(&self) @private {
	MenuItem it = self.current_item();
	self.deactivate();
	if (it.separator || it.label.len == 0) return { .kind = DISMISSED };
	return { .kind = PICKED, .id = it.id, .item = it };
}

fn MenuEvent MenuBar.key(&self, milktea::KeyMsg k) @private {
	if (k.action == milktea::KeyAction.KEY_RELEASE) return {};
	if (self.open) return self.key_open(k);
	if (self.is_active()) return self.key_bar(k);
	if (k.code == milktea::KeyCode.F10) {
		self.activate();
		return { .kind = CONSUMED };
	}
	// Shortcuts: Ctrl+key, or the Cmd/Super key where the window reports it
	// (on macOS the platform menu takes ⌘ shortcuts before they get here).
	if (k.code == milktea::KeyCode.RUNE && (k.ctrl || k.super) && !k.alt) {
		uint r = lower(k.rune);
		foreach (m : self.menus) {
			foreach (it : m.items) {
				if (!it.separator && it.key != 0 && lower(it.key) == r) {
					return { .kind = PICKED, .id = it.id, .item = it };
				}
			}
		}
	}
	return {};
}

fn uint lower(uint c) @private => c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c;

fn MenuEvent MenuBar.key_bar(&self, milktea::KeyMsg k) @private {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			self.step_title(-1);
		case milktea::KeyCode.RIGHT:
			self.step_title(1);
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.ENTER:
			self.open_menu(self.selected);
		case milktea::KeyCode.ESC:
		case milktea::KeyCode.F10:
			self.deactivate();
			return { .kind = DISMISSED };
		default:
			return {};
	}
	return { .kind = CONSUMED };
}

fn MenuEvent MenuBar.key_open(&self, milktea::KeyMsg k) @private {
	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.deactivate();
			return { .kind = DISMISSED };
		case milktea::KeyCode.UP:
			self.step_item(-1);
		case milktea::KeyCode.DOWN:
			self.step_item(1);
		case milktea::KeyCode.LEFT:
			self.step_title(-1);
			self.open_menu(self.selected);
		case milktea::KeyCode.RIGHT:
			self.step_title(1);
			self.open_menu(self.selected);
		case milktea::KeyCode.ENTER:
			return self.picked();
		default:
			return {};
	}
	return { .kind = CONSUMED };
}

fn void MenuBar.step_title(&self, sz d) @private {
	sz n = self.menus.len;
	if (n == 0) return;
	self.selected = (self.selected + d + n) % n;
}

// step_item moves to the next item that is not a separator.
fn void MenuBar.step_item(&self, sz d) @private {
	if (self.selected >= self.menus.len) return;
	MenuItem[] items = self.menus[self.selected].items;
	sz i = self.item;
	for (sz tries = 0; tries < items.len; tries++) {
		i += d;
		if (i < 0 || i >= items.len) return;
		if (!items[i].separator) {
			self.item = i;
			return;
		}
	}
}

fn void MenuBar.open_menu(&self, sz index) @private {
	if (index < 0 || index >= self.menus.len) return;
	self.selected = index;
	self.open = true;
	self.item = 0;
	MenuItem[] items = self.menus[index].items;
	while (self.item < items.len && items[self.item].separator) self.item++;
}

// ---- mouse ------------------------------------------------------------------

fn void menubar_title_clicked(void* id, String id_str, sz col, sz row) @private {
	MenuTitleSlot* slot = (MenuTitleSlot*)id;
	MenuBar* b = slot.bar;
	b.title_press = true;
	// Clicking the open menu's title closes it, the way a platform menu bar
	// does; any other title moves to it and stays open.
	if (b.open && b.selected == slot.index) {
		b.deactivate();
		b.pending = { .kind = DISMISSED };
		return;
	}
	b.activate();
	b.open_menu(slot.index);
	b.pending = { .kind = CONSUMED };
}

// While a menu is open the pointer drives it as in a platform menu bar:
// moving onto another title opens that one.
fn void menubar_title_hovered(void* id, String id_str, sz col, sz row) @private {
	MenuTitleSlot* slot = (MenuTitleSlot*)id;
	MenuBar* b = slot.bar;
	if (b.open && b.selected != slot.index) b.open_menu(slot.index);
}

fn void menubar_item_clicked(void* id, String id_str, sz col, sz row) @private {
	MenuItemSlot* slot = (MenuItemSlot*)id;
	MenuBar* b = slot.bar;
	if (b.selected >= b.menus.len || slot.index >= b.menus[b.selected].items.len) return;
	if (b.menus[b.selected].items[slot.index].separator) return;
	b.item = slot.index;
	b.pending = b.picked();
}

fn void menubar_item_hovered(void* id, String id_str, sz col, sz row) @private {
	MenuItemSlot* slot = (MenuItemSlot*)id;
	MenuBar* b = slot.bar;
	if (b.selected >= b.menus.len || slot.index >= b.menus[b.selected].items.len) return;
	if (!b.menus[b.selected].items[slot.index].separator) b.item = slot.index;
}

fn void menubar_dismissed(void* id, String id_str, sz col, sz row) @private {
	MenuBar* b = (MenuBar*)id;
	// A title already handled this press — it moved the menu or closed it —
	// and the panel must not undo that.
	if (b.title_press) return;
	b.deactivate();
	b.pending = { .kind = DISMISSED };
}

fn void menubar_minimize(void* id, String id_str, sz col, sz row) @private => milktea::minimize_window();
fn void menubar_zoom(void* id, String id_str, sz col, sz row) @private => milktea::zoom_window();
fn void menubar_close(void* id, String id_str, sz col, sz row) @private => milktea::request_quit();

// ---- view -------------------------------------------------------------------

fn bool in_window() @private => milktea::layout_metrics().pixels;

// bar_height is the bar's height in a window: a row, at least tall enough
// for the window buttons, plus bar_shape's padding.
fn sz MenuBar.bar_height(&self) @private {
	sz h = milktea::layout_metrics().unit_h();
	if (h < MENU_BAR_MIN_HEIGHT) h = MENU_BAR_MIN_HEIGHT;
	return h;
}

// publish puts the menus in the platform's menu bar, once per set of menus.
fn void MenuBar.publish(&self) @private {
	if (self.published) return;
	self.published = true;
	if (!milktea::has_native_menus()) return;
	milktea::NativeMenu[] native = mem::temp_array(milktea::NativeMenu, self.menus.len);
	foreach (i, m : self.menus) {
		milktea::NativeMenuItem[] items = mem::temp_array(milktea::NativeMenuItem, m.items.len);
		foreach (j, it : m.items) {
			items[j] = { .label = it.label, .key = it.key, .id = it.id, .separator = it.separator };
		}
		native[i] = { .title = m.title, .items = items };
	}
	milktea::set_native_menus(native);
}

// width_px is how wide a node with a fixed width is, in layout units; a
// node sized any other way counts as 0.
fn sz width_of(xray::Node* n) @private {
	if (n == null) return 0;
	xray::Constraint c = n.size_w;
	if (c.kind != xray::ConstraintKind.CLEN) return 0;
	xray::LayoutMetrics m = milktea::layout_metrics();
	if (c.pixel_units) return m.pixels ? c.value : c.cell_fallback * m.unit_w();
	return c.value * m.unit_w();
}

// node is the bar: the window controls' room, lead, the titles, the empty
// part that moves the window, trail, and drawn controls where the platform
// has none. lead and trail need a fixed width (cells() or pixels()) for the
// dropdowns to line up with their titles.
fn xray::Node* MenuBar.node(&self, xray::Node* lead = null, xray::Node* trail = null) {
	self.publish();
	self.title_press = false;
	bool window = in_window();
	milktea::WindowChrome chrome = milktea::window_chrome();

	xray::Node* row = milktea::hstack().style(self.bar_style).id_with(self);
	if (self.keyboard_focus) row.focusable();
	if (window && self.bar_shape.kind != xray::DecorationKind.NONE) {
		sz h = self.bar_height();
		row.height(xray::pixels(h, 1)).decorate(self.bar_shape);
		milktea::set_window_chrome_height(h + self.bar_shape.pad_top + self.bar_shape.pad_bottom);
	} else {
		row.height(milktea::cells(1));
		if (window) milktea::set_window_chrome_height(self.bar_height());
	}

	if (chrome.left > 0) row.add(milktea::hstack().width(xray::pixels(chrome.left)).window_drag());
	if (lead) row.add(lead);

	bool titles = self.titles_with_native || !milktea::has_native_menus();
	if (titles) {
		foreach (i, m : self.menus) {
			self.title_slots[i] = { .bar = self, .index = i };
			bool current = self.is_active() && i == self.selected;
			glaze::Style s = current ? self.title_open_style : self.title_style;
			// The title's colours are its box's, which the label inherits, so
			// the hover bg reaches it; in a window title_shape gives it a shape.
			xray::Node* t = milktea::text(m.title, { .bold = s.bold, .italic = s.italic, .underline = s.underline })
				.style({ .bg = s.bg, .fg = s.fg }, hover: current ? (glaze::Style){} : self.title_hover_style)
				.fit_width();
			if (self.title_shape.kind != xray::DecorationKind.NONE) t.decorate(self.title_shape);
			t.id_with(&self.title_slots[i]).on_click(&menubar_title_clicked).on_hover_in(&menubar_title_hovered);
			row.add(t);
		}
	}
	row.add(milktea::hstack().fill(1).window_drag());
	if (trail) row.add(trail);
	if (chrome.drawn) row.add(self.controls());
	return row;
}

// controls are minimise, maximise and close, for a window whose platform
// draws none in the app's own bar.
fn xray::Node* MenuBar.controls(&self) @private {
	glaze::Style s = self.controls_style;
	return milktea::hstack().width(milktea::cells(9))
		.add(milktea::text(" – ", s).width(milktea::cells(3)).on_click(&menubar_minimize))
		.add(milktea::text(" □ ", s).width(milktea::cells(3)).on_click(&menubar_zoom))
		.add(milktea::text(" × ", s).width(milktea::cells(3)).on_click(&menubar_close));
}

// dropdown is the open menu, or null when none is: add it over the rest of
// the view, after it. It assumes the bar is the view's top row.
fn xray::Node* MenuBar.dropdown(&self, xray::Node* lead = null) {
	if (!self.open || self.selected >= self.menus.len) return null;
	bool window = in_window();
	bool shaped = window && self.panel_shape.kind != xray::DecorationKind.NONE;
	xray::LayoutMetrics lm = milktea::layout_metrics();

	// The open title's column, counted in cells from the first title.
	sz title_x = 0;
	for (sz i = 0; i < self.selected; i++) title_x += glaze::string_width(self.menus[i].title);

	// A drawn panel brings its own border; the glyph border's cell stays as
	// padding so the content keeps its place and the panel its size.
	glaze::Style ps = self.panel_style;
	if (shaped) {
		if (ps.border.left.len > 0) ps.pad_left++;
		if (ps.border.right.len > 0) ps.pad_right++;
		ps.border = {};
	}
	xray::Node* panel = milktea::vstack().style(ps).min_width(self.min_panel_width);
	if (shaped) {
		panel.decorate(self.panel_shape);
	} else if (self.panel_shadow.enabled) {
		panel.shadow(self.panel_shadow);
	}
	panel.id_with(self).on_click_outside(&menubar_dismissed);

	foreach (i, it : self.menus[self.selected].items) {
		self.item_slots[i] = { .bar = self, .index = i };
		xray::Node* r = self.item_row(it, i == self.item);
		r.id_with(&self.item_slots[i]).on_click(&menubar_item_clicked).on_hover_in(&menubar_item_hovered);
		panel.add(r);
	}

	if (!window) return panel.at(width_of(lead) / lm.unit_w() + title_x, 1);
	// In a window the bar may be taller than a row and start after the window
	// buttons and lead, by amounts in points: the panel is placed in whole
	// cells and the rest is padding on a stack around it.
	sz bar_h = self.bar_height() + self.bar_shape.pad_top + self.bar_shape.pad_bottom;
	sz left = self.bar_shape.pad_left + milktea::window_chrome().left + width_of(lead);
	xray::Decoration inset;
	return milktea::root()
		.decorate(inset.padding(bar_h - lm.unit_h(), 0, 0, left))
		.add(panel.at(title_x, 1));
}

fn xray::Node* MenuBar.item_row(&self, MenuItem it, bool current) @private {
	glaze::Style s = current ? self.item_selected_style : self.item_style;
	xray::Node* r = milktea::hstack()
		.style({ .bg = s.bg, .fg = s.fg, .pad_left = MENU_ITEM_PAD, .pad_right = MENU_ITEM_PAD })
		.height(milktea::cells(1));
	if (self.item_shape.kind != xray::DecorationKind.NONE) r.decorate(self.item_shape);
	if (it.separator) {
		// Long enough for any panel; the row clips it to its width.
		return r.add(milktea::text("────────────────────────────────────────────────────────────",
			{ .fg = self.shortcut_style.fg }).fill(1));
	}
	r.with_justify(xray::JustifyContent.JUSTIFY_SPACE_BETWEEN).with_gap(MENU_ITEM_GAP)
		.add(milktea::text(it.label, { .bold = s.bold }).fit_width());
	if (it.key != 0) {
		// The current item's colours win over the shortcut's dimmer ones.
		glaze::Style ks = current ? (glaze::Style){ .bold = s.bold } : self.shortcut_style;
		ks.bg = {};
		r.add(milktea::text(shortcut_label(it.key), ks).fit_width());
	}
	return r;
}

// shortcut_label is how an item's shortcut reads: ⌘N where the platform's
// menu bar takes it, Ctrl+N elsewhere.
fn String shortcut_label(uint key) {
	uint k = key >= 'a' && key <= 'z' ? key - 'a' + 'A' : key;
	char[4] buf;
	sz n = conv::char32_to_utf8(k, buf[..]) ?? 0;
	String ch = (String)buf[:n];
	return milktea::has_native_menus() ? string::tformat("⌘%s", ch) : string::tformat("Ctrl+%s", ch);
}
