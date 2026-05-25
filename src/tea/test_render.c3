module tea;

import std::io;
import std::core::dstring;

// ============================================================
// Helpers
// ============================================================

// contains returns true if [haystack] contains [needle].
fn bool contains(String haystack, String needle) {
	if (needle.len == 0) return true;
	if (needle.len > haystack.len) return false;
	for (sz i = 0; i <= haystack.len - needle.len; i++) {
		bool match = true;
		for (sz j = 0; j < needle.len; j++) {
			if (haystack[i + j] != needle[j]) {
				match = false;
				break;
			}
		}
		if (match) return true;
	}
	return false;
}

// ============================================================
// cursor_style_seq encoding
// ============================================================

fn void test_cursor_style_block_blink() @test {
	// Block (0) + blink: (0*2)+1 = 1 → \x1b[1 q
	String s = cursor_style_seq(CursorShape.CURSOR_BLOCK, true);
	assert(contains(s, "\x1b[1 q"));
}

fn void test_cursor_style_block_steady() @test {
	// Block (0) + steady: (0*2)+1+1 = 2 → \x1b[2 q
	String s = cursor_style_seq(CursorShape.CURSOR_BLOCK, false);
	assert(contains(s, "\x1b[2 q"));
}

fn void test_cursor_style_underline_blink() @test {
	// Underline (1) + blink: (1*2)+1 = 3 → \x1b[3 q
	String s = cursor_style_seq(CursorShape.CURSOR_UNDERLINE, true);
	assert(contains(s, "\x1b[3 q"));
}

fn void test_cursor_style_underline_steady() @test {
	// Underline (1) + steady: (1*2)+1+1 = 4 → \x1b[4 q
	String s = cursor_style_seq(CursorShape.CURSOR_UNDERLINE, false);
	assert(contains(s, "\x1b[4 q"));
}

fn void test_cursor_style_bar_blink() @test {
	// Bar (2) + blink: (2*2)+1 = 5 → \x1b[5 q
	String s = cursor_style_seq(CursorShape.CURSOR_BAR, true);
	assert(contains(s, "\x1b[5 q"));
}

fn void test_cursor_style_bar_steady() @test {
	// Bar (2) + steady: (2*2)+1+1 = 6 → \x1b[6 q
	String s = cursor_style_seq(CursorShape.CURSOR_BAR, false);
	assert(contains(s, "\x1b[6 q"));
}

// ============================================================
// View / Cursor construction helpers
// ============================================================

fn void test_new_view_defaults() @test {
	View v = new_view("hello");
	assert(v.content == "hello");
	assert(!v.has_cursor);
	assert(!v.alt_screen);
}

fn void test_new_alt_screen_view() @test {
	View v = new_alt_screen_view("hello");
	assert(v.content == "hello");
	assert(!v.has_cursor);
	assert(v.alt_screen);
}

fn void test_new_cursor_defaults() @test {
	Cursor c = new_cursor(5, 3);
	assert(c.x == 5);
	assert(c.y == 3);
	assert(c.shape == CursorShape.CURSOR_BLOCK);
	assert(c.blink);
}

// ============================================================
// render_view_to — no cursor
// ============================================================

fn void test_render_no_cursor() @test {
	View v      = new_view("hello");
	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	// Should contain the content
	assert(contains(result, "hello"));
	// Should show cursor at end (no cursor_to sequence for positioning)
	assert(contains(result, SGR_SHOW_CURSOR));
}

// ============================================================
// render_view_to — \n → \r\n conversion
// ============================================================

fn void test_render_newline_conversion() @test {
	View v      = new_view("a\nb");
	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	// Should contain \r\n (the \n in content gets \r prepended)
	assert(contains(result, "a\r\nb"));
	// Should NOT contain a bare \n (without preceding \r)
	// The only \n should be preceded by \r
	// (SGR_CLEAR_HOME contains \x1b[H\x1b[2J — no bare \n there either)
}

// ============================================================
// render_view_to — cursor positioning
// ============================================================

fn void test_render_cursor_position_simple() @test {
	// Content: "hello" (one line, no \n)
	// Cursor at x=3, y=0 → terminal (1, 4)
	View v = new_view("hello");
	v.has_cursor = true;
	v.cursor = new_cursor(3, 0);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[1;4H"));
}

fn void test_render_cursor_position_multiline() @test {
	// Content: "line0\nline1\nline2"
	// Cursor at x=2, y=2 → terminal (3, 3)
	View v = new_view("line0\nline1\nline2");
	v.has_cursor = true;
	v.cursor = new_cursor(2, 2);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[3;3H"));
}

fn void test_render_cursor_position_zero_indexed() @test {
	// Content: "abc"
	// Cursor at x=0, y=0 → terminal (1, 1)
	View v = new_view("abc");
	v.has_cursor = true;
	v.cursor = new_cursor(0, 0);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[1;1H"));
}

// ============================================================
// render_view_to — cursor shape is written
// ============================================================

fn void test_render_cursor_shape_block() @test {
	View v = new_view("x");
	v.has_cursor = true;
	v.cursor = new_cursor(0, 0);
	// blink block = style 1

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[1 q"));
}

fn void test_render_cursor_shape_bar_steady() @test {
	View v = new_view("x");
	v.has_cursor = true;
	v.cursor = { .x = 0, .y = 0, .shape = CursorShape.CURSOR_BAR, .blink = false };
	// bar steady = style 6

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[6 q"));
}

// ============================================================
// Simulated textinputs layout — the real-world scenario
// ============================================================

// This test mimics what textinputs.c3 does:
//   title.render("Sign Up") with padding(0,0,1,0) → 2 lines + \n
//   + 2 explicit \n
//   + "Nickname: Nickname\n"
//   + "Email: Email\n"
//   + "Password: Password\n"
// 
// We count content lines (split on \n) to verify base_row.
fn void test_textinputs_line_counting() @test {
	// Simulate the content structure from textinputs view():
	// title produces "Sign Up\n       " (2 visual lines, trailing \n stripped)
	// then 2 explicit \n characters
	// then input lines
	String content = "Sign Up\n       \n\nNickname: Nickname\nEmail: Email\nPassword: Password\n\nhint";

	// Count the lines by splitting on \n
	int line_count = 0;
	for (sz i = 0; i < content.len; i++) {
		if (content[i] == '\n') line_count++;
	}
	// 7 \n characters → 8 lines (0-indexed: 0..7)

	// "Nickname: Nickname" starts after 3 \n characters → line index 3
	// So base_row should be 3 (0-indexed)
	int nickname_line = 0;
	int nl_count      = 0;
	for (sz i = 0; i < content.len; i++) {
		if (content[i] == '\n') {
			nl_count++;
			if (nl_count == 3) {
				nickname_line = (int)(i + 1 < content.len ? i + 1 : i);
				break;
			}
		}
	}
	// After the 3rd \n, the next content is "Nickname: Nickname"
	// The line index is 3 (0-indexed)

	// Now render with cursor at the position textinputs would use:
	// label_cols[0] = 10, cursor_x for empty input = 0
	// So cursor at x=10, y=3 → terminal (4, 11)
	View v = new_alt_screen_view(content);
	v.has_cursor = true;
	v.cursor = new_cursor(10, 3);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	// Should contain cursor move to terminal row 4, col 11
	assert(contains(result, "\x1b[4;11H"));
}

fn void test_textinputs_cursor_after_typing() @test {
	// Same layout, but cursor is 2 chars into the first input.
	// cursor_x = label_cols[0] + cursor_pos = 10 + 2 = 12
	// cursor_y = base_row + 0 = 3
	// → terminal (4, 13)
	String content = "Sign Up\n       \n\nNickname: Jo\nEmail: Email\nPassword: Password\n\nhint";

	View v = new_alt_screen_view(content);
	v.has_cursor = true;
	v.cursor = new_cursor(12, 3);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[4;13H"));
}

fn void test_textinputs_second_input() @test {
	// Focus on second input (Email), cursor at start.
	// Email starts after "Email: " = 7 chars → x=7
	// Email is on line 4 (0-indexed) → y=4
	// → terminal (5, 8)
	String content = "Sign Up\n       \n\nNickname: Nickname\nEmail: Email\nPassword: Password\n\nhint";

	View v = new_alt_screen_view(content);
	v.has_cursor = true;
	v.cursor = new_cursor(7, 4);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	assert(contains(result, "\x1b[5;8H"));
}

// ============================================================
// cursor_to unit test
// ============================================================

fn void test_cursor_to_format() @test {
	assert(cursor_to(1, 1) == "\x1b[1;1H");
	assert(cursor_to(10, 20) == "\x1b[10;20H");
	assert(cursor_to(0, 0) == "\x1b[0;0H");
}

// ============================================================
// Edge case: empty content with cursor
// ============================================================

fn void test_render_empty_content_with_cursor() @test {
	View v = new_view("");
	v.has_cursor = true;
	v.cursor = new_cursor(0, 0);

	DString out = dstring::temp();
	render_view_to(v, &out);
	String result = out.str_view();

	// Cursor at (0,0) → terminal (1,1)
	assert(contains(result, "\x1b[1;1H"));
}