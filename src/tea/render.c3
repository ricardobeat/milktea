module tea;

import std::core::dstring;

const String SGR_HIDE_CURSOR = "\x1b[?25l";
const String SGR_SHOW_CURSOR = "\x1b[?25h";
const String SGR_ALT_ON = "\x1b[?1049h";
const String SGR_ALT_OFF = "\x1b[?1049l";
const String SGR_CLEAR_HOME = "\x1b[H\x1b[2J";
const String SGR_FOCUS_ON = "\x1b[?1004h";
const String SGR_FOCUS_OFF = "\x1b[?1004l";
const String SGR_MOUSE_SGR_ON = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
const String SGR_MOUSE_SGR_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";

fn void render_frame(String frame) {
    DString out = dstring::temp();
    out.append_string(SGR_HIDE_CURSOR);
    out.append_string(SGR_CLEAR_HOME);
    for (usz i = 0; i < frame.len; i++) {
        if (frame[i] == '\n' && (i == 0 || frame[i - 1] != '\r')) {
            out.append_char('\r');
        }
        out.append_char(frame[i]);
    }
    out.append_string(SGR_SHOW_CURSOR);
    write_stdout((char[])out.str_view());
}

fn void enter_alt_screen() { write_stdout((char[])SGR_ALT_ON); }
fn void exit_alt_screen()  { write_stdout((char[])SGR_ALT_OFF); }
fn void show_cursor()      { write_stdout((char[])SGR_SHOW_CURSOR); }
fn void hide_cursor()      { write_stdout((char[])SGR_HIDE_CURSOR); }
fn void enable_focus()     { write_stdout((char[])SGR_FOCUS_ON); }
fn void disable_focus()    { write_stdout((char[])SGR_FOCUS_OFF); }

fn void enable_mouse()   { write_stdout((char[])SGR_MOUSE_SGR_ON); }
fn void disable_mouse()  { write_stdout((char[])SGR_MOUSE_SGR_OFF); }

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