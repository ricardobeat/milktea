// dos-app — a DOS-era desktop: menu bar, dropdowns, a bordered content panel,
// a modal dialog and a status line.
//
// The menu, the dialog and its buttons are components (menu.c3, dialog.c3,
// button.c3): each owns its own state, key handling and node, so the model
// below is little more than which tab is showing and what the status line says.
module dos_app;

import milktea;
import glaze;
import xray;
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

// Chrome the layout reserves: the menu bar and status bar are one row each,
// and the content panel sits inside a one-row, two-column margin.
const int BAR_ROWS       = 1;
const int CONTENT_MARGIN = 1;

const int TAB_COUNT = 3;

struct DosModel {
	Menu menu;
	Dialog about;
	int active_tab;
	String status_msg;
}

fn milktea::Cmd DosModel.init(DosModel* self) @dynamic {
	self.menu = new_menu({ " File ", " Edit ", " View ", " Help " });
	self.menu.set_items(0, { {"New", "Ctrl+N"}, {"Open...", "Ctrl+O"}, {"Save", "Ctrl+S"}, {"Exit", "Alt+F4"} });
	self.menu.set_items(1, { {"Undo", "Ctrl+Z"}, {"Cut", "Ctrl+X"}, {"Copy", "Ctrl+C"}, {"Paste", "Ctrl+V"} });
	self.menu.set_items(2, { {"Zoom In", "+"}, {"Zoom Out", "-"}, {"Full Screen", "F11"}, {"Refresh", "F5"} });
	self.menu.set_items(3, { {"Help Topics", "F1"}, {"About milktea...", ""}, {"License", ""}, {"Diagnostics...", ""} });

	self.about = new_dialog("About milktea",
		"A TUI framework for the C3\nprogramming language.\n\nVersion 0.1.0  —  MIT License",
		"  OK  ", "Cancel");

	self.status_msg = "Ready";
	return null;
}

// ─── Update ──────────────────────────────────────────────────────────────────

fn milktea::Cmd DosModel.update(DosModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	if (k.code == milktea::KeyCode.CTRL_C) return milktea::quit();

	// Whichever layer is on top gets the key first. Only when nothing has one
	// open do the app's own shortcuts apply.
	if (self.about.open) return self.handle_dialog(k);
	if (self.menu.open) return self.handle_menu(k);
	return self.handle_desktop(k);
}

fn milktea::Cmd DosModel.handle_dialog(&self, milktea::KeyMsg k) {
	switch (self.about.handle_key(k)) {
		case Pressed.CONFIRMED:
			// Button 0 is OK, 1 is Cancel.
			self.status_msg = self.about.focused == 0 ? "Confirmed" : "Cancelled";
		case Pressed.DISMISSED:
			self.status_msg = "Cancelled";
		default:
	}
	return null;
}

fn milktea::Cmd DosModel.handle_menu(&self, milktea::KeyMsg k) {
	switch (self.menu.handle_key(k)) {
		case Chosen.PICKED:
			return self.run_menu_item(self.menu.current_item().label);
		case Chosen.DISMISSED:
			self.status_msg = "Ready";
		default:
	}
	return null;
}

// run_menu_item acts on a chosen item by name, so adding an item to the menu
// does not mean re-deriving which column and row it landed on.
fn milktea::Cmd DosModel.run_menu_item(&self, String label) {
	switch (label) {
		case "Exit":
			return milktea::quit();
		case "About milktea...":
			self.about.show();
		default:
			self.status_msg = "Action: not implemented in demo";
	}
	return null;
}

fn milktea::Cmd DosModel.handle_desktop(&self, milktea::KeyMsg k) {
	if (k.code == milktea::KeyCode.ESC) return milktea::quit();
	if (k.code == milktea::KeyCode.RUNE) {
		if (k.rune == 'q') return milktea::quit();
		if (k.rune >= '1' && k.rune <= '0' + TAB_COUNT) {
			self.active_tab = (int)(k.rune - '1');
			return null;
		}
	}
	self.menu.handle_key(k);
	return null;
}

// ─── View ────────────────────────────────────────────────────────────────────

fn milktea::View DosModel.view(DosModel* self) @dynamic {
	return milktea::draw(milktea::root()
		.add(milktea::vstack()
			.add(self.menu.bar())
			.add(self.content()
				.fill(1)
				.with_padding(CONTENT_MARGIN, CONTENT_MARGIN * 2, 0, CONTENT_MARGIN * 2))
			.add(self.statusbar()))
		// Both return null when closed, and add() ignores a null child, so
		// neither needs a condition here.
		.add(self.menu.dropdown(BAR_ROWS))
		.add(self.about.node()));
}

fn xray::Node* DosModel.content(&self) {
	glaze::Style panel = {
		.fg = glaze::color_hex(C_WHITE), .bg = glaze::color_hex(C_BLUE),
		.border = glaze::DOUBLE, .border_color = glaze::color_hex(C_CYAN),
		.pad_top = 1, .pad_right = 3, .pad_bottom = 1, .pad_left = 3,
	};
	glaze::Style title = { .fg = glaze::color_hex(C_YELLOW), .bold = true };
	glaze::Style body  = { .fg = glaze::color_hex(C_WHITE) };

	String[TAB_COUNT] tab_titles = { "Welcome", "System Info", "Settings" };
	String[TAB_COUNT] tab_bodies = {
		"Welcome to milktea DOS Demo!\n\nThis demonstrates the layout tree:\n  ▸ Menu bar with keyboard navigation\n  ▸ Dropdown menus\n  ▸ Modal dialogs\n  ▸ Drop shadows on any node\n\nUse ← → to navigate menus.\nPress Enter or ↓ to open a menu.\nPress q or ESC to quit.",
		"milktea    TUI event loop & TTY management\nglaze      Styling & string composition\nxray       Layout, cells & rendering\nboba       Reusable widgets\n\nC3 language — fast, safe, C-compatible\nno GC · no runtime · direct C interop\n\nTerminal size: see status bar",
		"Theme         DOS Classic\nColors        True color\nBorder        Double\nMenu style    Cyan bar\nShadows       Enabled\n\n(These are display-only in this demo)",
	};

	String inner = glaze::join_vertical(glaze::Position.LEFT,
		title.render(tab_titles[self.active_tab]),
		body.render(tab_bodies[self.active_tab]));

	return milktea::text(panel, inner);
}

fn xray::Node* DosModel.statusbar(&self) {
	glaze::Style bar  = { .bg = glaze::color_hex(C_CYAN), .fg = glaze::color_hex(C_BLACK) };
	glaze::Style key  = { .bg = glaze::color_hex(C_BLACK), .fg = glaze::color_hex(C_WHITE), .bold = true };
	glaze::Style info = { .bg = glaze::color_hex(C_DARK), .fg = glaze::color_hex(C_GRAY) };

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

fn int main() {
	DosModel m = { };
	return milktea::@run(&m);
}
