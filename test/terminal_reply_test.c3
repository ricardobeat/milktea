module milktea @test;

import std::core::dstring;
import libc;

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
// Regression tests for the startup probe's reply parser: the whole reply and
// a reply split across two reads must both be recognized. Globals are saved
// and restored so the tests never leak state into other tests.
fn void test_probe_parse_whole_reply() @test {
	bool saved_cell = g_cell_px_known;
	bool saved_kgp = g_tgp_replied;
	g_cell_px_known = false;
	g_tgp_replied = false;
	defer {
		g_cell_px_known = saved_cell;
		g_tgp_replied = saved_kgp;
	}

	char[256] acc;
	sz len = 0;
	char[] seq = "\x1b[6;20;10t\x1b]1337;ReportCellSize=20;10\x07\x1b_Gi=31;OK\x1b\\";
	foreach (b : seq) acc[len++] = b;
	parse_probe_replies(acc[0:len]);
	assert(g_cell_px_known);
	assert(g_tgp_replied);
}

fn void test_probe_parse_waits_for_every_partial_string_reply() @test {
	String[4] replies = {
		"\x1b]11;rgb:0202/0505/0303\x1b\\", "\x1b]11;rgb:02/05/03\x07",
		"\x1b_Gi=31;OK\x1b\\", "\x1b]1337;ReportCellSize=16;8\x07"
	};
	foreach (reply : replies) {
		for (sz n = 0; n < reply.len; n++) {
			assert(parse_probe_replies((char[])reply[:n]).consumed == 0, "partial reply of %d bytes must wait", n);
		}
	}
}

fn void test_probe_preserves_keys_between_split_replies() @test {
	bool saved_kgp = g_tgp_replied;
	defer g_tgp_replied = saved_kgp;
	String source = "q\x1b_Gi=31;OK\x1b\\\x1b[A\x1bqz";
	String keys = "q\x1b[A\x1bqz";
	for (sz split = 0; split <= source.len; split++) {
		g_tgp_replied = false;
		char[64] acc;
		char[64] input;
		mem::copy(acc[..].ptr, source.ptr, split);
		ProbeParse first = parse_probe_replies(acc[:split], input[..]);
		sz len = split - first.consumed;
		for (sz i = 0; i < len; i++) acc[i] = acc[first.consumed + i];
		mem::copy(&acc[len], source[split..].ptr, source.len - split);
		len += source.len - split;
		ProbeParse second = parse_probe_replies(acc[:len], input[first.input_len..]);
		assert(second.consumed == len && g_tgp_replied);
		assert((String)input[:first.input_len + second.input_len] == keys, "keys changed at split %d", split);
	}
}

fn void test_probe_preserves_input_before_an_incomplete_reply() @test {
	char[16] input;
	String source = "q\x1b[A\x1b]11;rgb:02";
	ProbeParse parsed = parse_probe_replies((char[])source, input[..]);
	assert(parsed.consumed == 4 && parsed.input_len == 4);
	assert((String)input[:parsed.input_len] == "q\x1b[A");
}

fn void test_probe_respects_the_input_output_slice() @test {
	char[5] input = { '#', '#', '#', '#', '#' };
	ProbeParse parsed = parse_probe_replies((char[])"abcdef", input[1:3]);
	assert(parsed.consumed == 6 && parsed.input_len == 3);
	assert((String)input[..] == "#abc#");
}

fn void test_probe_parse_split_reply() @test {
	bool saved_cell = g_cell_px_known;
	bool saved_kgp = g_tgp_replied;
	g_cell_px_known = false;
	g_tgp_replied = false;
	defer {
		g_cell_px_known = saved_cell;
		g_tgp_replied = saved_kgp;
	}

	char[256] acc;
	sz len = 0;
	char[] part1 = "\x1b[6;20;10t\x1b]1337;ReportCellSize=20;10\x07\x1b_Gi=31;O";
	foreach (b : part1) acc[len++] = b;
	sz consumed = parse_probe_replies(acc[0:len]).consumed;
	sz keep = len - consumed;
	for (sz j = 0; j < keep; j++) acc[j] = acc[consumed + j];
	len = keep;
	char[] part2 = "K\x1b\\";
	foreach (b : part2) acc[len++] = b;
	parse_probe_replies(acc[0:len]);
	assert(g_tgp_replied);
}

// A crash must leave the shell usable, which means the fatal-signal teardown
// has to turn off every mode the event loop can enable. Pin the sequences here
// so dropping one is caught by the suite rather than by a wedged terminal.
fn void test_fatal_teardown_covers_every_mode() @test {
	const String[8] REQUIRED = {
		"\x1b[?1000l", // base mouse tracking
		"\x1b[?1002l", // cell-motion tracking
		"\x1b[?1003l", // all-motion tracking
		"\x1b[?1006l", // SGR mouse encoding
		"\x1b[?1016l", // SGR-pixels
		"\x1b[?2004l", // bracketed paste
		"\x1b[?1004l", // focus reporting
		"\x1b[?25h",   // show cursor
	};
	foreach (seq : REQUIRED) {
		assert(FATAL_MODE_RESET.contains(seq), "fatal teardown must disable %s", seq);
	}
	// Two pops: the key-events layer sits on top of the base keyboard layer.
	assert(FATAL_MODE_RESET.contains("\x1b[<u\x1b[<u"), "fatal teardown must pop both kitty keyboard layers");
	assert(FATAL_ALT_SCREEN_OFF == "\x1b[?1049l", "fatal teardown must leave the alt screen");
}

// setup_signals must capture the disposition it replaces, and teardown must put
// it back; otherwise a Program run would leave the C3 runtime's crash handlers
// uninstalled, or leave our handler pointing at a dead Program frame.
fn void test_fatal_signal_setup_round_trips() @test {
	libc::Sigaction before;
	libc::sigaction(SIGSEGV, null, &before);

	TtyState saved;
	bool in_alt = true;
	setup_signals(saved, &in_alt);
	defer teardown_signals();

	libc::Sigaction during;
	libc::sigaction(SIGSEGV, null, &during);
	assert(during.sa_sigaction == &fatal_signal_handler, "SIGSEGV must route to the fatal handler");
	assert(g_in_alt_screen_ptr == &in_alt, "the handler must see the Program's alt-screen flag");
	assert(fatal_prev_for(SIGSEGV) != null, "the replaced disposition must be captured");
	assert(fatal_prev_for(SIGSEGV).sa_sigaction == before.sa_sigaction, "captured disposition must match");
	// C3 ends a panic with $$trap(), which raises SIGTRAP on arm64.
	assert(fatal_prev_for(SIGTRAP) != null, "C3 panics must be covered too");

	teardown_signals();
	libc::Sigaction after;
	libc::sigaction(SIGSEGV, null, &after);
	assert(after.sa_sigaction == before.sa_sigaction, "the original disposition must be restored");
	assert(g_in_alt_screen_ptr == null, "teardown must drop the alt-screen pointer");
	assert(!g_tty_saved, "teardown must clear the saved-tty flag");
}
