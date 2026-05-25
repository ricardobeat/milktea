module tea;

import std::core::dstring;

// ============================================================
// Minimal model that records every message it sees
// ============================================================

struct KeyProbeModel {
	int key_count;
	int last_keycode;
	bool quit_seen;
}

fn tea::Cmd KeyProbeModel.init(KeyProbeModel* self) @dynamic {
	return null;
}

fn tea::Cmd KeyProbeModel.update(KeyProbeModel* self, tea::Msg msg) @dynamic {
	switch (msg.kind) {
		case tea::MsgKind.KEY:
			self.key_count++;
			self.last_keycode = (int)msg.key.code;
			return tea::quit();
		case tea::MsgKind.WINDOW_SIZE:
			return null;
		default:
	}
	return null;
}

fn void KeyProbeModel.on_mount(KeyProbeModel* self) @dynamic {
}
fn void KeyProbeModel.on_destroy(KeyProbeModel* self) @dynamic {
}

fn tea::View KeyProbeModel.view(KeyProbeModel* self) @dynamic {
	return tea::new_view("probe");
}

// ============================================================
// Test 1: parse_key directly
// ============================================================

fn void test_parse_key_letter_a() @test {
	char[] input        = "a";
	tea::ParseResult pr = tea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == tea::MsgKind.KEY);
	assert(pr.key.code == tea::KeyCode.RUNE);
	assert(pr.key.rune == 'a');
}

fn void test_parse_key_ctrl_c() @test {
	char[] input        = { 0x03 };
	tea::ParseResult pr = tea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == tea::MsgKind.KEY);
	assert(pr.key.code == tea::KeyCode.CTRL_C);
}

fn void test_parse_key_escape() @test {
	char[] input        = { 0x1b };
	tea::ParseResult pr = tea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == tea::MsgKind.KEY);
	assert(pr.key.code == tea::KeyCode.ESC);
}

fn void test_parse_key_space() @test {
	char[] input        = " ";
	tea::ParseResult pr = tea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == tea::MsgKind.KEY);
	assert(pr.key.code == tea::KeyCode.RUNE);
	assert(pr.key.rune == ' ');
}

fn void test_parse_key_enter() @test {
	char[] input        = { 0x0d };
	tea::ParseResult pr = tea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.kind == tea::MsgKind.KEY);
	assert(pr.key.code == tea::KeyCode.ENTER);
}

// ============================================================
// Test 2: full event loop with single-byte input
// ============================================================

fn void test_single_char_a_quits() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	tea::Program p  = tea::@test_program_input(&m, &out, 80, 24, "a");
	p.run()!!;
	assert(m.key_count == 1);
	assert(m.quit_seen || m.key_count > 0);
}

fn void test_single_ctrl_c_quits() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	tea::Program p  = tea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x03 });
	p.run()!!;
	assert(m.key_count == 1);
}

fn void test_multiple_keys_then_quit() @test {
	KeyProbeModel m = { };
	DString out     = dstring::temp();
	// Three keys: 'x', 'y', 'z'. First key triggers quit.



	tea::Program p = tea::@test_program_input(&m, &out, 80, 24, "xyz");
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

fn tea::Cmd DispatchProbeModel.init(DispatchProbeModel* self) @dynamic {
	return null;
}

fn tea::Cmd DispatchProbeModel.update(DispatchProbeModel* self, tea::Msg msg) @dynamic {
	if (self.msg_count < 16) {
		self.msg_kinds[self.msg_count] = (int)msg.kind;
	}
	self.msg_count++;
	if (msg.kind == tea::MsgKind.KEY) return tea::quit();
	return null;
}

fn void DispatchProbeModel.on_mount(DispatchProbeModel* self) @dynamic {
}
fn void DispatchProbeModel.on_destroy(DispatchProbeModel* self) @dynamic {
}

fn tea::View DispatchProbeModel.view(DispatchProbeModel* self) @dynamic {
	return tea::new_view("dispatch-probe");
}

fn void test_dispatch_delivers_key_message() @test {
	DispatchProbeModel m = { };
	DString out          = dstring::temp();
	tea::Program p       = tea::@test_program_input(&m, &out, 80, 24, "q");
	p.run()!!;

	// Should have received: WINDOW_SIZE (from init), then KEY (from 'q')
	assert(m.msg_count >= 2);
	// First message should be WINDOW_SIZE
	assert(m.msg_kinds[0] == (int)tea::MsgKind.WINDOW_SIZE);
	// Second message should be KEY
	assert(m.msg_kinds[1] == (int)tea::MsgKind.KEY);
}