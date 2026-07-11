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

fn void test_parse_key_escape() @test {
	char[] input        = { 0x1b };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.ESC);
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