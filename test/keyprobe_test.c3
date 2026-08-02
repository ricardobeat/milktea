module milktea;

import std::core::dstring;

// ============================================================
// Minimal model that records every message it sees
// ============================================================

struct KeyProbeModel {
	int key_count;
	int last_keycode;
	bool quit_seen;
}

fn milktea::Cmd KeyProbeModel.init(KeyProbeModel* self) @dynamic {
	return null;
}

fn milktea::Cmd KeyProbeModel.update(KeyProbeModel* self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.KEY:
			self.key_count++;
			self.last_keycode = (int)msg.key.code;
			return milktea::quit();
		case milktea::MsgKind.WINDOW_SIZE:
			return null;
		default:
	}
	return null;
}

fn void KeyProbeModel.on_mount(KeyProbeModel* self) @dynamic {
}
fn void KeyProbeModel.on_destroy(KeyProbeModel* self) @dynamic {
}

fn milktea::View KeyProbeModel.view(KeyProbeModel* self) @dynamic {
	return milktea::new_view("probe");
}

// ============================================================
// Test 1: parse_key directly
// ============================================================

fn void test_parse_key_letter_a() @test {
	char[] input        = "a";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 'a');
}

fn void test_parse_key_ctrl_c() @test {
	char[] input        = { 0x03 };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.CTRL_C);
}

fn void test_parse_key_lone_escape_needs_more() @test {
	// A lone ESC may be the start of a split escape sequence, so
	// parse_key asks for more data; the event loop resolves it.
	char[] input        = { 0x1b };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 0);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

fn void test_parse_key_space() @test {
	char[] input        = " ";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == ' ');
}

fn void test_parse_key_enter() @test {
	char[] input        = { 0x0d };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.ENTER);
}

// ============================================================
// Test 2: full event loop with single-byte input
// ============================================================

fn void test_single_char_a_quits() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	milktea::Program p  = milktea::@test_program_input(&m, &out, 80, 24, "a");
	p.run()!!;
	assert(m.key_count == 1);
	assert(m.quit_seen || m.key_count > 0);
}

fn void test_single_ctrl_c_quits() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	milktea::Program p  = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x03 });
	p.run()!!;
	assert(m.key_count == 1);
}

fn void test_multiple_keys_then_quit() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	// Three keys: 'x', 'y', 'z'. First key triggers quit.



	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, "xyz");
	p.run()!!;
	assert(m.key_count == 1); // should quit on first key
}

fn void test_lone_esc_delivers_esc_key() @test {
	// Injected input is exactly ESC — with input exhausted, the event
	// loop must flush the held ESC as a real keypress without waiting.
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	milktea::Program p  = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x1b });
	p.run()!!;
	assert(m.key_count == 1);
	assert(m.last_keycode == (int)milktea::KeyCode.ESC);
}

fn void test_esc_bracket_a_delivers_single_up() @test {
	// A full arrow sequence must parse as one UP key, never ESC + runes.
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	milktea::Program p  = milktea::@test_program_input(&m, &out, 80, 24, "\x1b[A");
	p.run()!!;
	assert(m.key_count == 1);
	assert(m.last_keycode == (int)milktea::KeyCode.UP);
}

// ============================================================
// Test 3: verify the model actually sees the key via dispatch
// ============================================================

struct DispatchProbeModel {
	int[16] msg_kinds;
	int msg_count;
}

fn milktea::Cmd DispatchProbeModel.init(DispatchProbeModel* self) @dynamic {
	return null;
}

fn milktea::Cmd DispatchProbeModel.update(DispatchProbeModel* self, milktea::Msg msg) @dynamic {
	if (self.msg_count < 16) {
		self.msg_kinds[self.msg_count] = (int)msg.kind;
	}
	self.msg_count++;
	if (msg.kind == milktea::MsgKind.KEY) return milktea::quit();
	return null;
}

fn void DispatchProbeModel.on_mount(DispatchProbeModel* self) @dynamic {
}
fn void DispatchProbeModel.on_destroy(DispatchProbeModel* self) @dynamic {
}

fn milktea::View DispatchProbeModel.view(DispatchProbeModel* self) @dynamic {
	return milktea::new_view("dispatch-probe");
}

// ============================================================
// Test 4: X10 mouse decoding (ESC [ M <b+32> <x+32> <y+32>)
// ============================================================

// Helper: build a 6-byte X10 mouse sequence.
// cb is the raw button byte BEFORE adding 32 (i.e. the decoded value).
// cx/cy are 1-based column/row.
fn char[6] x10_mouse_buf(int cb, int cx, int cy) {
	char[6] buf;
	buf[0] = 0x1b;
	buf[1] = '[';
	buf[2] = 'M';
	buf[3] = (char)(cb + 32);
	buf[4] = (char)(cx + 32);
	buf[5] = (char)(cy + 32);
	return buf;
}

// Plain left-button press: cb=0, col=5, row=10.
fn void test_x10_mouse_left_press() @test {
	char[6] buf             = x10_mouse_buf(0, 5, 10);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_LEFT);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_PRESS);
	assert(pr.mouse.col == 5);
	assert(pr.mouse.row == 10);
	assert(!pr.mouse.shift);
	assert(!pr.mouse.alt);
	assert(!pr.mouse.ctrl);
}

// Shift + left press: cb=4 (bit 2 set = Shift, low 2 bits = 0 = LEFT).
// The old code wrongly treated cb=4 as WHEEL_UP.
fn void test_x10_mouse_shift_left_press() @test {
	char[6] buf             = x10_mouse_buf(4, 3, 7);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_LEFT);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_PRESS);
	assert(pr.mouse.shift);
	assert(!pr.mouse.alt);
	assert(!pr.mouse.ctrl);
}

// Wheel up: cb=64 (bit 64 set, low 2 bits = 0).
fn void test_x10_mouse_wheel_up() @test {
	char[6] buf             = x10_mouse_buf(64, 1, 1);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_WHEEL_UP);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_PRESS);
}

// Wheel down: cb=65 (bit 64 set, low 2 bits = 1).
fn void test_x10_mouse_wheel_down() @test {
	char[6] buf             = x10_mouse_buf(65, 1, 1);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_WHEEL_DOWN);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_PRESS);
}

// Button release: cb=3 (low 2 bits == 3 means release in X10 encoding).
fn void test_x10_mouse_release() @test {
	char[6] buf             = x10_mouse_buf(3, 5, 10);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_NONE);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_RELEASE);
}

// Motion with left button held: cb=32 (bit 32 = motion, low 2 bits = 0 = LEFT).
// The old code would have treated bit 64 as the motion flag — wrong.
fn void test_x10_mouse_motion_left_held() @test {
	char[6] buf             = x10_mouse_buf(32, 8, 4);
	milktea::ParseResult pr = milktea::parse_key(buf[..]);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.MOUSE);
	assert(pr.mouse.button == milktea::MouseButton.MOUSE_LEFT);
	assert(pr.mouse.action == milktea::MouseAction.MOUSE_MOTION);
	assert(pr.mouse.col == 8);
	assert(pr.mouse.row == 4);
}

// ============================================================
// Test 5: Home/End modifier decoding
// ============================================================

fn void test_parse_key_home_no_modifiers() @test {
	// ESC [ H — bare Home, no modifier param
	char[] input        = "\x1b[H";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 3);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.HOME);
	assert(!pr.key.ctrl);
	assert(!pr.key.alt);
	assert(!pr.key.shift);
}

fn void test_parse_key_home_ctrl() @test {
	// ESC [ 1 ; 5 H — Home + Ctrl (mod=5)
	char[] input        = "\x1b[1;5H";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.HOME);
	assert(pr.key.ctrl);
	assert(!pr.key.alt);
	assert(!pr.key.shift);
}

fn void test_parse_key_end_shift() @test {
	// ESC [ 1 ; 2 F — End + Shift (mod=2)
	char[] input        = "\x1b[1;2F";
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 6);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.END);
	assert(!pr.key.ctrl);
	assert(!pr.key.alt);
	assert(pr.key.shift);
}

fn void test_dispatch_delivers_key_message() @test {
	DispatchProbeModel m = { };
	DString out          = dstring::temp();
	milktea::Program p       = milktea::@test_program_input(&m, &out, 80, 24, "q");
	p.run()!!;

	// Should have received: WINDOW_SIZE (from init), then KEY (from 'q')
	assert(m.msg_count >= 2);
	// First message should be WINDOW_SIZE
	assert(m.msg_kinds[0] == (int)milktea::MsgKind.WINDOW_SIZE);
	// Second message should be KEY
	assert(m.msg_kinds[1] == (int)milktea::MsgKind.KEY);
}
// ============================================================
// Terminal replies must not surface as keypresses
//
// Terminals answer capability queries with CSI sequences we don't handle
// (CPR, DA1, DSR, XTWINOPS). Consuming only the ESC left the body in the
// buffer, where it re-parsed as printable ASCII — so a query reply arrived at
// the model as a burst of real RUNE keys, i.e. literal garbage typed into
// whatever had focus.
// ============================================================

// count_key_events runs the parser over a byte string the way the event loop
// does and counts how many events a model would actually observe.
fn int count_key_events(char[] bytes) @private {
	int events = 0;
	sz pos     = 0;
	while (pos < bytes.len) {
		ParseResult r = parse_key(bytes[pos..]);
		if (r.consumed == 0) break;
		bool real_key = r.kind == MsgKind.KEY && r.key.code != KeyCode.NONE;
		if (real_key || r.kind == MsgKind.MOUSE) events++;
		pos += r.consumed;
	}
	return events;
}

fn void test_cpr_reply_produces_no_keys() @test {
	assert(count_key_events((char[])"\x1b[24;80R") == 0);
}

fn void test_da1_reply_produces_no_keys() @test {
	assert(count_key_events((char[])"\x1b[?1;2c") == 0);
}

fn void test_xtwinops_reply_produces_no_keys() @test {
	assert(count_key_events((char[])"\x1b[4;600;800t") == 0);
}

fn void test_malformed_sgr_mouse_produces_no_keys() @test {
	// Wrong parameter count: must be dropped, not re-lexed as text.
	assert(count_key_events((char[])"\x1b[<0;10M") == 0);
}

fn void test_unknown_csi_still_consumes_following_key() @test {
	// Dropping the unknown sequence must not swallow what comes after it.
	assert(count_key_events((char[])"\x1b[24;80Rx") == 1);
}

// ============================================================
// Modifier decoding
// ============================================================

fn void test_arrow_modifiers_use_bitmask() @test {
	// mod 5 = 1 + ctrl(4)
	ParseResult r = parse_key((char[])"\x1b[1;5A");
	assert(r.key.code == KeyCode.UP);
	assert(r.key.ctrl);

	// mod 13 = 1 + ctrl(4) + meta(8). Equality tests against 2/4/6/8 dropped
	// every modifier once a higher bit was set.
	r = parse_key((char[])"\x1b[1;13A");
	assert(r.key.ctrl);
}

fn void test_tilde_sequence_modifiers_are_reported() @test {
	// ESC[3;5~ is Ctrl+Delete; the modifier used to be parsed and discarded,
	// making it indistinguishable from a bare Delete.
	ParseResult r = parse_key((char[])"\x1b[3;5~");
	assert(r.key.code == KeyCode.DELETE);
	assert(r.key.ctrl);

	r = parse_key((char[])"\x1b[15;2~");
	assert(r.key.code == KeyCode.F5);
	assert(r.key.shift);
}

// ============================================================
// Malformed / adversarial input
// ============================================================

fn void test_x10_mouse_out_of_range_is_dropped() @test {
	// X10 encodes coordinates as byte-32, so column 224 arrives as 0x00 and
	// decodes to -32. A negative row/col must never reach the model.
	char[6] bytes = { 0x1b, '[', 'M', ' ', 0x00, 0x00 };
	ParseResult r = parse_key(bytes[..]);
	assert(r.kind != MsgKind.MOUSE);
	assert(r.consumed == 6); // still consumed, so the loop makes progress
}

fn void test_huge_csi_param_is_clamped_not_dropped() @test {
	// Overflowing the accumulator used to wrap it negative, which made
	// parse_csi discard the parameter and change param_count — rerouting the
	// sequence to the wrong handler.
	CSIParse csi = parse_csi((char[])"999999999999m");
	assert(csi.valid);
	assert(csi.param_count == 1);
	assert(csi.params[0] == CSI_PARAM_MAX);
}

fn void test_parse_key_never_consumes_past_buffer() @test {
	// The @ensure contract, exercised over every single-byte input plus a
	// spread of adversarial multi-byte prefixes.
	for (int b = 0; b < 256; b++) {
		char[1] one = { (char)b };
		assert(parse_key(one[..]).consumed <= 1);
	}
	String[] tricky = {
		"\x1b", "\x1b[", "\x1b[<", "\x1b[M", "\x1b[M ", "\x1bO",
		"\xc3", "\xe6\x97", "\xf0\x9f\x98", "\x1b[1;", "\x1b[999",
	};
	foreach (t : tricky) {
		assert(parse_key((char[])t).consumed <= t.len);
	}
}
