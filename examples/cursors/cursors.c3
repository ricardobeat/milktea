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
import xray::layout;
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

alias DrawCursorFn = fn String(int x, int y, bool blink, String under);

struct Entry {
	// label is the small-caps name shown before the input box, e.g. "ꜰɪʀᴇ".
	String label;
	String border_color;
	// the input component; border comes from its styles
	boba::TextInput input;
	// section A: non-null draw fn
	DrawCursorFn draw;
	int interval_ms;
	// section B: draw == null; use native shape + color
	milktea::CursorShape shape;
	String native_color;
	bool blink_native;
}

// style_input returns a bordered text-input style for the given border color.
fn glaze::Style style_input(String bc, bool focused) {
	glaze::Style s = glaze::style()
		.border(glaze::rounded_border())
		.border_fg(glaze::color_hex(bc))
		.align(glaze::Position.LEFT, glaze::Position.CENTER);
	return focused ? s.foreground(glaze::color_hex("#ffffff")) : s.foreground(glaze::color_hex("#555555"));
}

// ── model ─────────────────────────────────────────────────────────────────────

const int N = 10;

struct Model {
	Entry[N] entries;
	int focused;
	int width;
	int height;
	int prev_cx;
	int prev_cy;
	// Reused cell buffer, owned by the model. The View borrows its cell array
	// until the framework has copied it into the renderer, so the buffer must
	// outlive view() — building a fresh screen per frame and freeing it here
	// left every View referencing freed memory (use-after-free).
	xray::ScreenBuffer* screen;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	// Section A: draw-cursor
	self.entries[0] = { .label = "ꜰɪʀᴇ", .border_color = "#ff4400", .interval_ms = 400, .draw = &cursor_fire };
	self.entries[1] = { .label = "ꜱᴋᴜʟʟ", .border_color = "#888888", .interval_ms = 500, .draw = &cursor_skull };
	self.entries[2] = {
		.label = "ᴄʀᴏꜱꜱʜᴀɪʀ",
		.border_color = "#ff8800",
		.interval_ms = 250,
		.draw = &cursor_crosshair
	};
	self.entries[3] = { .label = "ꜱɴᴀᴋᴇ", .border_color = "#00ffaa", .interval_ms = 150, .draw = &cursor_snake };
	self.entries[4] = { .label = "ʀᴀɪɴʙᴏᴡ", .border_color = "#ff00ff", .interval_ms = 100, .draw = &cursor_rainbow };
	self.entries[5] = { .label = "ᴍᴀᴛʀɪx", .border_color = "#00ff44", .interval_ms = 80, .draw = &cursor_matrix };
	// Section B: native shapes + OSC 12 colors
	self.entries[6] = {
		.label = "ʙʟᴏᴄᴋ",
		.border_color = "#4488ff",
		.shape = milktea::CursorShape.CURSOR_BLOCK,
		.native_color = "",
		.blink_native = true
	};
	self.entries[7] = {
		.label = "ᴜɴᴅᴇʀʟɪɴᴇ",
		.border_color = "#44ccff",
		.shape = milktea::CursorShape.CURSOR_UNDERLINE,
		.native_color = "#00ccff",
		.blink_native = true
	};
	self.entries[8] = {
		.label = "ʙᴀʀ",
		.border_color = "#ff44cc",
		.shape = milktea::CursorShape.CURSOR_BAR,
		.native_color = "#ff44cc",
		.blink_native = true
	};
	self.entries[9] = {
		.label = "ꜱᴛᴇᴀᴅʏ",
		.border_color = "#ffaa00",
		.shape = milktea::CursorShape.CURSOR_BLOCK,
		.native_color = "#ffaa00",
		.blink_native = false
	};
	// Give every input the bordered styles up front.
	for (int i = 0; i < N; i++) {
		self.entries[i].input = boba::new_text_input()
			.with_styles(
				style_input(self.entries[i].border_color, true),
				style_input("#333333", false)
			);
	}
	return milktea::tick(16);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.WINDOW_SIZE:
			self.width = msg.window_size.width;
			self.height = msg.window_size.height;
			return milktea::tick(16);
		case milktea::MsgKind.TICK:
			return milktea::tick(16);
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
	int w = self.width > 0 ? self.width : 80;
	int h = self.height > 0 ? self.height : 24;

	xray::ScreenBuffer* screen = self.screen;
	if (screen == null) {
		screen = xray::new_screen_buffer((sz)w, (sz)h);
		self.screen = screen;
	} else if (screen.width != (sz)w || screen.height != (sz)h) {
		screen.resize((sz)w, (sz)h);
	}
	screen.clear();

	const String PROMPT  = "> ";
	const int PROMPT_LEN = 2;

	// Page: title bar over a two-column body (flex).
	xray::Rect title_r, body_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::len(1), &title_r),
		layout::slot(layout::fill(1), &body_r),
	});

	xray::Rect col_l, col_r;
	layout::hstack(body_r, {
		layout::slot(layout::fill(1), &col_l),
		layout::slot(layout::fill(1), &col_r),
	}, { .gap = 2 });

	String title = "\x1b[1;37m  CURSOR GALLERY\x1b[0m  \x1b[2;37m tab/shift+tab · q quit\x1b[0m";
	screen.render_ansi_string((sz)title_r.x, (sz)title_r.y, title, xray::default_style());

	// Each column stacks 5 entry rows; each row is exactly the box height.
	xray::Rect[5] l_rows, r_rows;
	layout::vstack(col_l, {
		layout::slot(layout::len(3), &l_rows[0]),
		layout::slot(layout::len(3), &l_rows[1]),
		layout::slot(layout::len(3), &l_rows[2]),
		layout::slot(layout::len(3), &l_rows[3]),
		layout::slot(layout::len(3), &l_rows[4]),
	}, { .gap = 1 });
	layout::vstack(col_r, {
		layout::slot(layout::len(3), &r_rows[0]),
		layout::slot(layout::len(3), &r_rows[1]),
		layout::slot(layout::len(3), &r_rows[2]),
		layout::slot(layout::len(3), &r_rows[3]),
		layout::slot(layout::len(3), &r_rows[4]),
	}, { .gap = 1 });

	int focused_cx = 0;
	int focused_cy = 0;

	for (int i = 0; i < N; i++) {
		Entry* e = &self.entries[i];
		bool is_focused = (i == self.focused);
		String bc       = is_focused ? e.border_color : "#333333";

		// Entry row: small-caps name before the input box.
		xray::Rect row = (i < 5) ? l_rows[i] : r_rows[i - 5];
		xray::Rect name_r, input_r;
		layout::hstack(row, {
			layout::slot(layout::len(10), &name_r),
			layout::slot(layout::fill(1), &input_r),
		}, { .gap = 1 });

		// Name — right-aligned against the box, centred on its content line.
		String fc = is_focused ? "#ffffff" : "#555555";
		glaze::Style name_s = glaze::style()
			.foreground(glaze::color_hex(fc))
			.align(glaze::Position.RIGHT, glaze::Position.CENTER);
		String name_out = name_r.render(name_s, e.label);
		screen.render_ansi_string((sz)name_r.x, (sz)name_r.y, name_out, xray::default_style());

		// Input box — the component's text inside a bordered style sized to
		// the rect, so the box is one row of content and never stretched.
		glaze::Style box = style_input(bc, is_focused);
		String rendered = input_r.render(box, e.input.text());
		screen.render_ansi_string((sz)input_r.x, (sz)input_r.y, rendered, xray::default_style());

		// Cursor sits on the box's content line: left border, then the text
		// cursor column reported by the component.
		int cx = (int)input_r.x + 1 + e.input.cursor_col();
		int cy = (int)input_r.y + 1 + ((int)input_r.h - 3) / 2;

		if (is_focused) {
			focused_cx = cx;
			focused_cy = cy;

			// Section A: paint draw-cursor — overlay_char writes exactly one
			// cell slot so wide chars (emoji, katakana) never displace neighbors.
			if (e.draw != null) {
				long now     = milktea::time_ms();
				bool blink   = ((now / (long)e.interval_ms) % 2) == 0;
				// After cursor moves, force one frame of showing the
				// underlying character so it's never permanently hidden.
				bool moved   = (cx != self.prev_cx || cy != self.prev_cy);
				if (moved) blink = false;
				xray::Cell* uc = screen.cell_at((sz)cx, (sz)cy);
				String under = (uc != null && uc.content_len > 0) ? uc.content_str() : "";
				String drawn = e.draw(cx, cy, blink, under);
				if (drawn.len > 0) {
					screen.overlay_char((sz)cx, (sz)cy, drawn, xray::default_style());
				} else if (under.len > 0) {
					screen.overlay_char((sz)cx, (sz)cy, under, xray::default_style());
				}
			}
		}
	}

	self.prev_cx = focused_cx;
	self.prev_cy = focused_cy;

	milktea::View view = milktea::new_alt_cell_view(screen.cells[0:(sz)w * (sz)h], (sz)w, (sz)h);
	// screen is owned by the model (self.screen); freed in on_destroy.

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
	if (self.screen != null) {
		self.screen.destroy();
		mem::free(self.screen);
		self.screen = null;
	}
}

fn int main() {
	Model m = { };
	return milktea::@run(&m);
}
