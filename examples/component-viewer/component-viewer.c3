module component_viewer;

import milktea;
import glaze;
import boba;
import xray;
import xray::layout;
import std::core::string;

// Component viewer — full-screen TUI that lists every boba component on
// the left and renders a live preview of the selected one on the right.
//
// Previews use a mount/unmount lifecycle: mount creates the component
// fresh and starts its animation; unmount tears it down on switch.
// TICK scheduling is centralized so exactly one timer is ever pending.

// ─── Component catalogue ──────────────────────────────────────────────────────

const int COMPONENT_COUNT = 14;

enum Component : char {
	FILE_PICKER,
	HELP,
	KEYMAP,
	LIST,
	PAGINATION,
	PROGRESS,
	SPINNER,
	STOPWATCH,
	TABLE,
	TEXTAREA,
	TEXT_INPUT,
	TIMER,
	TOAST,
	VIEWPORT,
}

fn String component_name(Component c) {
	switch (c) {
		case FILE_PICKER: return "FilePicker";
		case HELP:        return "Help";
		case KEYMAP:      return "KeyMap";
		case LIST:        return "List";
		case PAGINATION:  return "Pagination";
		case PROGRESS:    return "Progress";
		case SPINNER:     return "Spinner";
		case STOPWATCH:   return "Stopwatch";
		case TABLE:       return "Table";
		case TEXTAREA:    return "Textarea";
		case TEXT_INPUT:  return "TextInput";
		case TIMER:       return "Timer";
		case TOAST:       return "Toast";
		case VIEWPORT:    return "Viewport";
	}
}

fn String component_desc(Component c) {
	switch (c) {
		case FILE_PICKER: return "file browser";
		case HELP:        return "key/desc pairs";
		case KEYMAP:      return "key bindings";
		case LIST:        return "scrollable list";
		case PAGINATION:  return "page navigation";
		case PROGRESS:    return "fill bar";
		case SPINNER:     return "animated indicator";
		case STOPWATCH:   return "count-up";
		case TABLE:       return "rows + columns";
		case TEXTAREA:    return "multi-line input";
		case TEXT_INPUT:  return "single-line input";
		case TIMER:       return "countdown";
		case TOAST:       return "overlay notification";
		case VIEWPORT:    return "scrollable region";
	}
}

fn bool component_interactive(Component c) {
	switch (c) {
		case FILE_PICKER: return true;
		case LIST:        return true;
		case PAGINATION:  return true;
		case TABLE:       return true;
		case TEXTAREA:    return true;
		case TEXT_INPUT:  return true;
		case VIEWPORT:    return true;
		default:          return false;
	}
}

// ─── Preview — mount/unmount lifecycle ────────────────────────────────────────

const int FLOAT_TICK_MS = 50;
const int FLOAT_CYCLE = 60; // steps per full cycle (~3 seconds)

struct Preview {
	Component kind;
	boba::FilePicker fp;
	boba::Help help;
	boba::KeyMap keymap;
	boba::List list;
	boba::Pagination pg;
	boba::Progress progress;
	boba::Spinner spinner;
	boba::Stopwatch stopwatch;
	boba::Table table;
	boba::Textarea ta;
	boba::TextInput ti;
	boba::Timer timer;
	boba::Toast toast_hard;
	boba::Toast toast_blur;
	int float_step;
	boba::Viewport vp;
}

fn void Preview.mount(&self, Component c) {
	milktea::cancel(&self.spinner);
	milktea::cancel(&self.stopwatch);
	milktea::cancel(&self.timer);
	milktea::cancel(&self.toast_hard);
	milktea::cancel(&self.toast_blur);
	milktea::cancel(&self.float_step);
	self.kind = c;
	switch (c) {
		case FILE_PICKER:
			self.fp = boba::new_file_picker("examples");
			self.fp.load_dir("examples");
			self.fp.width = 40;
			self.fp.height = 10;
		case HELP:
			self.help = boba::new_help();
			self.help.add_entry("↑/↓", "navigate");
			self.help.add_entry("enter", "select");
			self.help.add_entry("esc", "quit");
		case KEYMAP:
			self.keymap = boba::new_keymap();
			self.keymap.bind("q", "quit");
			self.keymap.bind("j", "down");
			self.keymap.bind("k", "up");
			self.keymap.bind("/", "search");
			self.keymap.bind("enter", "select");
		case LIST:
			self.list = boba::new_list();
			self.list.selectable = true;
			self.list.set_size(30, 8);
			self.list.add_item("Buy milk",     "from the store");
			self.list.add_item("Write code",    "in C3");
			self.list.add_item("Walk dog",      "around the block");
			self.list.add_item("Read book",     "before bed");
			self.list.add_item("Cook dinner",   "with garlic");
		case PAGINATION:
			self.pg = boba::new_pagination(5, 23);
		case PROGRESS:
			self.progress = boba::new_progress(30, 64);
		case SPINNER:
			self.spinner = boba::new_spinner(boba::SpinnerKind.DOTS)
				.with_color(glaze::color_hex("#00d7ff"));
			self.spinner.init_cmd();
		case STOPWATCH:
			self.stopwatch = boba::new_stopwatch();
			self.stopwatch.init_cmd();
		case TABLE:
			self.table = boba::new_table();
			self.table.width = 38;
			self.table.height = 7;
			self.table.add_column("Name", 14);
			self.table.add_column("Qty", 8);
			self.table.add_column("Price", 10);
			self.table.add_row3("Apple",  "12", "$1.20");
			self.table.add_row3("Bread",  "3",  "$2.50");
			self.table.add_row3("Coffee", "1",  "$4.00");
		case TEXTAREA:
			self.ta = boba::new_textarea(40, 20)
				.with_placeholder("Start typing...");
		case TEXT_INPUT:
			self.ti = boba::new_text_input()
				.with_placeholder("type something...");
		case TIMER:
			self.timer = boba::new_timer(45);
			self.timer.init_cmd();
		case TOAST:
			self.toast_hard = boba::new_toast();
			self.toast_hard.message = "Hard shadow";
			self.toast_hard.state = boba::ToastState.VISIBLE;
			self.toast_hard.anim_step = boba::TOAST_ANIM_STEPS;
			self.toast_blur = boba::new_toast();
			self.toast_blur.message = "Blurred shadow";
			self.toast_blur.state = boba::ToastState.VISIBLE;
			self.toast_blur.anim_step = boba::TOAST_ANIM_STEPS;
			self.float_step = 0;
			milktea::every(FLOAT_TICK_MS, owner: &self.float_step);
		case VIEWPORT:
			self.vp = boba::new_viewport(40, 10);
			self.vp.show_scrollbar = true;
			self.vp.thumb_style = glaze::style().foreground(glaze::color_hex("#874bfc"));
			String[30] vp_lines = {
				"The quick brown fox jumps over the lazy dog.",
				"Pack my box with five dozen liquor jugs.",
				"How vexingly quick daft zebras jump!",
				"The five boxing wizards jump quickly.",
				"",
				"Sphinx of black quartz, judge my vow.",
				"Two driven jocks help fax my big quiz.",
				"The jay, pig, fox, zebra and wolves quack!",
				"Sympathizing would fix Quaker objectives.",
				"",
				"A wizard's job is to vex chumps quickly.",
				"Watch Jeopardy, Alex Trebek's fun TV quiz.",
				"My quick study of lexicography won a prize.",
				"Waxy and quivering, jocks fumble the pizza.",
				"",
				"Amazingly few discotheques provide jukeboxes.",
				"My girl wove six dozen plaid jackets.",
				"Sixty zippers were picked from the jute bag.",
				"A quick movement will jeopardize six gunboats.",
				"",
				"All questions asked by experts amaze the judge.",
				"Jack quietly moved up and seized the wax.",
				"Few quips galvanized the mock jury box.",
				"The quick brown fox jumps over the lazy dog.",
				"",
				"Scroll with arrow keys or PgUp/PgDn.",
				"",
				"",
				"",
				"End.",
			};
			for (int i = 0; i < 30; i++) self.vp.add_line(vp_lines[i]);
	}
}

fn void Preview.update(&self, milktea::Msg msg) {
	switch (self.kind) {
		case SPINNER:   self.spinner.update(msg);
		case STOPWATCH: self.stopwatch.update(msg);
		case TIMER:     self.timer.update(msg);
		case TEXTAREA:  self.ta.update(msg);
		default:
	}
}

fn void Preview.set_focused(&self, bool focused) {
	switch (self.kind) {
		case TEXTAREA:
			self.ta.focused = focused;
			if (focused) { self.ta.start_blink(); } else { self.ta.stop_blink(); }
		case TEXT_INPUT:  self.ti.focused = focused;
		default:
	}
}

fn bool Preview.handle_key(&self, milktea::KeyMsg k) {
	switch (self.kind) {
		case FILE_PICKER: return self.fp.handle_key(k);
		case LIST:        return self.list.handle_key(k);
		case PAGINATION:  return self.pg.handle_key(k);
		case TABLE:       return self.table.handle_key(k);
		case TEXTAREA:    return self.ta.handle_key(k);
		case TEXT_INPUT:  return self.ti.handle_key(k);
		case VIEWPORT:    return self.vp.handle_key(k);
		default:          return false;
	}
}

fn String Preview.render(&self) {
	switch (self.kind) {
		case FILE_PICKER: return self.fp.view();
		case HELP:        return self.help.view();
		case KEYMAP:      return self.keymap.view();
		case LIST:        return self.list.view();
		case PAGINATION:  return self.pg.view();
		case PROGRESS:    return self.progress.view();
		case SPINNER:     return self.spinner.view();
		case STOPWATCH:   return self.stopwatch.view();
		case TABLE:       return self.table.view();
		case TEXTAREA:    return self.ta.view();
		case TEXT_INPUT:  return self.ti.view();
		case TIMER:       return self.timer.view();
		case TOAST:       return "Two toasts with different shadow styles:";
		case VIEWPORT:    return self.vp.view();
		default: return "";
	}
}

// ─── Model ────────────────────────────────────────────────────────────────────

const int LEFT_PANE_W = 22;

struct Model {
	boba::List lst;
	Preview preview;
	bool preview_focused;
	int width;
	int height;
	int vp_screen_row;
	int vp_screen_col;
	boba::Toast toast;
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.lst = boba::new_list();
	self.lst.width = LEFT_PANE_W;
	for (int i = 0; i < COMPONENT_COUNT; i++) {
		Component c = (Component)i;
		self.lst.add_item(component_name(c), component_desc(c));
	}
	self.preview.mount(Component.FILE_PICKER);
	self.toast = boba::new_toast();
	return null;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width  = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.preview.update(msg);
		self.toast.update(msg);
		if (msg.owner == &self.preview.float_step) {
			self.preview.float_step = (self.preview.float_step + 1) % FLOAT_CYCLE;
			milktea::tick(FLOAT_TICK_MS, owner: &self.preview.float_step);
		}
		return null;
	}

	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (self.preview.kind == Component.VIEWPORT) {
			milktea::MouseMsg m = msg.mouse;
			m.row = m.row - 1 - self.vp_screen_row;
			m.col = m.col - 1 - self.vp_screen_col;
			if (m.row >= 0 && m.row < self.preview.vp.height &&
				m.col >= 0 && m.col < self.preview.vp.width) {
				bool was_dragging = self.preview.vp.sel_active;
				self.preview.vp.handle_mouse_msg(m);
				if (was_dragging && !self.preview.vp.sel_active && self.preview.vp.has_selection) {
					self.toast.show("Copied to clipboard");
				}
			}
		}
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	// Preview focus mode.
	if (self.preview_focused) {
		if (k.code == milktea::KeyCode.ESC) {
			self.preview_focused = false;
			self.preview.set_focused(false);
			return null;
		}
		if (self.preview.handle_key(k)) return null;
		return null;
	}

	// Sidebar mode.
	if (self.lst.handle_key(k)) {
		Component cur = (Component)self.lst.cursor;
		if (cur != self.preview.kind) {
			self.preview.mount(cur);
		}
		return null;
	}

	if (k.code == milktea::KeyCode.ENTER && component_interactive(self.preview.kind)) {
		self.preview_focused = true;
		self.preview.set_focused(true);
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

	xray::Rect header_r, body_r, footer_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::len(1),  &header_r),
		layout::slot(layout::fill(1), &body_r),
		layout::slot(layout::len(1),  &footer_r),
	});

	xray::Rect sidebar_r, preview_r;
	layout::hstack(body_r, {
		layout::slot(layout::len(LEFT_PANE_W), &sidebar_r),
		layout::slot(layout::fill(1),          &preview_r),
	}, { .gap = 0 });

	self.lst.height = sidebar_r.h - 4;
	self.lst.cursor_style = glaze::style()
		.foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#874bfc"))
		.bold(true);
	self.lst.item_style = glaze::style()
		.foreground(glaze::color_hex("#a0a0b0"));
	self.lst.dim_style = glaze::style()
		.foreground(glaze::color_hex("#555566"));

	glaze::Color accent     = glaze::color_hex("#874bfc");
	glaze::Color accent2    = glaze::color_hex("#e040fb");
	glaze::Color cyan       = glaze::color_hex("#00d7ff");
	glaze::Color sidebar_bg = glaze::color_hex("#1a1a2e");
	glaze::Color content_bg = glaze::color_hex("#12121a");
	glaze::Color header_bg  = glaze::color_hex("#874bfc");
	glaze::Color subtle     = glaze::color_hex("#555566");
	glaze::Color text_dim   = glaze::color_hex("#888899");
	glaze::Color text_light = glaze::color_hex("#e0e0e8");

	// ── Header ──
	String header_title = glaze::gradient_text(" boba ", glaze::color_hex("#ffffff"), cyan);
	String header_sub = glaze::style()
		.foreground(glaze::color_hex("#e0d0ff"))
		.render("component viewer");
	String header = glaze::style()
		.background(header_bg)
		.foreground(glaze::color_hex("#ffffff"))
		.bold(true)
		.width(w)
		.padding(0, 0, 0, 1)
		.render(string::tformat("%s %s", header_title, header_sub));

	// ── Sidebar ──
	String sidebar_title = glaze::style()
		.foreground(cyan)
		.background(sidebar_bg)
		.bold(true)
		.padding(1, 0, 1, 2)
		.render("Components");

	String sidebar_inner = glaze::join_vertical(glaze::Position.LEFT,
		sidebar_title,
		glaze::style().padding(0, 1, 0, 2).render(self.lst.view()));
	glaze::Style sidebar_s = glaze::style()
		.background(sidebar_bg)
		.align(glaze::Position.LEFT, glaze::Position.TOP);
	String sidebar = sidebar_r.render(sidebar_s, sidebar_inner);

	// ── Preview panel ──
	bool live = self.preview_focused && component_interactive(self.preview.kind);

	String comp_name = glaze::style()
		.foreground(accent2)
		.bold(true)
		.render(component_name(self.preview.kind));
	String comp_desc = glaze::style()
		.foreground(text_dim)
		.render(string::tformat(" — %s", component_desc(self.preview.kind)));
	String focus_indicator = live
		? glaze::style().foreground(glaze::color_hex("#50fa7b")).bold(true).render("  ● FOCUSED")
		: "";

	String preview_header = glaze::style()
		.foreground(text_light)
		.background(glaze::color_hex("#1e1e30"))
		.padding(1, 0, 1, 2)
		.width(preview_r.w)
		.render(string::tformat("%s%s%s", comp_name, comp_desc, focus_indicator));

	// Size textarea/textinput to fill available preview space
	int content_h = preview_r.h - 5; // header padding (3) + content top padding (1) + margin
	int content_w = preview_r.w - 6; // content side padding (2+2) + margin
	if (content_h < 4) content_h = 4;
	if (content_w < 20) content_w = 20;
	if (self.preview.kind == Component.TEXTAREA) {
		self.preview.ta.height = content_h;
		self.preview.ta.width = content_w;
	}
	if (self.preview.kind == Component.VIEWPORT) {
		self.preview.vp.height = content_h / 2;
		self.preview.vp.width = content_w;
		self.vp_screen_row = preview_r.y + 4;
		self.vp_screen_col = preview_r.x + 2;
	}

	String preview_content = glaze::style()
		.foreground(text_light)
		.padding(1, 2, 0, 2)
		.render(self.preview.render());

	String preview_inner = glaze::join_vertical(glaze::Position.LEFT,
		preview_header, preview_content);
	glaze::Style preview_s = glaze::style()
		.background(content_bg)
		.align(glaze::Position.LEFT, glaze::Position.TOP);
	String preview = preview_r.render(preview_s, preview_inner);

	// ── Footer ──
	glaze::Style key_style = glaze::style()
		.foreground(accent)
		.bold(true);
	glaze::Style footer_style = glaze::style()
		.foreground(subtle)
		.width(w)
		.align(glaze::Position.CENTER, glaze::Position.CENTER);

	String footer_inner;
	if (live) {
		footer_inner = string::tformat(
			"%s unfocus   %s quit",
			key_style.render("Esc"), key_style.render("Ctrl+C"));
	} else {
		int idx = self.preview.kind.ordinal;
		footer_inner = string::tformat(
			"%s navigate   %s%s focus   %s quit   %d/%d",
			key_style.render("↑/↓"), key_style.render("Enter"),
			component_interactive(self.preview.kind) ? "" : " (n/a)",
			key_style.render("q"), idx + 1, COMPONENT_COUNT);
	}
	String footer = footer_style.render(footer_inner);

	String middle = glaze::join_horizontal(sidebar, preview, 0);
	String body = glaze::join_vertical(glaze::Position.LEFT, header, middle);
	String doc  = glaze::join_vertical(glaze::Position.LEFT, body, footer);

	milktea::View view = milktea::new_alt_screen_view(doc)
		.set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);

	// Inner shadow on sidebar right edge
	if (view.overlay_count < milktea::MAX_OVERLAYS) {
		view.overlays[view.overlay_count] = {
			.x = sidebar_r.x,
			.y = sidebar_r.y,
			.w = sidebar_r.w,
			.h = sidebar_r.h,
			.transparent = true,
			.layer_style = {
				.inner_shadow = xray::inner_shadow(right: 3, opacity: 40),
			},
		};
		view.overlay_count++;
	}

	if (self.toast.visible()) {
		self.toast.screen_width = w;
		self.toast.screen_height = h;
		view = self.toast.add_overlays(view);
	}

	// Toast preview: two floating toasts with different shadow styles
	if (self.preview.kind == Component.TOAST) {
		// Triangle wave: 0 → amplitude → 0 → -amplitude → 0
		int quarter = FLOAT_CYCLE / 4;
		int step = self.preview.float_step;
		int float_offset;
		if (step < quarter) {
			float_offset = step * 3 / quarter;
		} else if (step < quarter * 2) {
			float_offset = 3 - (step - quarter) * 3 / quarter;
		} else if (step < quarter * 3) {
			float_offset = -(step - quarter * 2) * 3 / quarter;
		} else {
			float_offset = -3 + (step - quarter * 3) * 3 / quarter;
		}

		int center_x = preview_r.x + preview_r.w / 2;
		int center_y = preview_r.y + preview_r.h / 2;

		// Hard shadow toast (left)
		int hard_w = self.preview.toast_hard.toast_width();
		int hard_x = center_x - hard_w - 2;
		int hard_y = center_y - 2 + float_offset;
		String hard_rendered = self.preview.toast_hard.style.render(self.preview.toast_hard.message);
		view = view.add_overlay(hard_x, hard_y, hard_w, boba::TOAST_H, hard_rendered);
		// Add hard shadow manually
		xray::Shadow hard_shadow = xray::shadow(offset_x: 1, offset_y: 1, opacity: 128, blur: 0);
		view.overlays[view.overlay_count - 1].layer_style.shadow = hard_shadow;

		// Blurred shadow toast (right)
		int blur_w = self.preview.toast_blur.toast_width();
		int blur_x = center_x + 2;
		int blur_y = center_y - 2 - float_offset;
		String blur_rendered = self.preview.toast_blur.style.render(self.preview.toast_blur.message);
		view = view.add_overlay(blur_x, blur_y, blur_w, boba::TOAST_H, blur_rendered);
		xray::Shadow blur_shadow = xray::shadow(offset_x: 1, offset_y: 1, opacity: 128, blur: 2);
		view.overlays[view.overlay_count - 1].layer_style.shadow = blur_shadow;
	}

	return view;
}

fn int main() {
	Model m = { };
	return milktea::@run(&m);
}
