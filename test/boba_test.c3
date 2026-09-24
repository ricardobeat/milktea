module boba_test @test;

import boba;
import milktea;
import xray;
import std::core::dstring;
import std::core::string;

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
	ti.cursor_pos = 0;

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
	ti.cursor_pos = 0;

	milktea::KeyMsg right = { .code = milktea::KeyCode.RIGHT };
	ti.handle_key(right);

	assert(ti.cursor_pos == 3); // past the whole 3-byte sequence
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
	// cursor_col was computed from self.cursor_pos *after* it had been assigned,
	// so it was always 0 and the rendered cursor jumped to the line start.
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste("hello\nworld");
	ta.cursor_pos = 6;
	ta.cursor_row = 1;
	ta.cursor_col = 0;

	milktea::KeyMsg end = { .code = milktea::KeyCode.END };
	ta.handle_key(end);

	assert(ta.cursor_pos == 11);
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
	vp.free();
}

fn void test_viewport_truncates_on_width_boundary() @test {
	// Truncating at a byte index split multi-byte characters and could cut a
	// CSI in half, leaking the escape as visible text.
	boba::Viewport vp = boba::new_viewport(6, 2);
	vp.add_line("日本語日本語日本語");
	vp.view(); // must not produce a partial sequence or trap
	vp.free();
}

fn void test_viewport_selection_uses_display_columns() @test {
	// Selection anchors come from mouse events, which are DISPLAY columns. The
	// render loop used to advance a char-count column, so a wide glyph
	// (日 = 2 columns) shifted every later boundary one column left: with
	// "日abc" (display 0-1 = 日, 2 = a, 3 = b, 4 = c) and a selection over
	// display columns [2,4), the highlight landed on "bc" instead of "ab".
	boba::Viewport vp = boba::new_viewport(40, 2);
	vp.add_line("日abc");
	vp.has_selection = true;
	vp.sel_start_row = 0;
	vp.sel_start_col = 2;
	vp.sel_end_row = 0;
	vp.sel_end_col = 4;
	String out = vp.view();

	// The selection style is fg #000000 on bg #ffffff. Each selected char is
	// wrapped in its own SGR pair, so the style appears once per selected
	// glyph, followed immediately by that glyph's bytes.
	char[] sel = "\x1b[38;2;0;0;0;48;2;255;255;255m";
	int matches = 0;
	for (sz i = 0; i + sel.len + 1 <= out.len; i++) {
		bool match = true;
		for (sz j = 0; j < sel.len; j++) {
			if (out[i + j] != sel[j]) {
				match = false;
				break;
			}
		}
		if (!match) continue;
		// The glyph following the style must be a or b — never 日 or c.
		char next = out[i + sel.len];
		assert(next == 'a' || next == 'b');
		matches++;
	}
	assert(matches == 2);
	vp.free();
}

// ============================================================
// Textarea — press mapping
// ============================================================
//
// The three tests below each build their own textarea — three lines with the
// middle one wider than the content area, so it wraps — because everything in
// a @test module has to be a test function itself.

fn void test_textarea_press_counts_wrapped_rows() @test {
	// The view draws a line wider than the content area across several rows,
	// so a press names a row rather than a line: reading the row as a line
	// number put the caret on whichever line happened to be that far down.
	DString body = dstring::temp();
	body.append_string("first\n");
	for (int i = 0; i < 120; i++) body.append_char('A');
	body.append_string("\nthird");
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste(body.str_view());
	ta.width = 40;
	ta.height = 10;
	ta.scroll_offset = 0;

	int content_w = 40 - ta.text_offset();
	assert(content_w == 37);

	// Line 1 is one row, so rows 1..4 are line 2's four chunks: row 2 is its
	// second chunk, and a column inside it counts from where that chunk starts.
	int row = -1;
	int col = -1;
	ta.text_pos_at(2, 10, &row, &col);
	assert(row == 1);
	assert(col == content_w + (10 - ta.text_offset()));

	// The chunk after the last one is the next line.
	ta.text_pos_at(5, 5, &row, &col);
	assert(row == 2);
	assert(col == 5 - ta.text_offset());

	// A press past the end of the text belongs at the end of the buffer.
	ta.text_pos_at(9, 3, &row, &col);
	assert(row == 2);
	assert(col == 5);
}

fn void test_textarea_press_reads_from_the_scrolled_top() @test {
	// The render starts at scroll_offset, so screen row 0 is that line — not
	// line 0, which is where a press used to land.
	DString body = dstring::temp();
	body.append_string("first\nsecond\nthird");
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste(body.str_view());
	ta.width = 40;
	ta.height = 10;
	ta.scroll_offset = 2;

	int row = -1;
	int col = -1;
	ta.text_pos_at(0, 5, &row, &col);
	assert(row == 2);
	assert(col == 5 - ta.text_offset());
}

fn void test_textarea_set_cursor_leaves_an_onscreen_view_alone() @test {
	// A press always lands inside the view, so resolving one to a caret must
	// not scroll. The rule this replaced compared line numbers against the
	// view height, which jumps once wrapping puts fewer lines on screen.
	DString body = dstring::temp();
	for (int i = 1; i <= 25; i++) body.append_string(string::tformat("line %d\n", i));
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste(body.str_view());
	ta.width = 40;
	ta.height = 10;
	ta.scroll_offset = 5;

	ta.set_cursor(8, 0);
	assert(ta.cursor_row == 8);
	assert(ta.scroll_offset == 5);

	// A caret that is genuinely off the bottom still comes into view.
	ta.set_cursor(24, 0);
	assert(ta.cursor_row == 24);
	assert(ta.scroll_offset == 24);
}

fn void test_textarea_cursor_sits_on_the_wrapped_chunk() @test {
	// The terminal cursor is placed from the same row count the grid uses, so
	// a wrapped line above the caret has to move it down with the text.
	DString body = dstring::temp();
	body.append_string("first\n");
	for (int i = 0; i < 120; i++) body.append_char('A');
	body.append_string("\nthird");
	boba::Textarea ta = boba::new_textarea(40, 10);
	ta.handle_paste(body.str_view());
	ta.width = 40;
	ta.height = 10;
	ta.scroll_offset = 0;
	ta.focused = true;
	ta.set_cursor(1, 40);

	int content_w = 40 - ta.text_offset();
	xray::ContentCursor c = ta.cursor(xray::new_rect(0, 0, 40, 10));
	assert(c.has_cursor);
	assert(c.y == 2); // line 1's second chunk
	assert(c.x == ta.text_offset() + 40 % content_w);
}

fn void test_textarea_caret_visual_pos_clamps_to_the_last_chunk() @test {
	// A caret one whole chunk wide belongs at the end of the line it is on,
	// not on the row after it, which that line does not have. The render puts
	// it on the last chunk; the row count has to agree or the cursor and the
	// view disagree by a row.
	boba::Textarea ta = boba::new_textarea(40, 10);
	DString body = dstring::temp();
	for (int i = 0; i < 37; i++) body.append_char('A');
	body.append_string("\nbb");
	ta.handle_paste(body.str_view());
	ta.width = 40;
	ta.height = 10;
	ta.scroll_offset = 0;

	int content_w = 40 - ta.text_offset();
	assert(content_w == 37);
	ta.set_cursor(0, content_w);

	int row = -1;
	int col = -1;
	ta.caret_visual_pos(&row, &col);
	assert(row == 0);
	assert(col == content_w);
}

fn void test_textarea_draws_highlight_spans() @test {
	boba::Textarea t = boba::new_textarea(20, 3);
	t.show_line_numbers = false;
	t.focused_style = {};
	t.blurred_style = {};
	foreach (c : "fn main\nx fn") t.insert(c);
	boba::HighlightSpan[2] spans = {
		{ .start = 0, .len = 2, .style = { .bold = true } },
		{ .start = 10, .len = 2, .style = { .italic = true } },
	};
	t.highlights = spans[..];
	String v = t.view();
	assert(v.starts_with("\x1b[1mfn\x1b[0m main\n"), "first span bold, the rest plain");
	assert(v.ends_with("x \x1b[3mfn\x1b[0m"), "a span on the second line lands on its bytes");
}
