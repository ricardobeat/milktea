module utf8_input_test @test;

import milktea;
import boba;

// ============================================================
// UTF-8 keyboard input: parse_key decodes multi-byte sequences
// into Unicode codepoints (KeyMsg.rune).
// ============================================================

fn void test_parse_key_utf8_two_byte() @test {
	char[] input = { 0xC3, 0xA9 }; // é (U+00E9)
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 2);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 0xE9);
}

fn void test_parse_key_utf8_three_byte() @test {
	char[] input = { 0xE4, 0xB8, 0xAD }; // 中 (U+4E2D)
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 3);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 0x4E2D);
}

fn void test_parse_key_utf8_four_byte_emoji() @test {
	char[] input = { 0xF0, 0x9F, 0x98, 0x80 }; // 😀 (U+1F600)
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 4);
	assert(pr.kind == milktea::MsgKind.KEY);
	assert(pr.key.code == milktea::KeyCode.RUNE);
	assert(pr.key.rune == 0x1F600);
}

fn void test_parse_key_utf8_truncated_needs_more() @test {
	// Lead byte only — parser must wait for the continuation byte
	char[] input = { 0xC3 };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 0);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

fn void test_parse_key_utf8_truncated_four_byte() @test {
	// Three bytes of a four-byte sequence — still need more data
	char[] input = { 0xF0, 0x9F, 0x98 };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 0);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

fn void test_parse_key_utf8_invalid_continuation() @test {
	// Valid lead, invalid continuation — consume the lead byte only
	char[] input = { 0xC3, 0x41 };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

fn void test_parse_key_utf8_stray_continuation() @test {
	// Continuation byte with no lead — consume it to make progress
	char[] input = { 0xA9 };
	milktea::ParseResult pr = milktea::parse_key(input);
	assert(pr.consumed == 1);
	assert(pr.key.code == milktea::KeyCode.NONE);
}

// ============================================================
// utf8_encode round-trips codepoints back to bytes
// ============================================================

fn void test_utf8_encode_roundtrip() @test {
	char[4] enc;
	assert(milktea::utf8_encode('a', enc[..]) == 1 && enc[0] == 'a');
	assert(milktea::utf8_encode(0xE9, enc[..]) == 2 && enc[0] == 0xC3 && enc[1] == 0xA9);
	assert(milktea::utf8_encode(0x4E2D, enc[..]) == 3 && enc[0] == 0xE4 && enc[1] == 0xB8 && enc[2] == 0xAD);
	sz n = milktea::utf8_encode(0x1F600, enc[..]);
	assert(n == 4 && enc[0] == 0xF0 && enc[1] == 0x9F && enc[2] == 0x98 && enc[3] == 0x80);
}

// ============================================================
// Typing a non-ASCII rune into boba widgets stores UTF-8 bytes
// ============================================================

fn void test_textinput_utf8_rune() @test {
	boba::TextInput t = boba::new_text_input();
	milktea::KeyMsg k = { .code = milktea::KeyCode.RUNE, .rune = 0xE9 }; // é
	assert(t.handle_key(k));
	assert(t.text() == "é"); // 0xC3 0xA9
	assert(t.len == 2);
	t.backspace();
	t.backspace();
	assert(t.len == 0);
}

fn void test_textarea_utf8_rune() @test {
	boba::Textarea ta = boba::new_textarea(20, 5);
	milktea::KeyMsg k = { .code = milktea::KeyCode.RUNE, .rune = 0x1F600 }; // 😀
	assert(ta.handle_key(k));
	assert(ta.text() == "😀"); // 0xF0 0x9F 0x98 0x80
	assert(ta.len == 4);
}
