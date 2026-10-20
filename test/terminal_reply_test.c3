module milktea @test;

import std::core::dstring;

fn void terminal_replies_are_not_keys() @test {
	String[4] replies = {
		"\x1b]11;rgb:0202/0505/0303\x1b\\", "\x1b]11;rgb:02/05/03\x07",
		"\x1b_Gi=31;OK\x1b\\", "\x1b]1337;ReportCellSize=16;8\x07"
	};
	foreach (text : replies) {
		ParseResult result = parse_key((char[])text);
		assert(result.consumed == text.len && result.key.code == KeyCode.NONE);
		for (sz n = 2; n < text.len; n++) {
			result = parse_key((char[])text[:n]);
			assert(result.consumed == 0 && result.key.code == KeyCode.NONE);
		}
	}
}

fn void terminal_reply_split_at_every_byte() @test {
	String[2] replies = { "11;rgb:0202/0505/0303\x1b\\", "Gi=31;OK\x1b\\" };
	foreach (index, text : replies) {
		for (sz split = 0; split < text.len; split++) {
			TerminalReply reply; reply.begin(index == 0);
			assert(reply.consume((char[])text[:split]) == split && reply.active);
			assert(reply.consume((char[])text[split..]) == text.len-split && !reply.active);
		}
	}
}

fn void terminal_reply_drains_oversize_body() @test {
	TerminalReply reply; reply.begin(false);
	char[1024] payload;
	foreach (&byte : payload) *byte = 'x';
	assert(reply.consume(payload[..]) == payload.len && reply.active && reply.overflow);
	assert(reply.len == reply.body.len);
	assert(reply.consume((char[])"\x1b") == 1 && reply.active);
	assert(reply.consume((char[])"\\q8") == 1 && !reply.active);
}

fn void terminal_reply_preserves_following_keys_and_interrupt() @test {
	TerminalReply reply; reply.begin(true);
	assert(reply.consume((char[])"11;rgb:02/05/03\x07q8") == 16 && !reply.active);
	reply.begin(false);
	assert(reply.consume((char[])"broken\x03") == 6 && !reply.active);
	assert(parse_key((char[])"\x03").key.code == KeyCode.CTRL_C);
}

fn void terminal_reply_updates_late_capabilities() @test {
	int old_r = g_term_bg_r; int old_g = g_term_bg_g; int old_b = g_term_bg_b;
	bool old_known = g_term_bg_known; bool old_tgp = g_tgp_replied;
	defer {
		g_term_bg_r = old_r; g_term_bg_g = old_g; g_term_bg_b = old_b;
		g_term_bg_known = old_known; g_tgp_replied = old_tgp;
	}
	(void)parse_key((char[])"\x1b]11;rgb:0202/0505/0303\x1b\\");
	assert(g_term_bg_known && g_term_bg_r == 2 && g_term_bg_g == 5 && g_term_bg_b == 3);
	(void)parse_key((char[])"\x1b_Gi=31;OK\x1b\\");
	assert(g_tgp_replied);
}

struct TerminalReplyKeys { sz keys; KeyCode last; }
fn Cmd TerminalReplyKeys.init(&self) @dynamic { return null; }
fn Cmd TerminalReplyKeys.update(&self, Msg msg) @dynamic {
	if (msg.kind == MsgKind.KEY) {
		self.keys++; self.last = msg.key.code;
		if (msg.key.code == KeyCode.ENTER || msg.key.code == KeyCode.CTRL_C) return quit();
	}
	return null;
}
fn Node* TerminalReplyKeys.view(&self) @dynamic { return text("reply input test"); }

fn void terminal_reply_event_loop_drains_beyond_pending_capacity() @test {
	DString input = dstring::temp(); input.append_string("\x1b_G");
	for (sz i = 0; i < 2048; i++) input.append_char('x');
	input.append_string("\x1b\\q8\r");
	TerminalReplyKeys model;
	DString out = dstring::temp();
	Program program = @test_program_input(&model, &out, 80, 24, input.str_view());
	program.run()!!;
	assert(model.keys == 3 && model.last == KeyCode.ENTER);
}

fn void terminal_reply_event_loop_truncated_input_is_quiet() @test {
	TerminalReplyKeys model;
	DString out = dstring::temp();
	Program program = @test_program_input(&model, &out, 80, 24, "\x1b]11;rgb:02");
	program.run()!!;
	assert(model.keys == 0);
}
