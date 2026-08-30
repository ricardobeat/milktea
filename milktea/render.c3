module milktea;

import std::core::dstring;
import xray;

const String SGR_HIDE_CURSOR      = "\x1b[?25l";
const String SGR_SHOW_CURSOR      = "\x1b[?25h";
const String SGR_ALT_ON           = "\x1b[?1049h";
const String SGR_ALT_OFF          = "\x1b[?1049l";
const String SGR_CLEAR_HOME       = "\x1b[H\x1b[2J";
const String SGR_FOCUS_ON         = "\x1b[?1004h";
const String SGR_FOCUS_OFF        = "\x1b[?1004l";
// Bracketed paste mode (XTerm mode 2004): wraps pasted text in ESC[200~ ... ESC[201~
// so pasted ESC sequences are never misinterpreted as key sequences.
const String SGR_PASTE_ON         = "\x1b[?2004h";
const String SGR_PASTE_OFF        = "\x1b[?2004l";
const String SGR_MOUSE_SGR_ON     = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
const String SGR_MOUSE_SGR_OFF    = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";
const String SGR_MOUSE_ALL_ON     = "\x1b[?1003h\x1b[?1006h";
const String SGR_MOUSE_ALL_OFF    = "\x1b[?1006l\x1b[?1003l";
// DEC mode 1016: SGR-Pixels mouse reporting. Same wire format as SGR (mode 1006)
// except x/y are reported in pixels relative to the terminal window instead of
// cell coordinates. Opt-in via View.set_mouse_pixels; only meaningful while a
// mouse mode (cell-motion or all-motion) is also active.
const String SGR_MOUSE_PIXELS_ON  = "\x1b[?1016h";
const String SGR_MOUSE_PIXELS_OFF = "\x1b[?1016l";
const String SGR_CURSOR_BLINK_OFF = "\x1b[?12l";
const String SGR_CURSOR_BLINK_ON  = "\x1b[?12h";

// OSC 22 — set/reset the mouse pointer shape (xterm, kitty, most modern terminals).
// name: any CSS cursor keyword, e.g. "crosshair", "text", "pointer", "default".
fn String mouse_cursor_seq(String name) {
	return string::tformat("\x1b]22;%s\x1b\\", name);
}
const String OSC_MOUSE_CURSOR_RESET = "\x1b]22;\x1b\\";

// OSC 12 — set the terminal cursor color.
// color: CSS/X11 color name or hex, e.g. "#ff6600" or "red".
fn String cursor_color_seq(String color) {
	return string::tformat("\x1b]12;%s\x1b\\", color);
}
// Reset cursor color to terminal default.
const String OSC_CURSOR_COLOR_RESET = "\x1b]112\x1b\\";

// cursor_style_seq returns the ANSI escape to set cursor shape.
// Matches Go's encodeCursorStyle: (shape * 2) + 1, +1 if not blinking.
fn String cursor_style_seq(CursorShape shape, bool blink) {
	int style = ((int)shape * 2) + 1;
	if (!blink) style++;
	return string::tformat("\x1b[%d q", style);
}

// render_view_to writes the full rendered output for a View into [out].
// Split from render_view so tests can inspect the buffer without touching stdout.
// cells_to_string flattens a cell view into an ANSI string, one line per row.
// The differential renderer normally consumes the grid directly; this is the
// path for test mode and for any caller holding only a string sink.
fn String cells_to_string(View v) {
	DString out = dstring::temp();
	xray::Style pen = xray::default_style();

	for (sz row = 0; row < v.cells_height; row++) {
		if (row > 0) out.append_char('\n');
		sz line_start = row * v.cells_width;
		for (sz col = 0; col < v.cells_width; col++) {
			xray::Cell cell = v.cells[line_start + col];
			String sgr = cell.style.diff_sgr(pen);
			if (sgr.len > 0) out.append_string(sgr);
			// TRANSPARENT leaves the channel as it was, so the pen keeps its
			// previous color rather than adopting a non-color.
			if (cell.style.fg.kind != xray::ColorKind.TRANSPARENT) pen.fg = cell.style.fg;
			if (cell.style.bg.kind != xray::ColorKind.TRANSPARENT) pen.bg = cell.style.bg;
			pen.attrs = cell.style.attrs;
			pen.underline_color = cell.style.underline_color;
			out.append_string(cell.content_str());
			// A wide glyph owns the next column too; its placeholder cell
			// must not be emitted as a second character.
			if (cell.width == 2) col++;
		}
	}
	if (!pen.is_empty()) out.append_string("\x1b[0m");
	return out.copy_str(tmem);
}

fn void render_view_to(View v, DString* out) {
	// Hide cursor while rendering to avoid flicker
	out.append_string(SGR_HIDE_CURSOR);

	// Clear screen and move to home position
	out.append_string(SGR_CLEAR_HOME);

	// A cell view carries a grid rather than a string, so flatten it here.
	// Test mode has no differential renderer to hand the cells to.
	String frame = v.cells.ptr != null ? cells_to_string(v) : v.content;

	// Write content, converting \n to \r\n for proper terminal line endings
	for (sz i = 0; i < frame.len; i++) {
		if (frame[i] == '\n' && (i == 0 || frame[i - 1] != '\r')) {
			out.append_char('\r');
		}
		out.append_char(frame[i]);
	}

	// Position cursor if the View requests it.
	// Cursor x,y are 0-indexed relative to the content's top-left corner.
	// After SGR_CLEAR_HOME, content starts at terminal position (1,1),
	// so we add 1 to convert to 1-indexed terminal coordinates.
	if (v.has_cursor) {
		int term_row = v.cursor.y + 1;
		int term_col = v.cursor.x + 1;
		out.append_string(cursor_to(term_row, term_col));

		// Set cursor color via OSC 12
		if (v.cursor.color.len > 0) {
			out.append_string(cursor_color_seq(v.cursor.color));
		} else {
			out.append_string(OSC_CURSOR_COLOR_RESET);
		}

		// Set cursor shape and blink
		out.append_string(cursor_style_seq(v.cursor.shape, v.cursor.blink));
		if (v.cursor.blink) {
			out.append_string(SGR_CURSOR_BLINK_ON);
		} else {
			out.append_string(SGR_CURSOR_BLINK_OFF);
		}
	}

	// Show cursor
	out.append_string(SGR_SHOW_CURSOR);
}

// render_view renders a View to stdout.
fn void render_view(View v) {
	DString out = dstring::temp();
	render_view_to(v, &out);
	write_stdout((char[])out.str_view());
}

// g_manual_alt_screen records that enter_alt_screen() was called outside of a
// running Program. Program.run() starts from the assumption that it owns the
// alt screen and that the terminal is not in it yet; a manual entry beforehand
// breaks that, leaving in_alt_screen false forever so the exit path never pops
// back to the normal buffer. run() checks this flag and refuses to start.
bool g_manual_alt_screen = false;

// enter_alt_screen switches the terminal to the alternate screen buffer.
//
// A Program with an alt-screen view enters and exits the alt screen on its own
// — do not call this before @run_program/run(); doing so is an error and run()
// will reject it. This is for direct rendering without a Program.
fn void enter_alt_screen() {
	g_manual_alt_screen = true;
	write_stdout((char[])SGR_ALT_ON);
}
fn void exit_alt_screen() {
	g_manual_alt_screen = false;
	write_stdout((char[])SGR_ALT_OFF);
}
fn void show_cursor() {
	write_stdout((char[])SGR_SHOW_CURSOR);
}
fn void hide_cursor() {
	write_stdout((char[])SGR_HIDE_CURSOR);
}
fn void enable_focus() {
	write_stdout((char[])SGR_FOCUS_ON);
}
fn void disable_focus() {
	write_stdout((char[])SGR_FOCUS_OFF);
}
fn void enable_bracketed_paste() {
	write_stdout((char[])SGR_PASTE_ON);
}
fn void disable_bracketed_paste() {
	write_stdout((char[])SGR_PASTE_OFF);
}

// Kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
// Flag 1 = "disambiguate escape codes": functional keys that would otherwise be
// ambiguous are sent as CSI u sequences. Plain printable keys without modifiers
// still arrive as regular bytes, so this is safe to push unconditionally — terminals
// that do not support the protocol silently ignore the push/pop sequences.
//
// CSI > 1 u  — push progressive enhancement, flag 1
// CSI < u    — pop (restore the previous flags layer)
const String SGR_KITTY_KBD_ON  = "\x1b[>1u";
const String SGR_KITTY_KBD_OFF = "\x1b[<u";

fn void enable_kitty_keyboard() {
	write_stdout((char[])SGR_KITTY_KBD_ON);
}
fn void disable_kitty_keyboard() {
	write_stdout((char[])SGR_KITTY_KBD_OFF);
}

// Opt-in key event reporting (press/repeat/release). Pushed as an additional
// enhancement layer on top of the base disambiguate layer (flag 1 + flag 2 =
// 3), so popping it restores exactly the base layer pushed by
// enable_kitty_keyboard(). Only used when a View sets report_key_events.
//
// CSI > 3 u  — push progressive enhancement, flags 1 (disambiguate) + 2 (report events)
// CSI < u    — pop (restore the previous flags layer, i.e. back to flag 1 alone)
const String SGR_KITTY_KEY_EVENTS_ON  = "\x1b[>3u";
const String SGR_KITTY_KEY_EVENTS_OFF = "\x1b[<u";

fn void enable_kitty_key_events() {
	write_stdout((char[])SGR_KITTY_KEY_EVENTS_ON);
}
fn void disable_kitty_key_events() {
	write_stdout((char[])SGR_KITTY_KEY_EVENTS_OFF);
}

fn void enable_mouse(bool all_motion = false) {
	write_stdout((char[])(all_motion ? SGR_MOUSE_ALL_ON : SGR_MOUSE_SGR_ON));
}
fn void disable_mouse(bool all_motion = false) {
	write_stdout((char[])(all_motion ? SGR_MOUSE_ALL_OFF : SGR_MOUSE_SGR_OFF));
}

fn void enable_mouse_pixels() {
	write_stdout((char[])SGR_MOUSE_PIXELS_ON);
}
fn void disable_mouse_pixels() {
	write_stdout((char[])SGR_MOUSE_PIXELS_OFF);
}

fn String cursor_to(int row, int col) {
	return string::tformat("\x1b[%d;%dH", row, col);
}

fn String cursor_up(int n) {
	if (n <= 0) return "";
	return string::tformat("\x1b[%dA", n);
}

fn String cursor_down(int n) {
	if (n <= 0) return "";
	return string::tformat("\x1b[%dB", n);
}

fn String cursor_right(int n) {
	if (n <= 0) return "";
	return string::tformat("\x1b[%dC", n);
}

fn String cursor_left(int n) {
	if (n <= 0) return "";
	return string::tformat("\x1b[%dD", n);
}