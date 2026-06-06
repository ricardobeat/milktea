module dos_app;

import milktea;
import glaze;
import std::io;

const String C_BLUE    = "#0000aa";
const String C_CYAN    = "#00aaaa";
const String C_WHITE   = "#ffffff";
const String C_GRAY    = "#aaaaaa";
const String C_DARK    = "#000055";
const String C_SHADOW  = "#111111";
const String C_YELLOW  = "#ffff55";
const String C_BLACK   = "#000000";
const String C_RED     = "#aa0000";

// Focus layers: menubar > dropdown > modal
enum Focus { MENU, DROPDOWN, MODAL }

struct DosModel {
	int   width;
	int   height;
	int   menu_sel;      // 0=File 1=Edit 2=View 3=Help
	bool  dropdown_open;
	int   dropdown_sel;  // item within open menu
	bool  modal_open;
	int   modal_btn;     // 0=OK 1=Cancel
	Focus focus;
	// Content area
	int   active_tab;
	String status_msg;
}

const String[4] MENU_NAMES = { " File ", " Edit ", " View ", " Help " };
const int[4]    MENU_X     = { 2, 8, 14, 20 };  // col offsets of menu titles in menubar

const String[4] FILE_ITEMS = { "New       Ctrl+N", "Open...   Ctrl+O", "Save      Ctrl+S", "Exit      Alt+F4" };
const String[4] EDIT_ITEMS = { "Undo      Ctrl+Z", "Cut       Ctrl+X", "Copy      Ctrl+C", "Paste     Ctrl+V" };
const String[4] VIEW_ITEMS = { "Zoom In        +", "Zoom Out       -", "Full Screen  F11", "Refresh     F5 " };
const String[4] HELP_ITEMS = { "Help Topics    F1", "About milktea...", "License       ",   "Diagnostics..."  };

fn milktea::Cmd DosModel.init(DosModel* self) @dynamic {
	self.status_msg = "Ready";
	return null;
}

fn milktea::Cmd DosModel.update(DosModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width  = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	// Modal is top-priority
	if (self.modal_open) {
		switch (k.code) {
			case milktea::KeyCode.CTRL_C:
			case milktea::KeyCode.ESC:
				self.modal_open  = false;
				self.focus       = Focus.MENU;
				self.status_msg  = "Cancelled";
			case milktea::KeyCode.TAB:
				self.modal_btn   = self.modal_btn == 0 ? 1 : 0;
			case milktea::KeyCode.LEFT:
				self.modal_btn   = 0;
			case milktea::KeyCode.RIGHT:
				self.modal_btn   = 1;
			case milktea::KeyCode.ENTER:
				if (self.modal_btn == 0) {
					self.modal_open = false;
					self.focus      = Focus.MENU;
					self.status_msg = "Confirmed! (nothing actually happened)";
				} else {
					self.modal_open = false;
					self.focus      = Focus.MENU;
					self.status_msg = "Cancelled";
				}
			case milktea::KeyCode.RUNE:
				if (k.rune == 'q') {
					self.modal_open = false;
					self.focus      = Focus.MENU;
					self.status_msg = "Cancelled";
				}
			default:
		}
		return null;
	}

	// Dropdown is next
	if (self.dropdown_open) {
		switch (k.code) {
			case milktea::KeyCode.CTRL_C: return milktea::quit();
			case milktea::KeyCode.ESC:
				self.dropdown_open = false;
				self.focus         = Focus.MENU;
			case milktea::KeyCode.UP:
				if (self.dropdown_sel > 0) self.dropdown_sel--;
			case milktea::KeyCode.DOWN:
				if (self.dropdown_sel < 3) self.dropdown_sel++;
			case milktea::KeyCode.LEFT:
				if (self.menu_sel > 0) self.menu_sel--;
				self.dropdown_sel = 0;
			case milktea::KeyCode.RIGHT:
				if (self.menu_sel < 3) self.menu_sel++;
				self.dropdown_sel = 0;
			case milktea::KeyCode.ENTER:
				// "About" action opens modal, others set status
				if (self.menu_sel == 3 && self.dropdown_sel == 1) {
					self.dropdown_open = false;
					self.modal_open    = true;
					self.modal_btn     = 0;
					self.focus         = Focus.MODAL;
				} else if (self.menu_sel == 0 && self.dropdown_sel == 3) {
					return milktea::quit();
				} else {
					self.dropdown_open = false;
					self.focus         = Focus.MENU;
					self.status_msg    = "Action: not implemented in demo";
				}
			case milktea::KeyCode.RUNE:
				if (k.rune == 'q') return milktea::quit();
			default:
		}
		return null;
	}

	// Menu bar
	switch (k.code) {
		case milktea::KeyCode.CTRL_C: return milktea::quit();
		case milktea::KeyCode.LEFT:
			if (self.menu_sel > 0) self.menu_sel--;
		case milktea::KeyCode.RIGHT:
			if (self.menu_sel < 3) self.menu_sel++;
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.ENTER:
			self.dropdown_open = true;
			self.dropdown_sel  = 0;
			self.focus         = Focus.DROPDOWN;
		case milktea::KeyCode.ESC: return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'h') { if (self.menu_sel > 0) self.menu_sel--; }
			if (k.rune == 'l') { if (self.menu_sel < 3) self.menu_sel++; }
			if (k.rune == '1') { self.active_tab = 0; }
			if (k.rune == '2') { self.active_tab = 1; }
			if (k.rune == '3') { self.active_tab = 2; }
		default:
	}
	return null;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

// Build a shadowed panel: returns {panel_layer, shadow_layer} via compositor layers.
// shadow is at z=0, panel at z=1. Both positioned at (x, y) — shadow auto-offset.
fn void add_shadowed(milktea::Compositor* comp, String panel_str, int x, int y, int z) {
	// Measure panel width and height by splitting on newlines and using string_width per line.
	int pw = 0;
	int ph = 0;
	sz start = 0;
	for (sz i = 0; i <= panel_str.len; i++) {
		if (i == panel_str.len || panel_str[i] == '\n') {
			int lw = glaze::string_width(panel_str[start:i - start]);
			if (lw > pw) pw = lw;
			ph++;
			start = i + 1;
		}
	}

	glaze::Style shadow_style = glaze::new_style()
		.background(glaze::color_hex(C_SHADOW))
		.set_width(pw)
		.set_height(ph);
	String shadow_str = shadow_style.render("");

	comp.add_layer(milktea::new_layer(shadow_str).set_x(x + 2).set_y(y + 1).set_z(z));
	comp.add_layer(milktea::new_layer(panel_str).set_x(x).set_y(y).set_z(z + 1));
}

// dos_button renders a classic DOS-style raised button with drop shadow.
//
// Layout (face_w = label.len + 4, pad 2 each side):
//
//   col:   0 … face_w-1  face_w  face_w+1
//   row 0: [  face  ···]  [█]     [ ]
//   row 1: [ ]  [▄ ··· ▄  ▄]
//
// Row 0: face (bg=FACE, fg=TXT) + full-block right shadow (bg=SHADOW, fg=SHADOW) + bare space
// Row 1: bare space + lower-half-block bottom+corner shadow (fg=SHADOW, bg=PANEL)
//
// Both rows are face_w+2 wide so join_* sees equal widths.
// Focus changes FACE color (yellow focused, C_GRAY unfocused) and TXT color.
// Shadow is always SHADOW/PANEL — invariant.
fn String dos_button(String label, bool focused) {
	glaze::Color face_col  = glaze::color_hex(focused ? C_YELLOW : C_GRAY);
	glaze::Color txt_col   = glaze::color_hex(focused ? C_BLACK  : C_BLACK);
	glaze::Color shad_col  = glaze::color_hex(C_SHADOW);
	glaze::Color panel_col = glaze::color_hex(C_DARK);

	int face_w = (int)label.len + 4; // 2-space padding each side

	DString out = dstring::temp();

	// ── Row 0: face  [█]  [ ] ────────────────────────────────────────────────
	// Start with explicit reset so face colors are never inherited from context.
	out.append_string("\x1b[0m\x1b[");
	txt_col.write_sgr_params(&out, true);
	out.append_char(';');
	face_col.write_sgr_params(&out, false);
	out.append_string("m  ");
	out.append_string(label);
	out.append_string("  ");
	// right shadow: lower-half block — upper half is panel (gap), lower half is shadow
	out.append_string("\x1b[0m\x1b[");
	shad_col.write_sgr_params(&out, true);
	out.append_char(';');
	panel_col.write_sgr_params(&out, false);
	out.append_string("m\xe2\x96\x84"); // ▄ U+2584 lower half block
	// trailing bare space (col face_w+1) — equalises row width to face_w+2
	out.append_string("\x1b[0m ");

	out.append_char('\n');

	// ── Row 1: [ ]  [▀ × face_w] ────────────────────────────────────────────
	// bare space at col 0 (the 1-block left gap), then bottom shadow
	// ▀ U+2580: fg=SHADOW, bg=PANEL → upper half = shadow, lower half = panel
	// face_w blocks (not face_w+1) — right-shadow column already covers col face_w
	out.append_string("\x1b[0m ");
	out.append_string("\x1b[0m\x1b[");
	shad_col.write_sgr_params(&out, true);
	out.append_char(';');
	panel_col.write_sgr_params(&out, false);
	out.append_string("m");
	for (int i = 0; i < face_w; i++) out.append_string("\xe2\x96\x80"); // ▀ U+2580
	// trailing space to match row 0 width (face_w+2)
	out.append_string("\x1b[0m ");

	return out.copy_str(tmem);
}

fn String get_menu_item(int menu_sel, int item) {
	switch (menu_sel) {
		case 0: return FILE_ITEMS[item];
		case 1: return EDIT_ITEMS[item];
		case 2: return VIEW_ITEMS[item];
		default: return HELP_ITEMS[item];
	}
}

// ─── View ────────────────────────────────────────────────────────────────────

fn milktea::View DosModel.view(DosModel* self) @dynamic {
	int w = self.width;
	int h = self.height;
	if (w < 40) w = 80;
	if (h < 10) h = 24;

	milktea::Compositor* comp = milktea::new_compositor(w, h);

	// ── Background ────────────────────────────────────────────────────────────
	glaze::Style bg_style = glaze::new_style()
		.background(glaze::color_hex(C_BLUE))
		.set_width(w)
		.set_height(h);
	comp.add_layer(milktea::new_layer(bg_style.render("")).set_z(0));

	// ── Menu bar ─────────────────────────────────────────────────────────────
	glaze::Style menubar_style = glaze::new_style()
		.background(glaze::color_hex(C_CYAN))
		.foreground(glaze::color_hex(C_BLACK))
		.set_width(w)
		.set_height(1);

	glaze::Style menu_active_style = glaze::new_style()
		.background(glaze::color_hex(C_BLACK))
		.foreground(glaze::color_hex(C_WHITE))
		.set_bold(true);

	glaze::Style menu_item_style = glaze::new_style()
		.background(glaze::color_hex(C_CYAN))
		.foreground(glaze::color_hex(C_BLACK));

	// Build the full menubar text
	glaze::Style[4] item_styles;
	String[4] rendered_items;
	for (int i = 0; i < 4; i++) {
		rendered_items[i] = i == self.menu_sel
			? menu_active_style.render(MENU_NAMES[i])
			: menu_item_style.render(MENU_NAMES[i]);
	}
	String menubar_content = glaze::join_horizontal_arr(glaze::Position.CENTER, rendered_items[..], 0);
	comp.add_layer(milktea::new_layer(menubar_style.render(menubar_content)).set_z(10));

	// ── Content area ─────────────────────────────────────────────────────────
	int content_x = 2;
	int content_y = 2;
	int content_w = w - 4;
	int content_h = h - 5; // menubar(1) + gap(1) + statusbar(1) + 2 margin

	glaze::Style content_style = glaze::new_style()
		.foreground(glaze::color_hex(C_WHITE))
		.background(glaze::color_hex(C_BLUE))
		.set_border(glaze::double_border())
		.set_border_fg(glaze::color_hex(C_CYAN))
		.set_width(content_w)
		.set_height(content_h)
		.padding(1, 3, 1, 3)
		.align(glaze::Position.LEFT, glaze::Position.TOP);

	String[3] tab_titles = { "Welcome", "System Info", "Settings" };
	String[3] tab_bodies = {
		"Welcome to milktea DOS Demo!\n\nThis demonstrates the glaze compositor:\n  ▸ Menu bar with keyboard navigation\n  ▸ Dropdown menus\n  ▸ Modal dialogs\n  ▸ Drop shadows via layer compositing\n\nUse ← → to navigate menus.\nPress Enter or ↓ to open a menu.\nPress q or ESC to quit.",
		"milktea    TUI event loop & TTY management\nglaze      Styling, layout & compositor\nboba       Reusable widgets\n\nC3 language — fast, safe, C-compatible\nno GC · no runtime · direct C interop\n\nTerminal size: see status bar",
		"Theme         DOS Classic\nColors        True color\nBorder        Double\nMenu style    Cyan bar\nShadows       Enabled\n\n(These are display-only in this demo)",
	};

	glaze::Style title_style = glaze::new_style()
		.foreground(glaze::color_hex(C_YELLOW))
		.set_bold(true);
	glaze::Style body_style = glaze::new_style()
		.foreground(glaze::color_hex(C_WHITE));

	String tab_title = title_style.render(tab_titles[self.active_tab]);
	String tab_body  = body_style.render(tab_bodies[self.active_tab]);
	String inner     = glaze::join_vertical(glaze::Position.LEFT, tab_title, tab_body);
	comp.add_layer(milktea::new_layer(content_style.render(inner)).set_x(content_x).set_y(content_y).set_z(10));

	// ── Status bar ────────────────────────────────────────────────────────────
	glaze::Style status_style = glaze::new_style()
		.background(glaze::color_hex(C_CYAN))
		.foreground(glaze::color_hex(C_BLACK))
		.set_width(w);
	glaze::Style status_key_style = glaze::new_style()
		.background(glaze::color_hex(C_BLACK))
		.foreground(glaze::color_hex(C_WHITE))
		.set_bold(true);

	String size_info = string::tformat("%dx%d", w, h);
	String hint_keys = string::tformat("  %s %s  menus    %s  tabs    %s  quit",
		status_key_style.render("←→"),
		status_key_style.render("↵"),
		status_key_style.render("1-3"),
		status_key_style.render("q"));
	String status_right = string::tformat("  %s  │  %s ", self.status_msg, size_info);
	String status_left  = status_style.render(hint_keys);
	comp.add_layer(milktea::new_layer(status_left).set_x(0).set_y(h - 1).set_z(10));
	// Right-side status info
	glaze::Style status_r_style = glaze::new_style()
		.background(glaze::color_hex(C_DARK))
		.foreground(glaze::color_hex(C_GRAY));
	int srw = glaze::string_width(status_right) + 2;
	comp.add_layer(milktea::new_layer(status_r_style.render(status_right)).set_x(w - srw).set_y(h - 1).set_z(11));

	// ── Dropdown ─────────────────────────────────────────────────────────────
	if (self.dropdown_open) {
		glaze::Style dd_style = glaze::new_style()
			.background(glaze::color_hex(C_CYAN))
			.foreground(glaze::color_hex(C_BLACK))
			.set_border(glaze::normal_border())
			.set_border_fg(glaze::color_hex(C_WHITE))
			.padding(0, 1, 0, 1)
			.set_width(22);

		glaze::Style dd_sel_style = glaze::new_style()
			.background(glaze::color_hex(C_BLACK))
			.foreground(glaze::color_hex(C_YELLOW))
			.set_bold(true)
			.set_width(20);

		glaze::Style dd_item_style = glaze::new_style()
			.background(glaze::color_hex(C_CYAN))
			.foreground(glaze::color_hex(C_BLACK))
			.set_width(20);

		String[4] rows;
		for (int i = 0; i < 4; i++) {
			rows[i] = i == self.dropdown_sel
				? dd_sel_style.render(get_menu_item(self.menu_sel, i))
				: dd_item_style.render(get_menu_item(self.menu_sel, i));
		}
		String dd_content = glaze::join_vertical_arr(glaze::Position.LEFT, rows[..]);
		String dd_panel   = dd_style.render(dd_content);

		int ddx = MENU_X[self.menu_sel];
		add_shadowed(comp, dd_panel, ddx, 1, 20);
	}

	// ── Modal ─────────────────────────────────────────────────────────────────
	if (self.modal_open) {
		int modal_w  = 42;
		int modal_h  = 10;
		int modal_rw = modal_w + 2; // +2 for double border
		int modal_rh = modal_h + 2;
		int modal_x  = (w - modal_rw) / 2;
		int modal_y  = (h - modal_rh) / 2;

		glaze::Style modal_style = glaze::new_style()
			.background(glaze::color_hex(C_DARK))
			.foreground(glaze::color_hex(C_WHITE))
			.set_border(glaze::double_border())
			.set_border_fg(glaze::color_hex(C_YELLOW))
			.set_width(modal_w)
			.set_height(modal_h)
			.padding(1, 2, 1, 2)
			.align(glaze::Position.CENTER, glaze::Position.CENTER);

		glaze::Style modal_title_style = glaze::new_style()
			.foreground(glaze::color_hex(C_YELLOW))
			.set_bold(true);

		String btn_ok     = dos_button("  OK  ", self.modal_btn == 0);
		String btn_cancel = dos_button("Cancel", self.modal_btn == 1);
		String buttons    = glaze::join_horizontal_arr(glaze::Position.CENTER, { btn_ok, btn_cancel }, 2);

		String modal_title = modal_title_style.render("About milktea");
		String modal_body  = "A Bubble Tea-inspired TUI framework\nfor the C3 programming language.\n\nVersion 0.1.0  —  MIT License";
		String modal_inner = glaze::join_vertical_arr(glaze::Position.LEFT,
			{ modal_title, "", modal_body, "", buttons });
		String modal_panel = modal_style.render(modal_inner);

		add_shadowed(comp, modal_panel, modal_x, modal_y, 30);
	}

	return comp.render();
}

fn int main() {
	DosModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
