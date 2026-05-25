module milktea;

import std::core::dstring;

const String SGR_HIDE_CURSOR      = "\x1b[?25l";
const String SGR_SHOW_CURSOR      = "\x1b[?25h";
const String SGR_ALT_ON           = "\x1b[?1049h";
const String SGR_ALT_OFF          = "\x1b[?1049l";
const String SGR_CLEAR_HOME       = "\x1b[H\x1b[2J";
const String SGR_FOCUS_ON         = "\x1b[?1004h";
const String SGR_FOCUS_OFF        = "\x1b[?1004l";
const String SGR_MOUSE_SGR_ON     = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
const String SGR_MOUSE_SGR_OFF    = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";
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
fn void render_view_to(View v, DString* out) {
	// Hide cursor while rendering to avoid flicker
	out.append_string(SGR_HIDE_CURSOR);

	// Clear screen and move to home position
	out.append_string(SGR_CLEAR_HOME);

	// Write content, converting \n to \r\n for proper terminal line endings
	String frame = v.content;
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

fn void enter_alt_screen() {
	write_stdout((char[])SGR_ALT_ON);
}
fn void exit_alt_screen() {
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

fn void enable_mouse() {
	write_stdout((char[])SGR_MOUSE_SGR_ON);
}
fn void disable_mouse() {
	write_stdout((char[])SGR_MOUSE_SGR_OFF);
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