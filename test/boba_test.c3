module boba_test @test;

import boba;
import milktea;

// ============================================================
// UTF-8 boundary helpers
// ============================================================

fn void test_utf8_prev_boundary_walks_whole_sequence() @test {
	// "aé" = 61 c3 a9 — from offset 3 the previous boundary is 1, not 2.
	char[3] buf = { 'a', 0xc3, 0xa9 };
	assert(boba::utf8_prev_boundary(buf[..], 3) == 1);
	assert(boba::utf8_prev_boundary(buf[..], 1) == 0);
	assert(boba::utf8_prev_boundary(buf[..], 0) == 0);
}

fn void test_utf8_next_boundary_walks_whole_sequence() @test {
	// "日X" = e6 97 a5 58
	char[4] buf = { 0xe6, 0x97, 0xa5, 'X' };
	assert(boba::utf8_next_boundary(buf[..], 0) == 3);
	assert(boba::utf8_next_boundary(buf[..], 3) == 4);
	assert(boba::utf8_next_boundary(buf[..], 4) == 4);
}

fn void test_utf8_boundaries_terminate_on_malformed_input() @test {
	// A buffer that starts with stray continuation bytes must not loop or
	// walk off either end.
	char[3] buf = { 0x80, 0x80, 0x80 };
	assert(boba::utf8_prev_boundary(buf[..], 3) == 0);
	assert(boba::utf8_next_boundary(buf[..], 0) == 3);
}

// ============================================================
// TextInput — editing must preserve UTF-8
// ============================================================

fn void test_textinput_backspace_removes_whole_codepoint() @test {
	// Backspacing one BYTE of "é" left a dangling 0xc3 lead byte, corrupting
	// every subsequent render.
	boba::TextInput ti = boba::new_text_input();
	ti.insert_rune('a');
	ti.insert_rune(0xE9); // é — two bytes
	assert(ti.text().len == 3);

	ti.backspace();
	assert(ti.text() == "a");
}

fn void test_textinput_delete_removes_whole_codepoint() @test {
	boba::TextInput ti = boba::new_text_input();
	ti.insert_rune(0x65E5); // 日 — three bytes
	ti.insert_rune('X');
	ti.cursor = 0;

	ti.delete_char();
	assert(ti.text() == "X");
}

fn void test_textinput_arrows_step_whole_codepoints() @test {
	// Three LEFTs from the end of "héllo" must land before 'é', so the
	// following backspace removes 'é' rather than splitting it.
	boba::TextInput ti = boba::new_text_input();
	ti.insert_rune('h');
	ti.insert_rune(0xE9);
	ti.insert_rune('l');
	ti.insert_rune('l');
	ti.insert_rune('o');

	milktea::KeyMsg left = { .code = milktea::KeyCode.LEFT };
	ti.handle_key(left);
	ti.handle_key(left);
	ti.handle_key(left);
	ti.backspace();

	assert(ti.text() == "hllo");
}

fn void test_textinput_right_steps_whole_codepoint() @test {
	boba::TextInput ti = boba::new_text_input();
	ti.insert_rune(0x65E5); // 日
	ti.cursor = 0;

	milktea::KeyMsg right = { .code = milktea::KeyCode.RIGHT };
	ti.handle_key(right);

	assert(ti.cursor == 3); // past the whole 3-byte sequence
}

// ============================================================
// Textarea
// ============================================================

fn void test_textarea_backspace_removes_whole_codepoint() @test {
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.insert_rune('a');
	ta.insert_rune(0x65E5); // 日

	ta.backspace();
	assert(ta.text() == "a");
}

fn void test_textarea_end_sets_column_to_line_length() @test {
	// cursor_col was computed from self.cursor *after* it had been assigned,
	// so it was always 0 and the rendered cursor jumped to the line start.
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste("hello\nworld");
	ta.cursor = 6;
	ta.cursor_row = 1;
	ta.cursor_col = 0;

	milktea::KeyMsg end = { .code = milktea::KeyCode.END };
	ta.handle_key(end);

	assert(ta.cursor == 11);
	assert(ta.cursor_col == 5);
}

// ============================================================
// Empty-collection navigation
// ============================================================

fn void test_list_end_on_empty_does_not_go_negative() @test {
	// END set cursor to item_count - 1 == -1, and view() then indexed with it.
	boba::List lst = boba::new_list();
	lst.set_size(30, 5);

	milktea::KeyMsg end = { .code = milktea::KeyCode.END };
	lst.handle_key(end);
	assert(lst.cursor == 0);

	lst.view(); // must not index out of bounds
}

fn void test_table_end_on_empty_does_not_go_negative() @test {
	boba::Table t = boba::new_table();
	t.width = 40;
	t.height = 6;
	t.add_column("Name", 10);

	milktea::KeyMsg end = { .code = milktea::KeyCode.END };
	t.handle_key(end);
	assert(t.cursor == 0);

	t.view();
}

fn void test_table_row_capacity_is_enforced() @test {
	// The guard read 256 while the array held 64, so the 65th row wrote past
	// the end of the struct.
	boba::Table t = boba::new_table();
	t.add_column("Name", 10);
	for (int i = 0; i < 200; i++) {
		t.add_row("row");
	}
	assert(t.row_count == boba::MAX_TABLE_ROWS);
}

// ============================================================
// Viewport — width-aware rendering
// ============================================================

fn void test_viewport_renders_multibyte_intact() @test {
	// The render loop stepped one BYTE at a time and wrapped each byte in its
	// own SGR pair, so "日本語" came out as nine replacement glyphs.
	boba::Viewport vp = boba::new_viewport(40, 3);
	vp.add_line("日本語");
	String out = vp.view();

	// The three-byte sequence for 日 must survive contiguously.
	bool found = false;
	for (sz i = 0; i + 2 < out.len; i++) {
		if (out[i] == (char)0xe6 && out[i + 1] == (char)0x97 && out[i + 2] == (char)0xa5) {
			found = true;
			break;
		}
	}
	assert(found);
}

fn void test_viewport_truncates_on_width_boundary() @test {
	// Truncating at a byte index split multi-byte characters and could cut a
	// CSI in half, leaking the escape as visible text.
	boba::Viewport vp = boba::new_viewport(6, 2);
	vp.add_line("日本語日本語日本語");
	vp.view(); // must not produce a partial sequence or trap
}
