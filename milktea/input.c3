module milktea;

import xray;

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

// KeyAction distinguishes press/repeat/release events. Only kitty-keyboard-protocol
// terminals with the report_key_events opt-in enabled ever send REPEAT or RELEASE;
// otherwise every KeyMsg carries KEY_PRESS, matching legacy behavior.
enum KeyAction : int {
	KEY_PRESS,
	KEY_REPEAT,
	KEY_RELEASE,
}

struct KeyMsg {
	KeyCode code;
	uint rune; // Unicode codepoint, not a byte — ASCII literals still compare directly
	bool ctrl;
	bool alt;
	bool shift;
	KeyAction action;
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
	// px, py: raw 0-based pixel coordinates from DEC mode 1016 (SGR-Pixels).
	// Both are 0 unless the app opted in via View.set_mouse_pixels and the
	// terminal actually reported pixel coordinates for this event.
	int px;
	int py;
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
	int[CSI_MAX_PARAMS] subparams; // ':'-separated subparameter of each param; 0 = absent
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
	int current_subparam = -1; // -1 means no subparam seen for current_param
	bool in_subparam = false; // true once ':' has been seen for the current param
	bool subparam_seen_second_colon = false; // second ':' in a param — ignore extra levels

	while (pos < buf.len) {
		char ch = buf[pos];

		if (ch >= '0' && ch <= '9') {
			if (in_subparam) {
				if (!subparam_seen_second_colon) {
					if (current_subparam < 0) current_subparam = 0;
					current_subparam = current_subparam * 10 + (ch - '0');
				}
			} else {
				if (current_param < 0) current_param = 0;
				current_param = current_param * 10 + (ch - '0');
			}
			pos++;
		} else if (ch == ':') {
			if (!in_subparam) {
				in_subparam = true;
			} else {
				// Second (or later) ':' in this param — we only keep one
				// subparam level; ignore digits belonging to deeper levels.
				subparam_seen_second_colon = true;
			}
			pos++;
		} else if (ch == ';') {
			if (csi.param_count < CSI_MAX_PARAMS) {
				csi.params[csi.param_count] = current_param < 0 ? 0 : current_param;
				csi.subparams[csi.param_count] = current_subparam < 0 ? 0 : current_subparam;
				csi.param_count++;
			}
			current_param = -1;
			current_subparam = -1;
			in_subparam = false;
			subparam_seen_second_colon = false;
			pos++;
		} else if (ch >= 0x40 && ch <= 0x7e) {
			// Final byte
			csi.final_byte = ch;
			if (current_param >= 0 || csi.param_count > 0 || current_subparam >= 0) {
				if (csi.param_count < CSI_MAX_PARAMS) {
					csi.params[csi.param_count] = current_param < 0 ? 0 : current_param;
					csi.subparams[csi.param_count] = current_subparam < 0 ? 0 : current_subparam;
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

// csi_subparam returns the ':'-separated subparameter of params[idx] (e.g. the
// kitty keyboard protocol event type in "mods:event"), or default_val if the
// param is out of range or has no subparameter (0 means "absent").
fn int csi_subparam(CSIParse csi, int idx, int default_val) {
	if (idx < csi.param_count && csi.subparams[idx] != 0) return csi.subparams[idx];
	return default_val;
}

fn ParseResult make_key(KeyCode code, uint rune, bool ctrl, bool alt, bool shift, sz consumed) {
	return {
		MsgKind.KEY,
		{ code, rune, ctrl, alt, shift, KEY_PRESS },
		{ MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 },
		consumed
	};
}

// make_key_action is like make_key but sets a KeyAction other than the default
// press. Used exclusively by the kitty keyboard protocol 'u' path when the app
// has opted in to key-release/repeat reporting.
fn ParseResult make_key_action(KeyCode code, uint rune, bool ctrl, bool alt, bool shift, KeyAction action, sz consumed) {
	return {
		MsgKind.KEY,
		{ code, rune, ctrl, alt, shift, action },
		{ MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 },
		consumed
	};
}

fn ParseResult make_mouse(
	MouseButton button,
	MouseAction action,
	int row,
	int col,
	bool shift,
	bool alt,
	bool ctrl,
	sz consumed
) {
	return {
		MsgKind.MOUSE,
		{ NONE, 0, false, false, false, KEY_PRESS },
		{ button, action, row, col, shift, alt, ctrl, 0, 0 },
		consumed
	};
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
			// A lone ESC is ambiguous: it may be a bare keypress or the
			// first byte of a split escape sequence (common over SSH).
			// Ask for more data; the event loop flushes it as ESC after
			// a short hold if nothing else arrives.
			return make_key(NONE, 0, false, false, false, 0);
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

				MouseButton button;
				MouseAction action;

				// Bit 64: wheel event. Low 2 bits give direction (0=up, 1=down).
				// Bit 32: motion event (button-event tracking, mode 1002).
				// Low 2 bits == 3: release (X10 doesn't report which button).
				if ((cb & 64) != 0) {
					switch (cb & 3) {
						case 0: button = MOUSE_WHEEL_UP;
						case 1: button = MOUSE_WHEEL_DOWN;
						default: button = MOUSE_NONE;
					}
					action = MOUSE_PRESS;
				} else if ((cb & 3) == 3) {
					// Release or motion-with-no-button: distinguish by motion bit.
					button = MOUSE_NONE;
					action = ((cb & 32) != 0) ? MOUSE_MOTION : MOUSE_RELEASE;
				} else {
					switch (cb & 3) {
						case 0: button = MOUSE_LEFT;
						case 1: button = MOUSE_MIDDLE;
						case 2: button = MOUSE_RIGHT;
						default: button = MOUSE_NONE;
					}
					action = ((cb & 32) != 0) ? MOUSE_MOTION : MOUSE_PRESS;
				}

				bool shift = (cb & 4) != 0;
				bool alt   = (cb & 8) != 0;
				bool ctrl  = (cb & 16) != 0;

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
			char fb  = csi.final_byte;

			// SGR mouse: ESC [ < button ; col ; row M (press) or m (release)
			if (csi.private_prefix == '<' && (fb == 'M' || fb == 'm')) {
				if (csi.param_count == 3) {
					int btn_code = csi.params[0];
					int col      = csi.params[1];
					int row      = csi.params[2];

					MouseButton button = MOUSE_NONE;
					// Wheel buttons (64-67) must be checked before the low-2-bits mask



					if (btn_code >= 64 && btn_code <= 67) {
						switch (btn_code - 64) {
							case 0: button = MOUSE_WHEEL_UP;
							case 1: button = MOUSE_WHEEL_DOWN;
							default: button = MOUSE_NONE;
						}
					} else {
						if ((btn_code & 3) == 0) {
							button = MOUSE_LEFT;
						} else if ((btn_code & 3) == 1) {
							button = MOUSE_MIDDLE;
						} else if ((btn_code & 3) == 2) {
							button = MOUSE_RIGHT;
						} else {
							button = MOUSE_NONE;
						}
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
					bool alt   = (btn_code & 8) != 0;
					bool ctrl  = (btn_code & 16) != 0;

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
					default: code = UP;
				}

				int mod    = csi_param(csi, 1, 1);
				bool shift = (mod == 2) || (mod == 4) || (mod == 6) || (mod == 8);
				bool alt   = (mod == 3) || (mod == 4) || (mod == 7) || (mod == 8);
				bool ctrl  = (mod == 5) || (mod == 6) || (mod == 7) || (mod == 8);
				return make_key(code, 0, ctrl, alt, shift, total);
			}

			// Home / End — xterm sends ESC [ 1 ; <mod> H/F, same modifier layout as arrows
			if (fb == 'H' || fb == 'F') {
				KeyCode code   = (fb == 'H') ? HOME : END;
				int mod        = csi_param(csi, 1, 1);
				bool shift     = (mod == 2) || (mod == 4) || (mod == 6) || (mod == 8);
				bool alt       = (mod == 3) || (mod == 4) || (mod == 7) || (mod == 8);
				bool ctrl      = (mod == 5) || (mod == 6) || (mod == 7) || (mod == 8);
				return make_key(code, 0, ctrl, alt, shift, total);
			}

			// Focus in / Focus out (xterm focus reporting: ESC [ I / ESC [ O)
			if (fb == 'I' && csi.param_count == 0 && csi.private_prefix == 0) {
				ParseResult pr;
				pr.kind = FOCUS;
				pr.key = { NONE, 0, false, false, false, KEY_PRESS };
				pr.mouse = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 };
				pr.consumed = total;
				return pr;
			}
			if (fb == 'O' && csi.param_count == 0 && csi.private_prefix == 0) {
				ParseResult pr;
				pr.kind = BLUR;
				pr.key = { NONE, 0, false, false, false, KEY_PRESS };
				pr.mouse = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 };
				pr.consumed = total;
				return pr;
			}

			// Tilde sequences: PgUp, PgDn, Ins, Del, F-keys, and bracketed paste markers.
			if (fb == '~') {
				int p1 = csi_param(csi, 0, 0);
				switch (p1) {
					case 2: return make_key(INSERT, 0, false, false, false, total);
					case 3: return make_key(DELETE, 0, false, false, false, total);
					case 5: return make_key(PAGE_UP, 0, false, false, false, total);
					case 6: return make_key(PAGE_DOWN, 0, false, false, false, total);
					case 11: return make_key(F1, 0, false, false, false, total);
					case 12: return make_key(F2, 0, false, false, false, total);
					case 13: return make_key(F3, 0, false, false, false, total);
					case 14: return make_key(F4, 0, false, false, false, total);
					case 15: return make_key(F5, 0, false, false, false, total);
					case 17: return make_key(F6, 0, false, false, false, total);
					case 18: return make_key(F7, 0, false, false, false, total);
					case 19: return make_key(F8, 0, false, false, false, total);
					case 20: return make_key(F9, 0, false, false, false, total);
					case 21: return make_key(F10, 0, false, false, false, total);
					case 23: return make_key(F11, 0, false, false, false, total);
					case 24: return make_key(F12, 0, false, false, false, total);
					// Bracketed paste markers — returned as internal sentinels consumed
					// by Program.run(); never forwarded to model.update().
					case 200: {
						ParseResult pr;
						pr.kind     = MsgKind.PASTE_START;
						pr.key      = { NONE, 0, false, false, false, KEY_PRESS };
						pr.mouse    = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 };
						pr.consumed = total;
						return pr;
					}
					case 201: {
						ParseResult pr;
						pr.kind     = MsgKind.PASTE_END;
						pr.key      = { NONE, 0, false, false, false, KEY_PRESS };
						pr.mouse    = { MOUSE_NONE, MOUSE_PRESS, 0, 0, false, false, false, 0, 0 };
						pr.consumed = total;
						return pr;
					}
					default: return make_key(NONE, 0, false, false, false, total);
				}
			}

			// Shift+Tab: ESC [ Z
			if (fb == 'Z') return make_key(TAB, 0, false, false, true, total);

			// Kitty keyboard protocol: CSI <codepoint> [;<mods>] u
			//
			// Final byte 'u', no private prefix. Param 0 = Unicode codepoint;
			// param 1 (optional, default 1) = 1 + modifier bitfield:
			//   bit 0 (+1) = shift, bit 1 (+2) = alt, bit 2 (+4) = ctrl.
			// A bare CSI u with no params is unusual but not something we emit,
			// so treat param_count==0 conservatively as an unknown sequence.
			//
			// Private prefix '?' with final 'u' is a query-response form that
			// some terminals send back when probed; consume and ignore it.
			if (fb == 'u' && csi.private_prefix == '?') {
				// Terminal query response — consume, produce no key event.
				return make_key(NONE, 0, false, false, false, total);
			}
			if (fb == 'u' && csi.private_prefix == 0 && csi.param_count >= 1) {
				uint cp  = (uint)csi.params[0];
				int mods = csi_param(csi, 1, 1); // default modifier value = 1 (no mods)
				// Modifier value is 1 + bitfield: subtract 1 to get the bits.
				int mod_bits = mods > 0 ? mods - 1 : 0;
				bool shift   = (mod_bits & 1) != 0;
				bool alt     = (mod_bits & 2) != 0;
				bool ctrl    = (mod_bits & 4) != 0;

				// Event type is the subparameter on the modifier param
				// (CSI cp;mods:event u). 1=press, 2=repeat, 3=release; absent
				// defaults to press. This subparam is only ever present when
				// the app opted in via report_key_events (flag 2), so apps
				// that didn't opt in always see KEY_PRESS here.
				int event = csi_subparam(csi, 1, 1);
				KeyAction action;
				switch (event) {
					case 2: action = KEY_REPEAT;
					case 3: action = KEY_RELEASE;
					default: action = KEY_PRESS;
				}

				// Functional-key codepoints: map to their KeyCode.
				// ESC (27) is the main win — it arrives unambiguous under kitty protocol,
				// so we skip the 50ms ESC-hold entirely.
				if (cp == 27)  return make_key_action(ESC,       0,  false, false, false, action, total);
				if (cp == 13)  return make_key_action(ENTER,     0,  false, false, false, action, total);
				if (cp == 9)   return make_key_action(TAB,       0,  ctrl,  alt,   shift, action, total);
				if (cp == 127) return make_key_action(BACKSPACE, 0,  false, false, false, action, total);

				// Ctrl+C equivalence: under the disambiguate flag, kitty-protocol
				// terminals send ctrl+c as CSI 99;5u (codepoint 'c' + ctrl bit),
				// NOT as legacy 0x03. Map it to KeyCode.CTRL_C so apps that quit
				// on CTRL_C behave identically on both paths. Kept narrow: extra
				// modifiers (ctrl+shift+c etc.) stay RUNE so copy-shortcuts remain
				// distinguishable. cp==3 is also mapped defensively.
				if (cp == 3)   return make_key_action(CTRL_C, 0, true, false, false, action, total);
				if (cp == 'c' && ctrl && !alt && !shift) {
					return make_key_action(CTRL_C, 0, true, false, false, action, total);
				}

				// Ctrl+letter: kitty sends the lowercase letter codepoint with ctrl bit set.
				// Match the legacy control-char path (0x01..0x1a) which also produces
				// RUNE <lowercase> with ctrl=true, so models see identical messages from
				// both code paths.
				return make_key_action(RUNE, cp, ctrl, alt, shift, action, total);
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
				default: return make_key(ESC, 0, false, false, false, 1);
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

	// UTF-8 lead byte: decode a multi-byte codepoint into a RUNE key.
	// Expected length is checked here because xray::utf8_decode maps
	// truncated sequences to '?' instead of reporting "need more data".
	if (b >= 0x80) {
		sz need;
		if ((b & 0xE0) == 0xC0) {
			need = 2;
		} else if ((b & 0xF0) == 0xE0) {
			need = 3;
		} else if ((b & 0xF8) == 0xF0) {
			need = 4;
		} else {
			// Invalid lead (stray continuation or 0xF8+) — consume to make progress
			return make_key(NONE, 0, false, false, false, 1);
		}
		if (buf.len < need) {
			// Incomplete sequence — need more data
			return make_key(NONE, 0, false, false, false, 0);
		}
		for (sz i = 1; i < need; i++) {
			// Invalid continuation byte — consume the lead only
			if ((buf[i] & 0xC0) != 0x80) {
				return make_key(NONE, 0, false, false, false, 1);
			}
		}
		uint cp;
		xray::utf8_decode((String)buf[:need], &cp);
		return make_key(RUNE, cp, false, false, false, need);
	}

	// Anything else: consume to make progress
	return make_key(NONE, 0, false, false, false, 1);
}

// utf8_encode writes a codepoint as UTF-8 into out (room for 4 bytes required).
// Returns the number of bytes written (1-4). Counterpart to xray::utf8_decode,
// for consumers that store KeyMsg.rune into byte-oriented text buffers.
fn sz utf8_encode(uint cp, char[] out) {
	if (cp < 0x80) {
		out[0] = (char)cp;
		return 1;
	}
	if (cp < 0x800) {
		out[0] = (char)(0xC0 | (cp >> 6));
		out[1] = (char)(0x80 | (cp & 0x3F));
		return 2;
	}
	if (cp < 0x10000) {
		out[0] = (char)(0xE0 | (cp >> 12));
		out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[2] = (char)(0x80 | (cp & 0x3F));
		return 3;
	}
	out[0] = (char)(0xF0 | (cp >> 18));
	out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
	out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
	out[3] = (char)(0x80 | (cp & 0x3F));
	return 4;
}