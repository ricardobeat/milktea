// cursors — gallery of custom draw-cursor effects and native cursor shapes.
// 
// Section A: draw-cursor callbacks — paint arbitrary strings at cursor position.
// Section B: native terminal cursor shapes + OSC 12 color.
// 
// Tab / Shift+Tab cycles focus. q or Ctrl+C to quit.
module cursors;

import milktea;
import glaze;
import xray;
import boba;
import std::io;

// ── section A: draw-cursor callbacks ─────────────────────────────────────────

fn String cursor_fire(int x, int y, bool blink, String under) {
	return blink ? "🔥" : "";
}

fn String cursor_skull(int x, int y, bool blink, String under) {
	return blink ? "💀" : "";
}

fn String cursor_crosshair(int x, int y, bool blink, String under) {
	if (!blink && under.len > 0) return under;
	return blink ? "\x1b[1;33m✛\x1b[0m" : "\x1b[2;33m✛\x1b[0m";
}

fn String cursor_snake(int x, int y, bool blink, String under) {
	long now  = milktea::time_ms();
	int phase = (int)((now / 150) % 4);
	switch (phase) {
		case 0: return "█";
		case 1: return "▓";
		case 2: return "▒";
		default: return "░";
	}
}

fn String cursor_rainbow(int x, int y, bool blink, String under) {
	long now = milktea::time_ms();
	double t = ((double)(now % 1500)) / 1500.0;
	return glaze::style().foreground(glaze::hcl(t * 360.0, 100.0, 60.0)).render("█");
}

fn String cursor_matrix(int x, int y, bool blink, String under) {
	if (!blink && under.len > 0) return under;
	long now = milktea::time_ms();
	int idx  = (int)(((now / 80) + (long)x * 7 + (long)y * 13) % 48);
	uint cp  = 0x30A1u + (uint)idx; // katakana block
	char[4] buf;
	sz len;
	if (cp < 0x800u) {
		buf[0] = (char)(0xC0u | (cp >> 6));
		buf[1] = (char)(0x80u | (cp & 0x3Fu));
		len = 2;
	} else {
		buf[0] = (char)(0xE0u | (cp >> 12));
		buf[1] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
		buf[2] = (char)(0x80u | (cp & 0x3Fu));
		len = 3;
	}
	return string::tformat("\x1b[1;32m%s\x1b[0m", (String)buf[:len]);
}

// ── entry types ───────────────────────────────────────────────────────────────

struct Entry {
	// label is the small-caps name shown before the input box, e.g. "ꜰɪʀᴇ".
	String label;
	String border_color;
	// The input owns how its cursor looks — a draw callback for section A,
	// a terminal shape and color for section B — so this example only has to
	// place it in the tree and the cursor follows.
	boba::TextInput input;
}

// style_input returns a bordered text-input style for the given border color.
fn glaze::Style style_input(String bc, bool focused) {
	glaze::Style s = glaze::style()
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex(bc))
		.align(glaze::Position.LEFT, glaze::Position.CENTER);
	return focused ? s.foreground(glaze::color_hex("#ffffff")) : s.foreground(glaze::color_hex("#555555"));
}

// ── model ─────────────────────────────────────────────────────────────────────

const int N = 10;

// Layout measurements, named rather than inlined so the shape of the page is
// readable in one place.
const int TOP_MARGIN  = 1;  // blank row above the title
const int SIDE_MARGIN = 2;  // breathing room at the page edges
const int TITLE_GAP   = 2;  // rows between the title and the columns
const int COL_GAP     = 2;  // columns between the two entry columns
const int ROW_GAP     = 1;  // rows between entry boxes
const int NAME_GAP    = 1;  // columns between a name and its box
const int NAME_COLS   = 10; // width of the name column
const int BOX_ROWS    = 3;  // top border, content, bottom border

struct Model {
	Entry[N] entries;
	int focused;
}

// Section A entries paint their own cursor; section B entries use the
// terminal's, with a shape and color. Either way it is the input that carries
// the setting, and the layout decides where it lands.
fn milktea::Cmd Model.init(&self) @dynamic {
	self.add_drawn(0, "fire",      "#ff4400", &cursor_fire,      400);
	self.add_drawn(1, "skull",     "#888888", &cursor_skull,     500);
	self.add_drawn(2, "crosshair", "#ff8800", &cursor_crosshair, 250);
	self.add_drawn(3, "snake",     "#00ffaa", &cursor_snake,     150);
	self.add_drawn(4, "rainbow",   "#ff00ff", &cursor_rainbow,   100);
	self.add_drawn(5, "matrix",    "#00ff44", &cursor_matrix,     80);

	self.add_native(6, "block",     "#4488ff", milktea::CursorShape.CURSOR_BLOCK,     "",        true);
	self.add_native(7, "underline", "#44ccff", milktea::CursorShape.CURSOR_UNDERLINE, "#00ccff", true);
	self.add_native(8, "bar",       "#ff44cc", milktea::CursorShape.CURSOR_BAR,       "#ff44cc", true);
	self.add_native(9, "steady",    "#ffaa00", milktea::CursorShape.CURSOR_BLOCK,     "#ffaa00", false);

	return null;
}

fn void Model.add_drawn(&self, int i, String label, String bc, xray::DrawCursorFn draw, int blink_ms) {
	self.entries[i] = { .label = label, .border_color = bc, .input = new_input(bc) };
	self.entries[i].input.cursor_draw = draw;
	self.entries[i].input.cursor_blink_ms = blink_ms;
}

fn void Model.add_native(&self, int i, String label, String bc,
	milktea::CursorShape shape, String color, bool blink)
{
	self.entries[i] = { .label = label, .border_color = bc, .input = new_input(bc) };
	self.entries[i].input.cursor_shape = shape;
	self.entries[i].input.cursor_color = color;
	self.entries[i].input.cursor_blink = blink;
}

fn boba::TextInput new_input(String bc) {
	return boba::new_text_input()
		.with_styles(style_input(bc, true), style_input("#333333", false));
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	// No tick here: an animated cursor asks for its own repaints through the
	// interval it reports, so the app only responds to input.
	switch (msg.kind) {
		case milktea::MsgKind.KEY:
			milktea::KeyMsg k = msg.key;
			switch (k.code) {
				case milktea::KeyCode.CTRL_C:
				case milktea::KeyCode.ESC:
					return milktea::quit();
				case milktea::KeyCode.RUNE:
					if (k.rune == 'q') return milktea::quit();
					// delegate to the component (UTF-8-aware)
					self.entries[self.focused].input.handle_key(k);
				case milktea::KeyCode.BACKSPACE:
				case milktea::KeyCode.DELETE:
				case milktea::KeyCode.LEFT:
				case milktea::KeyCode.RIGHT:
				case milktea::KeyCode.HOME:
				case milktea::KeyCode.END:
					self.entries[self.focused].input.handle_key(k);
				case milktea::KeyCode.TAB:
					self.focused = k.shift ? (self.focused + N - 1) % N : (self.focused + 1) % N;
				default:
			}
		default:
	}
	return null;
}

fn milktea::View Model.view(&self) @dynamic {
	String title = "\x1b[1;37m  CURSOR GALLERY\x1b[0m  \x1b[2;37m tab/shift+tab · q quit\x1b[0m";

	milktea::Node* body = milktea::hstack().with_gap(COL_GAP);
	body.add(self.column(0));
	body.add(self.column(N / 2));

	return milktea::draw(milktea::root()
		.add(milktea::vstack()
			.with_gap(TITLE_GAP)
			.with_padding(TOP_MARGIN, SIDE_MARGIN, 0, SIDE_MARGIN)
			.add(milktea::text({}, title).height(milktea::cells(1)))
			.add(body.fill(1))));
}

// column builds one stack of entry rows, starting at entry `first`.
fn milktea::Node* Model.column(&self, int first) {
	milktea::Node* col = milktea::vstack().with_gap(ROW_GAP);
	for (int i = first; i < first + N / 2; i++) {
		col.add(self.entry_row(i));
	}
	return col;
}

// entry_row is a right-aligned name beside the input box. The box is three
// rows — border, content, border — and the input reports its cursor against
// the rect the layout hands it, so nothing here counts rows or columns.
fn milktea::Node* Model.entry_row(&self, int i) {
	Entry* e = &self.entries[i];
	bool focused = i == self.focused;

	glaze::Style name_s = glaze::style()
		.foreground(glaze::color_hex(focused ? "#ffffff" : "#555555"))
		.align(glaze::Position.RIGHT, glaze::Position.CENTER);

	e.input.focused = focused;

	return milktea::hstack()
		.height(milktea::cells(BOX_ROWS))
		.with_gap(NAME_GAP)
		.add(milktea::text(name_s, e.label).width(milktea::cells(NAME_COLS)))
		.add(milktea::component(&e.input).fill(1));
}

fn int main() {
	Model m = { };
	return milktea::@run(&m);
}
