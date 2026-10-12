module milktea @test;

fn void parses_four_digit_reply() @test {
	milktea::report_term_bg_reply(0, 0, 0);
	char[] buf = (char[])"\x1b]11;rgb:1e1e/2a2a/3c3c\x1b\\";
	milktea::parse_probe_replies(buf);
	assert(milktea::terminal_background_known(), "should have parsed");
	assert(milktea::terminal_background_r() == 0x1e, "r=%d", milktea::terminal_background_r());
	assert(milktea::terminal_background_g() == 0x2a, "g=%d", milktea::terminal_background_g());
	assert(milktea::terminal_background_b() == 0x3c, "b=%d", milktea::terminal_background_b());
}

fn void parses_two_digit_reply() @test {
	char[] buf = (char[])"\x1b]11;rgb:ff/80/00\x07";
	milktea::parse_probe_replies(buf);
	assert(milktea::terminal_background_r() == 255, "r=%d", milktea::terminal_background_r());
	assert(milktea::terminal_background_g() == 128, "g=%d", milktea::terminal_background_g());
	assert(milktea::terminal_background_b() == 0, "b=%d", milktea::terminal_background_b());
}
