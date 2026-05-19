module tea;

enum KeyCode : int {
    NONE,
    RUNE,
    ENTER,
    BACKSPACE,
    ESC,
    TAB,
    UP,
    DOWN,
    LEFT,
    RIGHT,
    HOME,
    END,
    DELETE,
    PAGE_UP,
    PAGE_DOWN,
    INSERT,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    CTRL_C,
}

struct KeyMsg {
    KeyCode code;
    char rune;
    bool ctrl;
    bool alt;
    bool shift;
}

enum MouseAction : int {
    MOUSE_PRESS,
    MOUSE_RELEASE,
    MOUSE_MOTION,
}

enum MouseButton : int {
    MOUSE_LEFT,
    MOUSE_MIDDLE,
    MOUSE_RIGHT,
    MOUSE_NONE,
    MOUSE_WHEEL_UP,
    MOUSE_WHEEL_DOWN,
}

struct MouseMsg {
    MouseButton button;
    MouseAction action;
    int row;
    int col;
    bool shift;
    bool alt;
    bool ctrl;
}

struct ParseResult {
    MsgKind kind;
    KeyMsg key;
    MouseMsg mouse;
    sz consumed;
}

const int CSI_MAX_PARAMS = 8;

struct CSIParse {
    int[CSI_MAX_PARAMS] params;
    int param_count;
    char final_byte;
    char private_prefix; // '<', '?', '>', '=' or 0 if none
    sz consumed;
    bool valid;
}

fn CSIParse parse_csi(char[] buf) {
    CSIParse csi;
    csi.param_count = 0;
    csi.final_byte = 0;
    csi.private_prefix = 0;
    csi.consumed = 0;
    csi.valid = false;

    // buf starts after ESC [
    if (buf.len == 0) return csi;

    sz pos = 0;

    // Check for private mode prefix (< ? > =)
    if (buf[0] == '<' || buf[0] == '?' || buf[0] == '>' || buf[0] == '=') {
        csi.private_prefix = buf[0];
        pos = 1;
    }

    int current_param = -1; // -1 means no param yet (implicit default)

    while (pos < buf.len) {
        char ch = buf[pos];

        if (ch >= '0' && ch <= '9') {
            if (current_param < 0) current_param = 0;
            current_param = current_param * 10 + (ch - '0');
            pos++;
        } else if (ch == ';') {
            if (csi.param_count < CSI_MAX_PARAMS) {
                csi.params[csi.param_count] = current_param < 0 ? 0 : current_param;
                csi.param_count++;
            }
            current_param = -1;
            pos++;
        } else if (ch >= 0x40 && ch <= 0x7e) {
            // Final byte
            csi.final_byte = ch;
            if (current_param >= 0 || csi.param_count > 0) {
                if (csi.param_count < CSI_MAX_PARAMS) {
                    csi.params[csi.param_count] = current_param < 0 ? 0 : current_param;
                    csi.param_count++;
                }
            }
            csi.consumed = pos + 1; // includes everything after ESC [
            csi.valid = true;
            return csi;
        } else if (ch >= 0x20 && ch <= 0x2f) {
            // Intermediate bytes — skip
            pos++;
        } else {
            // Unexpected byte — skip it to make progress.
            // But don't consume ESC (0x1b): it starts the next escape sequence.
            if (ch == 0x1b) {
                csi.consumed = pos;
                return csi;
            }
            csi.consumed = pos + 1;
            return csi;
        }
    }
    // Incomplete sequence
    return csi;
}

fn int csi_param(CSIParse csi, int idx, int default_val) {
    if (idx < csi.param_count) return csi.params[idx];
    return default_val;
}

fn ParseResult make_key(KeyCode code, char rune, bool ctrl, bool alt, bool shift, sz consumed) {
    return { MsgKind.KEY, { code, rune, ctrl, alt, shift }, { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false }, consumed };
}

fn ParseResult make_mouse(MouseButton button, MouseAction action, int row, int col, bool shift, bool alt, bool ctrl, sz consumed) {
    return { MsgKind.MOUSE, { NONE, 0, false, false, false }, { button, action, row, col, shift, alt, ctrl }, consumed };
}

<*
  @ensure return.consumed <= buf.len
*>
fn ParseResult parse_key(char[] buf) {
    // Empty buffer
    if (buf.len == 0) {
        return make_key(NONE, 0, false, false, false, 0);
    }

    char b = buf[0];

    // 0x03: Ctrl+C
    if (b == 0x03) {
        return make_key(CTRL_C, 0, true, false, false, 1);
    }

    // 0x0d or 0x0a: ENTER
    if (b == 0x0d || b == 0x0a) {
        return make_key(ENTER, 0, false, false, false, 1);
    }

    // 0x09: TAB
    if (b == 0x09) {
        return make_key(TAB, 0, false, false, false, 1);
    }

    // 0x7f or 0x08: BACKSPACE
    if (b == 0x7f || b == 0x08) {
        return make_key(BACKSPACE, 0, false, false, false, 1);
    }

    // 0x1b: ESC or escape sequence
    if (b == 0x1b) {
        if (buf.len == 1) {
            return make_key(ESC, 0, false, false, false, 1);
        }

        char second = buf[1];

        // ESC [ : CSI sequence
        if (second == '[') {
            // X10 mouse: ESC [ M followed by 3 bytes (button+32, col+32, row+32)
            // Check for ESC [ M before CSI parsing
            if (buf.len >= 3 && buf[2] == 'M') {
                if (buf.len < 6) {
                    // Need more data for X10 mouse
                    return make_key(NONE, 0, false, false, false, 0);
                }
                // X10 mouse: ESC [ M b x y  (3 bytes after M)
                int cb = (int)(buf[3]) - 32;
                int cx = (int)(buf[4]) - 32;
                int cy = (int)(buf[5]) - 32;

                MouseButton button = MOUSE_NONE;
                // Wheel buttons (4-5) must be checked before the low-2-bits mask
                if (cb == 4) { button = MOUSE_WHEEL_UP; }
                else if (cb == 5) { button = MOUSE_WHEEL_DOWN; }
                else {
                    if ((cb & 3) == 0) { button = MOUSE_LEFT; }
                    else if ((cb & 3) == 1) { button = MOUSE_MIDDLE; }
                    else if ((cb & 3) == 2) { button = MOUSE_RIGHT; }
                    else { button = MOUSE_NONE; }
                }

                MouseAction action = MOUSE_PRESS;
                if ((cb & 64) != 0) action = MOUSE_MOTION;  // motion event
                // Wheel events are always press
                if (cb == 4 || cb == 5) action = MOUSE_PRESS;

                bool shift = (cb & 4) != 0;
                bool alt = (cb & 8) != 0;
                bool ctrl = (cb & 16) != 0;

                return make_mouse(button, action, cy, cx, shift, alt, ctrl, 6);
            }

            CSIParse csi = parse_csi(buf[2..]);
            if (!csi.valid) {
                if (csi.consumed == 0) {
                    // Incomplete sequence — need more data
                    return make_key(NONE, 0, false, false, false, 0);
                }
                // Invalid or truncated CSI — consume and discard
                return make_key(NONE, 0, false, false, false, 2 + csi.consumed);
            }

            sz total = 2 + csi.consumed; // ESC [ + CSI data
            char fb = csi.final_byte;

            // SGR mouse: ESC [ < button ; col ; row M (press) or m (release)
            if (csi.private_prefix == '<' && (fb == 'M' || fb == 'm')) {
                if (csi.param_count == 3) {
                    int btn_code = csi.params[0];
                    int col = csi.params[1];
                    int row = csi.params[2];

                    MouseButton button = MOUSE_NONE;
                    // Wheel buttons (64-67) must be checked before the low-2-bits mask
                    if (btn_code >= 64 && btn_code <= 67) {
                        switch (btn_code - 64) {
                            case 0: button = MOUSE_WHEEL_UP;
                            case 1: button = MOUSE_WHEEL_DOWN;
                            default: button = MOUSE_NONE;
                        }
                    } else {
                        if ((btn_code & 3) == 0) { button = MOUSE_LEFT; }
                        else if ((btn_code & 3) == 1) { button = MOUSE_MIDDLE; }
                        else if ((btn_code & 3) == 2) { button = MOUSE_RIGHT; }
                        else { button = MOUSE_NONE; }
                    }

                    // Button 3 with no motion/release = no button (drag or other)
                    if ((btn_code & 3) == 3 && (btn_code & 32) == 0 && fb == 'M') {
                        button = MOUSE_NONE;
                    }

                    MouseAction action = (fb == 'M') ? MOUSE_PRESS : MOUSE_RELEASE;
                    if ((btn_code & 32) != 0) action = MOUSE_MOTION;
                    // Wheel events are always press (no release in SGR for wheel)
                    if (btn_code >= 64 && btn_code <= 67) action = MOUSE_PRESS;

                    bool shift = (btn_code & 4) != 0;
                    bool alt = (btn_code & 8) != 0;
                    bool ctrl = (btn_code & 16) != 0;

                    return make_mouse(button, action, row, col, shift, alt, ctrl, total);
                }
            }

            // Arrow keys (with optional modifiers)
            if (fb == 'A' || fb == 'B' || fb == 'C' || fb == 'D') {
                KeyCode code;
                switch (fb) {
                    case 'A': code = UP;
                    case 'B': code = DOWN;
                    case 'C': code = RIGHT;
                    case 'D': code = LEFT;
                    default:  code = UP;
                }

                int mod = csi_param(csi, 1, 1);
                bool shift = (mod == 2) || (mod == 4) || (mod == 6) || (mod == 8);
                bool alt = (mod == 3) || (mod == 4) || (mod == 7) || (mod == 8);
                bool ctrl = (mod == 5) || (mod == 6) || (mod == 7) || (mod == 8);
                return make_key(code, 0, ctrl, alt, shift, total);
            }

            // Home / End
            if (fb == 'H') return make_key(HOME, 0, false, false, false, total);
            if (fb == 'F') return make_key(END, 0, false, false, false, total);

            // Focus in / Focus out (xterm focus reporting: ESC [ I / ESC [ O)
            if (fb == 'I' && csi.param_count == 0 && csi.private_prefix == 0) {
                ParseResult pr;
                pr.kind = FOCUS;
                pr.key = { NONE, 0, false, false, false };
                pr.mouse = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false };
                pr.consumed = total;
                return pr;
            }
            if (fb == 'O' && csi.param_count == 0 && csi.private_prefix == 0) {
                ParseResult pr;
                pr.kind = BLUR;
                pr.key = { NONE, 0, false, false, false };
                pr.mouse = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false };
                pr.consumed = total;
                return pr;
            }

            // Tilde sequences: PgUp, PgDn, Ins, Del, F-keys
            if (fb == '~') {
                int p1 = csi_param(csi, 0, 0);
                switch (p1) {
                    case 2:  return make_key(INSERT,   0, false, false, false, total);
                    case 3:  return make_key(DELETE,   0, false, false, false, total);
                    case 5:  return make_key(PAGE_UP,  0, false, false, false, total);
                    case 6:  return make_key(PAGE_DOWN, 0, false, false, false, total);
                    case 11: return make_key(F1,  0, false, false, false, total);
                    case 12: return make_key(F2,  0, false, false, false, total);
                    case 13: return make_key(F3,  0, false, false, false, total);
                    case 14: return make_key(F4,  0, false, false, false, total);
                    case 15: return make_key(F5,  0, false, false, false, total);
                    case 17: return make_key(F6,  0, false, false, false, total);
                    case 18: return make_key(F7,  0, false, false, false, total);
                    case 19: return make_key(F8,  0, false, false, false, total);
                    case 20: return make_key(F9,  0, false, false, false, total);
                    case 21: return make_key(F10, 0, false, false, false, total);
                    case 23: return make_key(F11, 0, false, false, false, total);
                    case 24: return make_key(F12, 0, false, false, false, total);
                    default: return make_key(NONE, 0, false, false, false, total);
                }
            }

            // Unknown CSI — consume ESC only, let next call re-parse
            return make_key(ESC, 0, false, false, false, 1);
        }

        // ESC O : SS3 sequence (F1-F4 alternate encoding)
        if (second == 'O') {
            if (buf.len < 3) {
                // Need more data
                return make_key(NONE, 0, false, false, false, 0);
            }
            char third = buf[2];
            switch (third) {
                case 'P': return make_key(F1, 0, false, false, false, 3);
                case 'Q': return make_key(F2, 0, false, false, false, 3);
                case 'R': return make_key(F3, 0, false, false, false, 3);
                case 'S': return make_key(F4, 0, false, false, false, 3);
                default:  return make_key(ESC, 0, false, false, false, 1);
            }
        }

        // ESC followed by printable ASCII: Alt+rune
        if (second >= 0x20 && second <= 0x7e) {
            return make_key(RUNE, second, false, true, false, 2);
        }

        // ESC followed by something else
        return make_key(ESC, 0, false, false, false, 1);
    }

    // Printable ASCII (0x20..0x7e)
    if (b >= 0x20 && b <= 0x7e) {
        return make_key(RUNE, b, false, false, false, 1);
    }

    // Control chars 0x01..0x1a (except those handled above)
    if (b >= 0x01 && b <= 0x1a) {
        char rune_char = (char)('a' + (b - 1));
        return make_key(RUNE, rune_char, true, false, false, 1);
    }

    // Anything else: consume to make progress
    return make_key(NONE, 0, false, false, false, 1);
}