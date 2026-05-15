module xray @test;

import std::core::dstring;

// ============================================================
// Color tests
// ============================================================

fn void test_color_ansi_fg() @test {
	Color c = color_ansi(1); // red
	String sgr = c.to_sgr_fg();
	assert(sgr == "\x1b[31m");
}

fn void test_color_ansi_bg() @test {
	Color c = color_ansi(4); // blue
	String sgr = c.to_sgr_bg();
	assert(sgr == "\x1b[44m");
}

fn void test_color_bright_fg() @test {
	Color c = color_ansi(9); // bright red
	String sgr = c.to_sgr_fg();
	assert(sgr == "\x1b[91m");
}

fn void test_color_256_fg() @test {
	Color c = color_256(196);
	String sgr = c.to_sgr_fg();
	assert(sgr == "\x1b[38;5;196m");
}

fn void test_color_truecolor_fg() @test {
	Color c = color_rgb(255, 128, 0);
	String sgr = c.to_sgr_fg();
	assert(sgr == "\x1b[38;2;255;128;0m");
}

fn void test_color_truecolor_bg() @test {
	Color c = color_rgb(0, 0, 0);
	String sgr = c.to_sgr_bg();
	assert(sgr == "\x1b[48;2;0;0;0m");
}

fn void test_color_none_sgr() @test {
	Color c = color_none();
	assert(c.to_sgr_fg() == "");
	assert(c.to_sgr_bg() == "");
}

fn void test_color_hex() @test {
	Color c = color_hex("#ff8000");
	assert(c.r == 255);
	assert(c.g == 128);
	assert(c.b == 0);
	assert(c.kind == ColorKind.TRUECOLOR);
}

fn void test_color_eq() @test {
	assert(color_ansi(1).eq(color_ansi(1)));
	assert(!color_ansi(1).eq(color_ansi(2)));
	assert(color_rgb(100, 200, 50).eq(color_rgb(100, 200, 50)));
	assert(!color_rgb(100, 200, 50).eq(color_rgb(100, 200, 51)));
}

fn void test_palette_256() @test {
	// Index 0 should be black
	Color black = palette_256(0);
	assert(black.r == 0 && black.g == 0 && black.b == 0);

	// Index 15 should be bright white
	Color white = palette_256(15);
	assert(white.r == 255 && white.g == 255 && white.b == 255);

	// Index 196 should be red (5,0,0 in cube → 255,0,0)
	Color red = palette_256(196);
	assert(red.r == 255 && red.g == 0 && red.b == 0);

	// Grayscale: index 232 should be dark gray
	Color gray = palette_256(232);
	assert(gray.r == 8 && gray.g == 8 && gray.b == 8);
}

fn void test_downsample_truecolor_to_256() @test {
	// Pure red should map to index 196
	char idx = downsample_truecolor_to_256(255, 0, 0);
	assert(idx == 196);
}

// ============================================================
// Style tests
// ============================================================

fn void test_style_default_is_empty() @test {
	Style s = default_style();
	assert(s.is_empty());
}

fn void test_style_set_fg() @test {
	Style s = default_style().set_fg(color_ansi(1));
	assert(!s.is_empty());
	assert(s.fg.kind == ColorKind.ANSI);
	assert(s.fg.index == 1);
}

fn void test_style_full_sgr() @test {
	Style s = default_style()
		.set_fg(color_ansi(1))
		.set_bg(color_ansi(4))
		.set_bold(true);
	String sgr = s.to_sgr();
	// Should contain reset, bold, red fg, blue bg
	assert(sgr.len > 0);
	assert(sgr != "\x1b[0m"); // has attributes
}

fn void test_style_diff_no_change() @test {
	Style a = default_style().set_bold(true);
	Style b = default_style().set_bold(true);
	assert(a.diff_sgr(b) == "");
}

fn void test_style_diff_fg_change() @test {
	Style prev = default_style().set_fg(color_ansi(1));
	Style next = default_style().set_fg(color_ansi(4));
	String sgr = next.diff_sgr(prev);
	// Should emit reset + new fg color
	assert(sgr.len > 0);
}

fn void test_style_diff_bold_off() @test {
	Style prev = default_style().set_bold(true);
	Style next = default_style();
	String sgr = next.diff_sgr(prev);
	// Should emit \x1b[0m (reset clears bold)
	assert(sgr.len > 0);
}

// ============================================================
// Cell tests
// ============================================================

fn void test_empty_cell() @test {
	Cell c = empty_cell();
	assert(c.width == 1);
	assert(c.content_len == 1);
	assert(c.content[0] == ' ');
}

fn void test_new_cell() @test {
	Style s = default_style().set_fg(color_ansi(2));
	Cell c = new_cell("A", 1, s);
	assert(c.width == 1);
	assert(c.content_len == 1);
	assert(c.content[0] == 'A');
	assert(c.style.fg.index == 2);
}

fn void test_cell_eq() @test {
	Cell a = empty_cell();
	Cell b = empty_cell();
	assert(a.eq(b));
}

fn void test_cell_neq_content() @test {
	Cell a = new_cell("A", 1, default_style());
	Cell b = new_cell("B", 1, default_style());
	assert(!a.eq(b));
}

fn void test_cell_neq_style() @test {
	Cell a = new_cell("A", 1, default_style());
	Cell b = new_cell("A", 1, default_style().set_bold(true));
	assert(!a.eq(b));
}

// ============================================================
// ScreenBuffer tests
// ============================================================

fn void test_screen_buffer_new() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 5);
	defer { sb.destroy(); mem::free(sb); }

	assert(sb.width == 10);
	assert(sb.height == 5);
	assert(sb.full_redraw);

	Cell* c = sb.cell_at(0, 0);
	assert(c != null);
	assert(c.width == 1);
}

fn void test_screen_buffer_set_cell() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 5);
	defer { sb.destroy(); mem::free(sb); }
	sb.swap(); // clear full_redraw for this test

	Cell red = new_cell("X", 1, default_style().set_fg(color_ansi(1)));
	sb.set_cell(3, 2, red);

	assert(sb.dirty_lines[2]);
	assert(!sb.dirty_lines[0]);

	Cell* c = sb.cell_at(3, 2);
	assert(c.content[0] == 'X');
}

fn void test_screen_buffer_set_string() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }
	sb.swap();

	sb.set_string(0, 0, "Hello", default_style());
	assert(sb.dirty_lines[0]);

	Cell* c = sb.cell_at(0, 0);
	assert(c.content[0] == 'H');

	c = sb.cell_at(4, 0);
	assert(c.content[0] == 'o');
}

fn void test_screen_buffer_diff_no_changes() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.swap(); // clear full_redraw

	// After swap, no changes → render_diff should produce nothing
	DString out = dstring::temp();
	Style pen = default_style();
	sb.render_diff(&out, &pen);
	assert(out.str_view().len == 0);
}

fn void test_screen_buffer_diff_full_redraw() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	// full_redraw is true by default

	sb.set_string(0, 0, "Hi", default_style());

	DString out = dstring::temp();
	Style pen = default_style();
	sb.render_diff(&out, &pen);

	String result = out.str_view();
	// Should contain clear + home
	assert(result.len > 0);
	// Should contain cursor positioning and content
}

fn void test_screen_buffer_diff_incremental() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }

	sb.set_string(0, 0, "Frame1", default_style());
	DString out1 = dstring::temp();
	Style pen1 = default_style();
	sb.render_diff(&out1, &pen1);
	sb.swap();

	// Now change only row 1
	sb.set_string(0, 1, "Changed", default_style());
	DString out2 = dstring::temp();
	Style pen2 = pen1; // carry over pen state
	sb.render_diff(&out2, &pen2);

	String diff = out2.str_view();
	// The diff should NOT contain a full clear
	// It should only address row 2
	assert(diff.len > 0);
}

fn void test_screen_buffer_needs_redraw() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }

	assert(sb.needs_redraw()); // full_redraw=true
	sb.swap();
	assert(!sb.needs_redraw()); // clean

	sb.set_cell(0, 0, new_cell("X", 1, default_style()));
	assert(sb.needs_redraw()); // dirty line
}

fn void test_screen_buffer_resize() @test {
	ScreenBuffer* sb = new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.swap();

	sb.resize(20, 10);
	assert(sb.width == 20);
	assert(sb.height == 10);
	assert(sb.full_redraw);
}

// ============================================================
// UTF-8 decode tests
// ============================================================

fn void test_utf8_ascii() @test {
	uint cp;
	sz len = utf8_decode("A", &cp);
	assert(len == 1);
	assert(cp == 65);
}

fn void test_utf8_2byte() @test {
	// U+00E9 = é = 0xC3 0xA9
	uint cp;
	sz len = utf8_decode("\xc3\xa9", &cp);
	assert(len == 2);
	assert(cp == 0xE9);
}

fn void test_utf8_3byte() @test {
	// U+4E2D = 中 = 0xE4 0xB8 0xAD
	uint cp;
	sz len = utf8_decode("\xe4\xb8\xad", &cp);
	assert(len == 3);
	assert(cp == 0x4E2D);
}

// ============================================================
// ANSI parser tests
// ============================================================

fn void test_ansi_parser_plain_text() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "Hello", default_style());
	Cell* c = sb.cell_at(0, 0);
	assert(c.content[0] == 'H');
	assert(c.style.fg.is_none());
}

fn void test_ansi_parser_bold() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "\x1b[1mB", default_style());
	Cell* c = sb.cell_at(0, 0);
	assert(c.content[0] == 'B');
	assert(c.style.attrs.bold);
}

fn void test_ansi_parser_fg_color() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "\x1b[31mR", default_style());
	Cell* c = sb.cell_at(0, 0);
	assert(c.content[0] == 'R');
	assert(c.style.fg.index == 1);
	assert(c.style.fg.kind == ColorKind.ANSI);
}

fn void test_ansi_parser_truecolor() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "\x1b[38;2;255;128;0mX", default_style());
	Cell* c = sb.cell_at(0, 0);
	assert(c.style.fg.kind == ColorKind.TRUECOLOR);
	assert(c.style.fg.r == 255);
	assert(c.style.fg.g == 128);
	assert(c.style.fg.b == 0);
}

fn void test_ansi_parser_color_256() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "\x1b[38;5;196mX", default_style());
	Cell* c = sb.cell_at(0, 0);
	assert(c.style.fg.kind == ColorKind.ANSI256);
	assert(c.style.fg.index == 196);
}

fn void test_ansi_parser_reset() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "\x1b[1;31mR\x1b[0mN", default_style());
	// First cell: bold red
	Cell* c1 = sb.cell_at(0, 0);
	assert(c1.style.attrs.bold);
	assert(c1.style.fg.index == 1);
	// Second cell: default after reset
	Cell* c2 = sb.cell_at(1, 0);
	assert(!c2.style.attrs.bold);
	assert(c2.style.fg.is_none());
}

fn void test_ansi_parser_newline() @test {
	ScreenBuffer* sb = new_screen_buffer(20, 5);
	defer { sb.destroy(); mem::free(sb); }

	sb.render_ansi_string(0, 0, "A\nB", default_style());
	Cell* c1 = sb.cell_at(0, 0);
	assert(c1.content[0] == 'A');
	Cell* c2 = sb.cell_at(0, 1);
	assert(c2.content[0] == 'B');
}
