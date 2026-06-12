module component_viewer;

import milktea;
import glaze;
import boba;
import xray;
import xray::layout;
import std::io;
import std::core::string;
import std::core::dstring;

// Component viewer — full-screen TUI that lists every boba component on
// the left and renders a live preview of the selected one on the right.
//
// The screen is laid out with xray::layout (vstack + hstack) and each
// pane is rendered into its rect with glaze::Style.render_in:
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ header (1 row, len)                                         │
//   ├──────────┬───────────────────────────────────────────────────┤
//   │ sidebar  │  preview                                          │
//   │ (len=22) │  (fill=remaining)                                 │
//   ├──────────┴───────────────────────────────────────────────────┤
//   │ footer (1 row, len)                                         │
//   └──────────────────────────────────────────────────────────────┘
//
// Animated components (spinner, stopwatch, timer) tick from the
// model's TICK handler so their previews visibly move while idle.

// ─── Component catalogue ──────────────────────────────────────────────────────
// One entry per boba component file (boba/*.c3, excluding boba_snapshot.c3).

const int COMPONENT_COUNT = 14;

const String[COMPONENT_COUNT] NAMES = {
	"Cursor",        // 0  — boba/cursor.c3
	"FilePicker",    // 1  — boba/filepicker.c3
	"Help",          // 2  — boba/help.c3
	"KeyMap",        // 3  — boba/key.c3
	"List",          // 4  — boba/list.c3
	"Pagination",    // 5  — boba/pagination.c3
	"Progress",      // 6  — boba/progress.c3
	"Spinner",       // 7  — boba/spinner.c3
	"Stopwatch",     // 8  — boba/stopwatch.c3
	"Table",         // 9  — boba/table.c3
	"Textarea",      // 10 — boba/textarea.c3
	"TextInput",     // 11 — boba/textinput.c3
	"Timer",         // 12 — boba/timer.c3
	"Viewport",      // 13 — boba/viewport.c3
};

const String[COMPONENT_COUNT] DESCS = {
	"text position",
	"file browser",
	"key/desc pairs",
	"key bindings",
	"scrollable list",
	"page navigation",
	"fill bar",
	"animated indicator",
	"count-up",
	"rows + columns",
	"multi-line input",
	"single-line input",
	"countdown",
	"scrollable region",
};

// Indices of components that support interactive keyboard focus.
fn bool is_interactive(int idx) {
	switch (idx) {
		case 1: return true;
		case 4: return true;
		case 5: return true;
		case 9: return true;
		case 10: return true;
		case 11: return true;
		case 13: return true;
		default: return false;
	}
}

// ─── Per-component static previews ────────────────────────────────────────────

fn String preview_cursor() {
	boba::Cursor c = boba::new_cursor(120);
	c.set_pos(42);
	glaze::Style s = glaze::style().foreground(glaze::color_hex("#cccccc"));
	return s.render(string::tformat(
		"Cursor (pos=%d, end=%d)\n\n  A cursor points into a text buffer; it tracks\n  a byte offset (pos) and the total length (end).\n  Use boba::Cursor methods to move left/right,\n  start/end, or up/down by line width.", c.pos, c.end));
}

fn String preview_filepicker() {
	boba::FilePicker fp = boba::new_file_picker("examples");
	fp.load_dir("examples");
	fp.width  = 40;
	fp.height = 10;
	return string::tformat("FilePicker (cwd=examples/):\n\n%s", fp.view());
}

fn String preview_help() {
	boba::Help h = boba::new_help();
	h.add_entry("↑/↓", "navigate");
	h.add_entry("enter", "select");
	h.add_entry("esc", "quit");
	return string::tformat("Help (inline):\n\n%s", h.view());
}

fn String preview_keymap() {
	boba::KeyMap km = boba::new_keymap();
	km.bind("q", "quit");
	km.bind("j", "down");
	km.bind("k", "up");
	km.bind("/", "search");
	km.bind("enter", "select");

	// KeyMap has no .view() — render the bindings as a small two-column list.
	DString out = dstring::temp();
	glaze::Style key_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).bold(true);
	glaze::Style act_style = glaze::style().foreground(glaze::color_hex("#cccccc"));
	out.append_string("KeyMap (5 bindings):\n\n");
	for (int i = 0; i < km.count; i++) {
		out.append_string(string::tformat("  %-7s  ",
			key_style.render(km.bindings[i].key)));
		out.append_string(act_style.render(km.bindings[i].action));
		out.append_char('\n');
	}
	return out.str_view();
}

fn String preview_list() {
	boba::List l = boba::new_list();
	l.set_size(30, 8);
	l.add_item("Buy milk",     "from the store");
	l.add_item("Write code",    "in C3");
	l.add_item("Walk dog",      "around the block");
	l.add_item("Read book",     "before bed");
	l.add_item("Cook dinner",   "with garlic");
	return string::tformat("List (scrollable, with selection):\n\n%s", l.view());
}

fn String preview_pagination() {
	boba::Pagination pg = boba::new_pagination(5, 23);
	return string::tformat("Pagination (DOTS, 5 pages of 23):\n\n%s", pg.view());
}

fn String preview_progress() {
	boba::Progress p = boba::new_progress(30, 64);
	return string::tformat("Progress bar (64%%):\n\n%s", p.view());
}

fn String preview_stopwatch() {
	boba::Stopwatch s = boba::new_stopwatch();
	s.elapsed_seconds = 137;
	return string::tformat("Stopwatch (count-up):\n\n%s", s.view());
}

fn String preview_table() {
	boba::Table t = boba::new_table();
	t.width = 38;
	t.height = 7;
	t.add_column("Name", 14);
	t.add_column("Qty", 8);
	t.add_column("Price", 10);
	t.add_row3("Apple",  "12", "$1.20");
	t.add_row3("Bread",  "3",  "$2.50");
	t.add_row3("Coffee", "1",  "$4.00");
	return string::tformat("Table with 3 columns:\n\n%s", t.view());
}

fn String preview_textarea() {
	boba::Textarea ta = boba::new_textarea(40, 6)
		.with_placeholder("Start typing...");
	return string::tformat("Textarea (40x6, placeholder):\n\n%s", ta.view());
}

fn String preview_textinput() {
	boba::TextInput t = boba::new_text_input()
		.with_placeholder("type something...");
	String empty_view = t.view();
	t.insert_string("hello world");
	return string::tformat(
		"TextInput (placeholder, focused):\n\n%s\n\nTextInput (with text):\n\n%s",
		empty_view, t.view());
}

fn String preview_timer() {
	boba::Timer t = boba::new_timer(45);
	return string::tformat("Timer (countdown, ticking live):\n\n%s", t.view());
}

fn String preview_viewport() {
	// Viewport is a stateful container — show it with a fixed document
	// and its scrollbar drawn alongside so the user sees the component.
	boba::Viewport vp = boba::new_viewport(20, 8);
	vp.set_content(40);
	glaze::Style bar = glaze::style().foreground(glaze::color_hex("#555555"));
	String scrollbar = bar.render(vp.scrollbar());

	return string::tformat(
		"Viewport (40 lines, 8 visible):\n\n  line  1: Lorem ipsum\n  line  2: dolor sit amet\n  line  3: consectetur\n  line  4: adipiscing elit\n  line  5: sed do eiusmod\n  line  6: tempor incididunt\n  line  7: ut labore et\n  line  8: dolore magna\n\n  scroll:\n%s",
		scrollbar);
}

// preview_for returns the static preview for the component at `idx`.
// Animated components (7=Spinner, 8=Stopwatch, 12=Timer) are previewed
// live from the model so the user can see motion.
fn String preview_for(int idx) {
	switch (idx) {
		case 0:  return preview_cursor();
		case 1:  return preview_filepicker();
		case 2:  return preview_help();
		case 3:  return preview_keymap();
		case 4:  return preview_list();
		case 5:  return preview_pagination();
		case 6:  return preview_progress();
		case 9:  return preview_table();
		case 10: return preview_textarea();
		case 11: return preview_textinput();
		case 13: return preview_viewport();
		default: return "";
	}
}

// ─── Model ────────────────────────────────────────────────────────────────────

const int LEFT_PANE_W = 22;

struct Model {
	boba::List lst;
	// Animated previews (non-interactive)
	boba::Spinner preview_spinner;
	boba::Timer preview_timer;
	boba::Stopwatch preview_stopwatch;
	// Interactive previews (receive keyboard focus)
	boba::FilePicker preview_fp;
	boba::Viewport preview_vp;
	boba::Table preview_table;
	boba::Pagination preview_pg;
	boba::Textarea preview_ta;
	boba::TextInput preview_ti;
	boba::List preview_list;
	// Focus state
	bool preview_focused;
	int width;
	int height;
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	// Sidebar list
	self.lst = boba::new_list();
	self.lst.width = LEFT_PANE_W;
	for (int i = 0; i < COMPONENT_COUNT; i++) {
		self.lst.add_item(NAMES[i], DESCS[i]);
	}
	// Animated previews
	self.preview_spinner = boba::new_spinner(boba::SpinnerKind.DOTS)
		.with_color(glaze::color_hex("#00d7ff"));
	self.preview_timer = boba::new_timer(45);
	self.preview_stopwatch = boba::new_stopwatch();
	self.preview_stopwatch.elapsed_seconds = 137;
	// Interactive previews
	self.preview_fp = boba::new_file_picker("examples");
	self.preview_fp.load_dir("examples");
	self.preview_fp.width = 40;
	self.preview_fp.height = 10;
	self.preview_vp = boba::new_viewport(40, 10);
	self.preview_vp.set_content(30);
	self.preview_table = boba::new_table();
	self.preview_table.width = 38;
	self.preview_table.height = 7;
	self.preview_table.add_column("Name", 14);
	self.preview_table.add_column("Qty", 8);
	self.preview_table.add_column("Price", 10);
	self.preview_table.add_row3("Apple",  "12", "$1.20");
	self.preview_table.add_row3("Bread",  "3",  "$2.50");
	self.preview_table.add_row3("Coffee", "1",  "$4.00");
	self.preview_pg = boba::new_pagination(5, 23);
	self.preview_ta = boba::new_textarea(40, 6)
		.with_placeholder("Start typing...");
	self.preview_ti = boba::new_text_input()
		.with_placeholder("type something...");
	self.preview_list = boba::new_list();
	self.preview_list.selectable = true;
	self.preview_list.set_size(30, 8);
	self.preview_list.add_item("Buy milk",     "from the store");
	self.preview_list.add_item("Write code",    "in C3");
	self.preview_list.add_item("Walk dog",      "around the block");
	self.preview_list.add_item("Read book",     "before bed");
	self.preview_list.add_item("Cook dinner",   "with garlic");
	return self.preview_spinner.init_cmd();
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width  = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	// Drive animated previews from a single ~10fps tick.
	if (msg.kind == milktea::MsgKind.TICK) {
		self.preview_spinner.tick();
		self.preview_timer.tick();
		self.preview_stopwatch.elapsed_seconds++;
		return milktea::tick(100);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	// Preview focus mode: delegate keys to the active component.
	if (self.preview_focused) {
		if (k.code == milktea::KeyCode.ESC) {
			self.preview_focused = false;
			return null;
		}
		int idx = self.lst.cursor;
		switch (idx) {
			case 1:  if (self.preview_fp.handle_key(k)) return null;
			case 4:  if (self.preview_list.handle_key(k)) return null;
			case 5:  if (self.preview_pg.handle_key(k)) return null;
			case 9:  if (self.preview_table.handle_key(k)) return null;
			case 10: if (self.preview_ta.handle_key(k)) return null;
			case 11: if (self.preview_ti.handle_key(k)) return null;
			case 13: if (self.preview_vp.handle_key(k)) return null;
			default:
		}
		return null;
	}

	// Sidebar mode: navigate the component list.
	if (self.lst.handle_key(k)) return null;

	// Enter on an interactive component focuses its preview.
	if (k.code == milktea::KeyCode.ENTER && is_interactive(self.lst.cursor)) {
		self.preview_focused = true;
		return null;
	}

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	int w = self.width  > 0 ? self.width  : 80;
	int h = self.height > 0 ? self.height : 24;

	// ─── Layout ─────────────────────────────────────────────────────────
	// Top to bottom: header (1), body (fill), footer (1).
	xray::Rect header_r, body_r, footer_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::len(1),  &header_r),
		layout::slot(layout::fill(1), &body_r),
		layout::slot(layout::len(1),  &footer_r),
	});

	// Body: left sidebar (fixed) | preview (fill), 1-col gap.
	xray::Rect sidebar_r, preview_r;
	layout::hstack(body_r, {
		layout::slot(layout::len(LEFT_PANE_W), &sidebar_r),
		layout::slot(layout::fill(1),          &preview_r),
	}, { .gap = 1 });

	self.lst.height = body_r.h;

	// ─── Styles ─────────────────────────────────────────────────────────
	glaze::Style title_style = glaze::style()
		.foreground(glaze::color_hex("#874bfc"))
		.bold(true);
	glaze::Style selected_label_style = glaze::style()
		.foreground(glaze::color_hex("#ffffff"))
		.bold(true);
	glaze::Style left_header_style = glaze::style()
		.foreground(glaze::color_hex("#00d7ff"))
		.bold(true);
	glaze::Style body_style = glaze::style()
		.foreground(glaze::color_hex("#dddddd"));
	glaze::Style panel_style = glaze::style()
		.border(glaze::rounded_border())
		.border_fg(glaze::color_hex("#874bfc"))
		.padding(0, 1, 0, 1)
		.align(glaze::Position.LEFT, glaze::Position.TOP);
	glaze::Style footer_style = glaze::style()
		.foreground(glaze::color_hex("#666666"))
		.align(glaze::Position.CENTER, glaze::Position.CENTER);
	glaze::Style key_style = glaze::style()
		.foreground(glaze::color_hex("#874bfc"))
		.bold(true);
	glaze::Style focus_style = glaze::style()
		.foreground(glaze::color_hex("#50fa7b"))
		.bold(true);

	// ─── Sidebar: list of components ────────────────────────────────────
	String left_inner = glaze::join_vertical(glaze::Position.LEFT,
		left_header_style.render(" Components"),
		self.lst.view());
	String sidebar = panel_style.render_in(sidebar_r, left_inner);

	// ─── Preview: the selected component ─────────────────────────────────
	int idx = self.lst.cursor;
	bool live = self.preview_focused && is_interactive(idx);
	String preview_label = selected_label_style.render(string::tformat(
		"preview: %s — %s", NAMES[idx], DESCS[idx]));
	String focus_indicator = live ? focus_style.render("  ● FOCUSED — Esc to unfocus") : "";
	String preview_header = glaze::join_horizontal(
		preview_label, focus_indicator, 1);

	String preview_text;
	switch (idx) {
		case 1:  preview_text = self.preview_fp.view();
		case 4:  preview_text = self.preview_list.view();
		case 5:  preview_text = self.preview_pg.view();
		case 7:  preview_text = self.preview_spinner.view();
		case 8:  preview_text = self.preview_stopwatch.view();
		case 9:  preview_text = self.preview_table.view();
		case 10: preview_text = self.preview_ta.view();
		case 11: preview_text = self.preview_ti.view();
		case 12: preview_text = self.preview_timer.view();
		case 13: preview_text = preview_viewport();
		default: preview_text = preview_for(idx);
	}

	String preview_inner = glaze::join_vertical(glaze::Position.LEFT,
		preview_header,
		body_style.render(preview_text));
	String preview = panel_style.render_in(preview_r, preview_inner);

	// ─── Header & footer ────────────────────────────────────────────────
	String header = title_style.render_in(header_r, "  boba component viewer");
	String footer_inner;
	if (live) {
		footer_inner = string::tformat(
			"  %s unfocus   %s quit    previewing %s  ",
			key_style.render("Esc"),
			key_style.render("Ctrl+C"),
			NAMES[idx]);
	} else {
		footer_inner = string::tformat(
			"  %s navigate   %s%s focus   %s quit    %d / %d components  ",
			key_style.render("↑/↓"),
			key_style.render("Enter"),
			is_interactive(idx) ? "" : " (n/a)",
			key_style.render("q"),
			idx + 1, COMPONENT_COUNT);
	}
	String footer = footer_style.render_in(footer_r, footer_inner);

	// ─── Compose: header / (sidebar | preview) / footer ─────────────────
	String middle = glaze::join_horizontal(sidebar, preview, 0);
	String body = glaze::join_vertical(glaze::Position.LEFT, header, middle);
	String doc  = glaze::join_vertical(glaze::Position.LEFT, body, footer);

	return milktea::new_alt_screen_view(doc);
}

fn int main() {
	Model m = { };
	return milktea::@run(&m);
}
