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

// Inner width of a dropdown panel, and the modal's outer size.
const int DROPDOWN_INNER = 20;
const int MODAL_COLS     = 44;
const int MODAL_ROWS     = 12;

const String[4] MENU_NAMES = { " File ", " Edit ", " View ", " Help " };
const int[4]    MENU_X     = { 2, 8, 14, 20 };  // col offsets of menu titles in menubar

struct MenuItem { String label; String key; }

const MenuItem[4] FILE_ITEMS = { {"New",         "Ctrl+N"}, {"Open...",    "Ctrl+O"}, {"Save",       "Ctrl+S"}, {"Exit",       "Alt+F4"} };
const MenuItem[4] EDIT_ITEMS = { {"Undo",        "Ctrl+Z"}, {"Cut",        "Ctrl+X"}, {"Copy",       "Ctrl+C"}, {"Paste",      "Ctrl+V"} };
const MenuItem[4] VIEW_ITEMS = { {"Zoom In",     "+"     }, {"Zoom Out",   "-"     }, {"Full Screen","F11"   }, {"Refresh",    "F5"    } };
const MenuItem[4] HELP_ITEMS = { {"Help Topics", "F1"    }, {"About milktea...", ""}, {"License",    ""      }, {"Diagnostics...",""}    };

fn milktea::Cmd DosModel.init(DosModel* self) @dynamic {
	self.status_msg = "Ready";
	return null;
}

fn milktea::Cmd DosModel.update(DosModel* self, milktea::Msg msg) @dynamic {
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

fn MenuItem get_menu_item(int menu_sel, int item) {
	switch (menu_sel) {
		case 0: return FILE_ITEMS[item];
		case 1: return EDIT_ITEMS[item];
		case 2: return VIEW_ITEMS[item];
		default: return HELP_ITEMS[item];
	}
}

fn String render_menu_item(MenuItem mi, glaze::Style base_style, int inner_w) {
	String label = glaze::style().align_horizontal(glaze::Position.LEFT).render(mi.label);
	String key   = glaze::style().align_horizontal(glaze::Position.RIGHT).with_width(inner_w - glaze::string_width(mi.label)).render(mi.key);
	String row   = glaze::join_horizontal(label, key, 0);
	return base_style.render(row);
}

// ─── View ────────────────────────────────────────────────────────────────────

// Chrome the layout reserves: the menu bar and status bar are one row each,
// and the content panel sits inside a one-row, two-column margin.
const int BAR_ROWS       = 1;
const int CONTENT_MARGIN = 1;

fn milktea::View DosModel.view(DosModel* self) @dynamic {
	milktea::Node* root = milktea::root()
		.add(milktea::vstack()
			.add(self.menubar())
			.add(self.content()
				.fill(1)
				.with_padding(CONTENT_MARGIN, CONTENT_MARGIN * 2, 0, CONTENT_MARGIN * 2))
			.add(self.statusbar()));

	// A dropdown hangs off the menu bar and a modal sits over everything. Both
	// are children of the root, so they paint over the layout without it
	// knowing they exist.
	if (self.dropdown_open) root.add(self.dropdown());
	if (self.modal_open) root.add(self.modal());

	return milktea::draw(root);
}

// The desktop behind everything. Painting it as the root's own background
// means the panels above do not each have to carry it.
fn milktea::Node* DosModel.menubar(&self) {
	glaze::Style bar = {
		.bg = glaze::color_hex(C_CYAN), .fg = glaze::color_hex(C_BLACK),
	};
	glaze::Style active = {
		.bg = glaze::color_hex(C_BLACK), .fg = glaze::color_hex(C_WHITE), .bold = true,
	};

	String[4] items;
	for (int i = 0; i < 4; i++) {
		items[i] = (i == self.menu_sel ? active : bar).render(MENU_NAMES[i]);
	}
	String row = glaze::join_horizontal_arr(glaze::Position.CENTER, items[..], 0);

	return milktea::text(bar, row).height(milktea::cells(BAR_ROWS));
}

fn milktea::Node* DosModel.content(&self) {
	glaze::Style panel = {
		.fg = glaze::color_hex(C_WHITE), .bg = glaze::color_hex(C_BLUE),
		.border = glaze::DOUBLE, .border_color = glaze::color_hex(C_CYAN),
		.pad_top = 1, .pad_right = 3, .pad_bottom = 1, .pad_left = 3,
	};
	glaze::Style title = { .fg = glaze::color_hex(C_YELLOW), .bold = true };
	glaze::Style body  = { .fg = glaze::color_hex(C_WHITE) };

	String[3] tab_titles = { "Welcome", "System Info", "Settings" };
	String[3] tab_bodies = {
		"Welcome to milktea DOS Demo!\n\nThis demonstrates the layout tree:\n  ▸ Menu bar with keyboard navigation\n  ▸ Dropdown menus\n  ▸ Modal dialogs\n  ▸ Drop shadows on any node\n\nUse ← → to navigate menus.\nPress Enter or ↓ to open a menu.\nPress q or ESC to quit.",
		"milktea    TUI event loop & TTY management\nglaze      Styling & string composition\nxray       Layout, cells & rendering\nboba       Reusable widgets\n\nC3 language — fast, safe, C-compatible\nno GC · no runtime · direct C interop\n\nTerminal size: see status bar",
		"Theme         DOS Classic\nColors        True color\nBorder        Double\nMenu style    Cyan bar\nShadows       Enabled\n\n(These are display-only in this demo)",
	};

	String inner = glaze::join_vertical(glaze::Position.LEFT,
		title.render(tab_titles[self.active_tab]),
		body.render(tab_bodies[self.active_tab]));

	return milktea::text(panel, inner);
}

fn milktea::Node* DosModel.statusbar(&self) {
	glaze::Style bar = {
		.bg = glaze::color_hex(C_CYAN), .fg = glaze::color_hex(C_BLACK),
	};
	glaze::Style key = {
		.bg = glaze::color_hex(C_BLACK), .fg = glaze::color_hex(C_WHITE), .bold = true,
	};
	glaze::Style info = {
		.bg = glaze::color_hex(C_DARK), .fg = glaze::color_hex(C_GRAY),
	};

	String hints = string::tformat("  %s %s  menus    %s  tabs    %s  quit",
		key.render("←→"), key.render("↵"), key.render("1-3"), key.render("q"));
	String right = string::tformat("  %s  │  %dx%d ",
		self.status_msg, milktea::screen_width(), milktea::screen_height());

	// The hints fill the bar and the info block is pushed to the far end, so
	// neither side needs its width computed.
	return milktea::hstack()
		.height(milktea::cells(BAR_ROWS))
		.add(milktea::text(bar, hints).fill(1))
		.add(milktea::text(info, right).width(milktea::cells(glaze::string_width(right))));
}

// The dropdown opens directly under the menu title that owns it, and sizes
// itself to its items.
fn milktea::Node* DosModel.dropdown(&self) {
	glaze::Style panel = {
		.bg = glaze::color_hex(C_CYAN), .fg = glaze::color_hex(C_BLACK),
		.border = glaze::NORMAL, .border_color = glaze::color_hex(C_WHITE),
		.pad_left = 1, .pad_right = 1,
	};
	glaze::Style selected = {
		.bg = glaze::color_hex(C_BLACK), .fg = glaze::color_hex(C_YELLOW), .bold = true,
	};
	glaze::Style item = {
		.bg = glaze::color_hex(C_CYAN), .fg = glaze::color_hex(C_BLACK),
	};

	String[4] rows;
	for (int i = 0; i < 4; i++) {
		glaze::Style s = (i == self.dropdown_sel ? selected : item).with_width(DROPDOWN_INNER);
		rows[i] = render_menu_item(get_menu_item(self.menu_sel, i), s, DROPDOWN_INNER);
	}
	String content = glaze::join_vertical_arr(glaze::Position.LEFT, rows[..]);

	return milktea::text(panel, content)
		.at(MENU_X[self.menu_sel], BAR_ROWS)
		.shadow(milktea::shadow(2, 1));
}

fn milktea::Node* DosModel.modal(&self) {
	glaze::Style panel = {
		.bg = glaze::color_hex(C_DARK), .fg = glaze::color_hex(C_WHITE),
		.border = glaze::DOUBLE, .border_color = glaze::color_hex(C_YELLOW),
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
		.align_h = glaze::Position.CENTER, .align_v = glaze::Position.CENTER,
	};
	glaze::Style title = { .fg = glaze::color_hex(C_YELLOW), .bold = true };

	String buttons = glaze::join_horizontal_arr(glaze::Position.CENTER, {
		dos_button("  OK  ", self.modal_btn == 0),
		dos_button("Cancel", self.modal_btn == 1),
	}, 2);

	String inner = glaze::join_vertical_arr(glaze::Position.LEFT, {
		title.render("About milktea"),
		"",
		"A TUI framework for the C3\nprogramming language.\n\nVersion 0.1.0  —  MIT License",
		"",
		buttons,
	});

	return milktea::text(panel, inner)
		.width(milktea::cells(MODAL_COLS))
		.height(milktea::cells(MODAL_ROWS))
		.center()
		.shadow(milktea::shadow(2, 1));
}

fn int main() {
	DosModel m = { };
	return milktea::@run(&m);
}
