// cursors — gallery of custom draw-cursor effects and native cursor shapes.
// 
// Section A: draw-cursor callbacks — paint arbitrary strings at cursor position.
// Section B: native terminal cursor shapes + OSC 12 color.
// 
// Tab / Shift+Tab cycles focus. q or Ctrl+C to quit.
module cursors;

import tea;
import lipgloss;
import xray;
import std::io;

// ── section A: draw-cursor callbacks ─────────────────────────────────────────

fn String cursor_fire(int x, int y, bool blink) {
	return blink ? "🔥" : "";
}

fn String cursor_skull(int x, int y, bool blink) {
	return blink ? "💀" : "";
}

fn String cursor_crosshair(int x, int y, bool blink) {
	return blink ? "\x1b[1;33m✛\x1b[0m" : "\x1b[2;33m✛\x1b[0m";
}

fn String cursor_snake(int x, int y, bool blink) {
	long now  = tea::time_ms();
	int phase = (int)((now / 150) % 4);
	switch (phase) {
		case 0: return "█";
		case 1: return "▓";
		case 2: return "▒";
		default: return "░";
	}
}

fn String cursor_rainbow(int x, int y, bool blink) {
	long now         = tea::time_ms();
	int phase        = (int)((now / 100) % 6);
	String[6] colors = { "\x1b[31m", "\x1b[33m", "\x1b[32m", "\x1b[36m", "\x1b[34m", "\x1b[35m", };
	return string::tformat("%s█\x1b[0m", colors[phase]);
}

fn String cursor_matrix(int x, int y, bool blink) {
	long now = tea::time_ms();
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

alias DrawCursorFn = fn String(int x, int y, bool blink);

struct Entry {
	String label;
	String border_color;
	// section A: non-null draw fn
	DrawCursorFn draw;
	int interval_ms;
	// section B: draw == null; use native shape + color
	tea::CursorShape shape;
	String native_color;
	bool blink_native;
	// input buffer
	char[256] buf;
	sz len;
	sz cursor_pos;
}

fn void Entry.insert(&self, char c) {
	if (self.len >= self.buf.len - 1) return;
	for (sz i = self.len; i > self.cursor_pos; i--) self.buf[i] = self.buf[i - 1];
	self.buf[self.cursor_pos] = c;
	self.len++;
	self.cursor_pos++;
}

fn void Entry.backspace(&self) {
	if (self.cursor_pos == 0) return;
	for (sz i = self.cursor_pos; i < self.len; i++) self.buf[i - 1] = self.buf[i];
	self.len--;
	self.cursor_pos--;
}

fn void Entry.move_left(&self) {
	if (self.cursor_pos > 0) self.cursor_pos--;
}
fn void Entry.move_right(&self) {
	if (self.cursor_pos < self.len) self.cursor_pos++;
}
fn String Entry.text(&self) {
	return (String)self.buf[:self.len];
}

// ── model ─────────────────────────────────────────────────────────────────────

const int N = 10;

struct Model {
	Entry[N] entries;
	int focused;
	int width;
	int height;
}

fn tea::Cmd Model.init(&self) @dynamic {
	// Section A: draw-cursor
	self.entries[0] = { .label = "fire", .border_color = "#ff4400", .interval_ms = 400, .draw = &cursor_fire };
	self.entries[1] = { .label = "skull", .border_color = "#888888", .interval_ms = 500, .draw = &cursor_skull };
	self.entries[2] = {
		.label = "crosshair",
		.border_color = "#ff8800",
		.interval_ms = 250,
		.draw = &cursor_crosshair
	};
	self.entries[3] = { .label = "snake", .border_color = "#00ffaa", .interval_ms = 150, .draw = &cursor_snake };
	self.entries[4] = { .label = "rainbow", .border_color = "#ff00ff", .interval_ms = 100, .draw = &cursor_rainbow };
	self.entries[5] = { .label = "matrix", .border_color = "#00ff44", .interval_ms = 80, .draw = &cursor_matrix };
	// Section B: native shapes + OSC 12 colors
	self.entries[6] = {
		.label = "block",
		.border_color = "#4488ff",
		.shape = tea::CursorShape.CURSOR_BLOCK,
		.native_color = "",
		.blink_native = true
	};
	self.entries[7] = {
		.label = "underline",
		.border_color = "#44ccff",
		.shape = tea::CursorShape.CURSOR_UNDERLINE,
		.native_color = "#00ccff",
		.blink_native = true
	};
	self.entries[8] = {
		.label = "bar",
		.border_color = "#ff44cc",
		.shape = tea::CursorShape.CURSOR_BAR,
		.native_color = "#ff44cc",
		.blink_native = true
	};
	self.entries[9] = {
		.label = "steady",
		.border_color = "#ffaa00",
		.shape = tea::CursorShape.CURSOR_BLOCK,
		.native_color = "#ffaa00",
		.blink_native = false
	};
	return tea::tick(16);
}

fn tea::Cmd Model.update(&self, tea::Msg msg) @dynamic {
	switch (msg.kind) {
		case tea::MsgKind.WINDOW_SIZE:
			self.width = msg.window_size.width;
			self.height = msg.window_size.height;
			return tea::tick(16);
		case tea::MsgKind.TICK:
			return tea::tick(16);
		case tea::MsgKind.KEY:
			tea::KeyMsg k = msg.key;
			switch (k.code) {
				case tea::KeyCode.CTRL_C:
				case tea::KeyCode.ESC:
					return tea::quit();
				case tea::KeyCode.RUNE:
					if (k.rune == 'q') return tea::quit();
					self.entries[self.focused].insert(k.rune);
				case tea::KeyCode.BACKSPACE:
					self.entries[self.focused].backspace();
				case tea::KeyCode.LEFT:
					self.entries[self.focused].move_left();
				case tea::KeyCode.RIGHT:
					self.entries[self.focused].move_right();
				case tea::KeyCode.TAB:
					self.focused = k.shift ? (self.focused + N - 1) % N : (self.focused + 1) % N;
				default:
			}
		default:
	}
	return null;
}

fn tea::View Model.view(&self) @dynamic {
	int w = self.width > 0 ? self.width : 80;
	int h = self.height > 0 ? self.height : 24;

	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);

	String title = "\x1b[1;37m  CURSOR GALLERY\x1b[0m  \x1b[2;37m tab/shift+tab · q quit\x1b[0m";
	screen.render_ansi_string(0, 0, title, xray::default_style());

	const String PROMPT  = "> ";
	const int PROMPT_LEN = 2;
	const int BOX_LEFT   = 2;
	int input_w          = w - BOX_LEFT - 4;
	if (input_w < 20) input_w = 20;

	int focused_cx = 0;
	int focused_cy = 0;

	int row = 2;
	for (int i = 0; i < N; i++) {
		Entry* e = &self.entries[i];
		if (row + 3 > h) break;

		bool is_focused = (i == self.focused);
		String bc       = is_focused ? e.border_color : "#333333";
		String fc       = is_focused ? "#ffffff" : "#555555";

		// Input box
		lipgloss::Style box = lipgloss::new_style().set_border(lipgloss::rounded_border())
			.set_border_fg(lipgloss::color_hex(bc))
			.foreground(lipgloss::color_hex(fc))
			.set_width(input_w);
		String rendered = box.render(string::tformat("%s%s", PROMPT, e.text()));
		screen.render_ansi_string((sz)BOX_LEFT, (sz)row, rendered, xray::default_style(), (sz)(row + 3));

		int cx = BOX_LEFT + 1 + PROMPT_LEN + (int)e.cursor_pos;
		int cy = row + 1;

		if (is_focused) {
			focused_cx = cx;
			focused_cy = cy;

			// Section A: paint draw-cursor — overlay_char writes exactly one
			// cell slot so wide chars (emoji, katakana) never displace neighbors.
			if (e.draw != null) {
				long now     = tea::time_ms();
				bool blink   = ((now / (long)e.interval_ms) % 2) == 0;
				String drawn = e.draw(cx, cy, blink);
				if (drawn.len > 0) {
					screen.overlay_char((sz)cx, (sz)cy, drawn, xray::default_style());
				}
			}
		}

		row += 3;
	}

	tea::View view = tea::new_alt_cell_view(screen.cells[0:(sz)w * (sz)h], (sz)w, (sz)h);
	screen.destroy();
	mem::free(screen);

	// Section B: native cursor for focused native entry
	Entry* fe = &self.entries[self.focused];
	if (fe.draw == null) {
		view = view.set_cursor_shape(focused_cx, focused_cy, fe.shape, fe.blink_native);
		if (fe.native_color.len > 0) {
			view = view.set_cursor_color(fe.native_color);
		}
	}

	return view;
}

fn void Model.on_destroy(&self) @dynamic {
}

fn int main() {
	Model m = { };
	if (catch err = tea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}