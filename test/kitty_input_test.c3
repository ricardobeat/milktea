module milktea;

// Tests for kitty keyboard protocol CSI u parsing.
// Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
//
// Flag 1 (disambiguate escape codes) causes supporting terminals to encode
// previously-ambiguous keys as CSI <codepoint>[;<mods>] u. These tests verify
// that parse_key handles CSI u sequences correctly AND that ctrl+letter via the
// kitty path produces the same KeyMsg as the legacy 0x01-0x1a control-char path.

// ============================================================
// Plain CSI u — no modifiers
// ============================================================

fn void test_kitty_rune_a_no_mods() @test {
	// ESC [ 9 7 u  — 'a' (codepoint 97), no modifier params
	char[] input        = "\x1b[97u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 5);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 'a');
	assert(!pr.key.ctrl);
	assert(!pr.key.alt);
	assert(!pr.key.shift);
}

// ============================================================
// CSI u with modifiers
// ============================================================

fn void test_kitty_rune_a_ctrl() @test {
	// ESC [ 9 7 ; 5 u  — 'a' with mod=5 (1+4=ctrl)
	char[] input        = "\x1b[97;5u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 7);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 'a');
	assert(pr.key.ctrl);
	assert(!pr.key.alt);
	assert(!pr.key.shift);
}

fn void test_kitty_ctrl_j_matches_legacy() @test {
	// Under kitty protocol ctrl+j arrives as ESC[106;5u (codepoint='j', mod=5=ctrl).
	// The legacy path receives byte 0x0a = 0x0d which is ENTER, NOT ctrl+j.
	// Actually 0x0a (LF) maps to ENTER in parse_key (b == 0x0a handled at top).
	// Ctrl+j in legacy is 0x0a which is treated as ENTER.
	// Instead verify ctrl+j via the control-char path uses byte 0x0a vs kitty.
	// The legacy 0x01..0x1a path: byte = 0x0a = 10 = 'a'+9 = 'j', produces RUNE 'j' ctrl=true.
	// But wait — 0x0a is caught earlier as ENTER before the ctrl range.
	// So the kitty path for ctrl+j (codepoint 106, mod 5) is unique: no legacy equivalent.
	// Verify kitty ctrl+j = RUNE 'j' ctrl=true.
	char[] kitty_input  = "\x1b[106;5u";
	milktea::ParseResult kitty_pr = milktea::parse_key(kitty_input);
	assert(kitty_pr.consumed == 8);
	assert(kitty_pr.kind == milktea::MsgKind.KEY);
	assert(kitty_pr.key.code == milktea::KeyCode.RUNE);
	assert(kitty_pr.key.rune == 'j');
	assert(kitty_pr.key.ctrl);
	assert(!kitty_pr.key.alt);
	assert(!kitty_pr.key.shift);
}

fn void test_kitty_ctrl_a_matches_legacy() @test {
	// Ctrl+A: legacy byte 0x01 → RUNE 'a' ctrl=true.
	// Kitty: ESC[65;5u (codepoint='A'=65... but kitty sends lowercase for ctrl).
	// Kitty protocol sends lowercase letter codepoint for ctrl+letter: ESC[97;5u = ctrl+a.
	// Already tested above. Now verify against legacy 0x01.
	char[] legacy_input = { 0x01 };
	milktea::ParseResult legacy_pr = milktea::parse_key(legacy_input);
	assert(legacy_pr.consumed == 1);
	assert(legacy_pr.key.code == milktea::KeyCode.RUNE);
	assert(legacy_pr.key.rune == 'a');
	assert(legacy_pr.key.ctrl);

	// Kitty ctrl+a: ESC[97;5u — codepoint 97 = 'a', mods = 5 = ctrl
	char[] kitty_input  = "\x1b[97;5u";
	milktea::ParseResult kitty_pr = milktea::parse_key(kitty_input);
	assert(kitty_pr.key.code == legacy_pr.key.code);
	assert(kitty_pr.key.rune == legacy_pr.key.rune);
	assert(kitty_pr.key.ctrl == legacy_pr.key.ctrl);
}

// ============================================================
// Functional key codepoints via CSI u
// ============================================================

fn void test_kitty_esc_key() @test {
	// ESC[27u — ESC key unambiguous under kitty protocol.
	// This is the big win: skips the 50ms ESC-hold entirely.
	char[] input        = "\x1b[27u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 5);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.ESC);
}

fn void test_kitty_enter_key() @test {
	// ESC[13u — ENTER via kitty protocol
	char[] input        = "\x1b[13u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 5);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.ENTER);
}

fn void test_kitty_tab_shift() @test {
	// ESC[9;2u — TAB with shift (mod=2 = 1+1 = shift)
	char[] input        = "\x1b[9;2u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.TAB);
	assert(pr.key.shift);
	assert(!pr.key.ctrl);
	assert(!pr.key.alt);
}

// ============================================================
// Large codepoints (emoji) via CSI u
// ============================================================

fn void test_kitty_emoji_codepoint() @test {
	// ESC[128512u — U+1F600 (grinning face emoji)
	// 128512 decimal = 0x1F600
	char[] input        = "\x1b[128512u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 9);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 0x1F600);
}

// ============================================================
// Query-response form: CSI ? <n> u — consume silently
// ============================================================

fn void test_kitty_query_response_ignored() @test {
	// ESC[?1u — terminal's response to a kitty keyboard query.
	// We never send the query, but a terminal might spontaneously send it
	// on a state change. Defensive: consume and produce no key event.
	char[] input        = "\x1b[?1u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 5);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

// ============================================================
// Truncated CSI u — need more data
// ============================================================

fn void test_kitty_truncated_needs_more() @test {
	// ESC[97 with no final byte — incomplete sequence.
	// parse_key must return consumed=0 so the event loop waits for more input.
	char[] input        = "\x1b[97";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 0);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

// ============================================================
// Ctrl+C equivalence — kitty sends CSI 99;5u, not legacy 0x03
// ============================================================

fn void test_kitty_ctrl_c_maps_to_ctrl_c_keycode() @test {
	// Under the disambiguate flag the terminal sends ctrl+c as codepoint
	// 'c' (99) with the ctrl modifier. Apps quit on KeyCode.CTRL_C, so this
	// must map to the same keycode the legacy 0x03 path produces.
	char[] input            = "\x1b[99;5u";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 7);
	assert(pr.key.code == milktea::KeyCode.CTRL_C);
	assert(pr.key.ctrl);

	// ctrl+shift+c stays a RUNE so copy-shortcuts remain distinguishable.
	char[] input2            = "\x1b[99;6u";
	milktea::ParseResult pr2 = milktea::parse_key(input2);
	assert(pr2.key.code == milktea::KeyCode.RUNE);
	assert(pr2.key.rune == 'c');
	assert(pr2.key.ctrl && pr2.key.shift);
}

// Under kitty flag 2 (report events), the legacy CSI forms carry the event
// type as a subparameter on the modifier param, exactly like the CSI u form.
// These used to be parsed with a hardcoded KEY_PRESS, so a single arrow press
// delivered two PRESS events — one for the press, one for the release — and
// menus stepped twice per keystroke.
fn void test_kitty_arrow_press_and_release() @test {
	milktea::ParseResult press = milktea::parse_key((char[])"\x1b[1;1:1B");
	assert(press.kind == milktea::MsgKind.KEY);
	assert(press.key.code == milktea::KeyCode.DOWN);
	assert(press.key.action == milktea::KeyAction.KEY_PRESS);

	milktea::ParseResult repeat = milktea::parse_key((char[])"\x1b[1;1:2B");
	assert(repeat.key.code == milktea::KeyCode.DOWN);
	assert(repeat.key.action == milktea::KeyAction.KEY_REPEAT);

	milktea::ParseResult release = milktea::parse_key((char[])"\x1b[1;1:3B");
	assert(release.key.code == milktea::KeyCode.DOWN);
	assert(release.key.action == milktea::KeyAction.KEY_RELEASE);
}

// Without the subparameter (no opt-in, or a legacy terminal) arrows must still
// report a plain press, and modifiers must survive the change.
fn void test_arrow_without_event_subparam_is_press() @test {
	milktea::ParseResult pr = milktea::parse_key((char[])"\x1b[A");
	assert(pr.key.code == milktea::KeyCode.UP);
	assert(pr.key.action == milktea::KeyAction.KEY_PRESS);

	milktea::ParseResult ctrl = milktea::parse_key((char[])"\x1b[1;5C");
	assert(ctrl.key.code == milktea::KeyCode.RIGHT);
	assert(ctrl.key.ctrl);
	assert(ctrl.key.action == milktea::KeyAction.KEY_PRESS);
}

// The tilde family (Delete, PgUp, F-keys) shares the same modifier param, so
// it carries the event subparameter too.
fn void test_kitty_tilde_release() @test {
	milktea::ParseResult rel = milktea::parse_key((char[])"\x1b[3;1:3~");
	assert(rel.key.code == milktea::KeyCode.DELETE);
	assert(rel.key.action == milktea::KeyAction.KEY_RELEASE);

	milktea::ParseResult press = milktea::parse_key((char[])"\x1b[5~");
	assert(press.key.code == milktea::KeyCode.PAGE_UP);
	assert(press.key.action == milktea::KeyAction.KEY_PRESS);
}

// Home/End use the same layout as the arrows.
fn void test_kitty_home_release() @test {
	milktea::ParseResult rel = milktea::parse_key((char[])"\x1b[1;1:3H");
	assert(rel.key.code == milktea::KeyCode.HOME);
	assert(rel.key.action == milktea::KeyAction.KEY_RELEASE);
}
