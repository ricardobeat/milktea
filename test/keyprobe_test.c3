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