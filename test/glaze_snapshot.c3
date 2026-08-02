module glaze_snapshot @test;

import snapshot;
import glaze;

const String SNAP = "glaze";

// ============================================================
// Style.render — basic
// ============================================================

fn void test_snap_style_plain() @test {
	String out = glaze::style().render("hello");
	snapshot::assert_snapshot(SNAP, "style_plain", out);
}

fn void test_snap_style_fg() @test {
	String out = glaze::style()
		.foreground(glaze::color_hex("#ff5fd7"))
		.render("colored");
	snapshot::assert_snapshot(SNAP, "style_fg", out);
}

fn void test_snap_style_fg_ansi() @test {
	String out = glaze::style()
		.foreground(glaze::color_ansi(1))
		.render("red");
	snapshot::assert_snapshot(SNAP, "style_fg_ansi", out);
}

fn void test_snap_style_fg_256() @test {
	String out = glaze::style()
		.foreground(glaze::color_256(208))
		.render("orange");
	snapshot::assert_snapshot(SNAP, "style_fg_256", out);
}

fn void test_snap_style_bg() @test {
	String out = glaze::style()
		.background(glaze::color_hex("#000087"))
		.render("bg");
	snapshot::assert_snapshot(SNAP, "style_bg", out);
}

fn void test_snap_style_fg_bg() @test {
	String out = glaze::style()
		.foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#333333"))
		.render("both");
	snapshot::assert_snapshot(SNAP, "style_fg_bg", out);
}

fn void test_snap_style_bold() @test {
	String out = glaze::style()
		.bold(true)
		.render("bold");
	snapshot::assert_snapshot(SNAP, "style_bold", out);
}

fn void test_snap_style_italic() @test {
	String out = glaze::style()
		.italic(true)
		.render("italic");
	snapshot::assert_snapshot(SNAP, "style_italic", out);
}

fn void test_snap_style_underline() @test {
	String out = glaze::style()
		.underline(true)
		.render("underline");
	snapshot::assert_snapshot(SNAP, "style_underline", out);
}

fn void test_snap_style_bold_fg() @test {
	String out = glaze::style()
		.bold(true)
		.foreground(glaze::color_ansi(2))
		.render("bold green");
	snapshot::assert_snapshot(SNAP, "style_bold_fg", out);
}

// ============================================================
// Style.render — dimensions
// ============================================================

fn void test_snap_style_width() @test {
	String out = glaze::style()
		.width(20)
		.render("wide");
	snapshot::assert_snapshot(SNAP, "style_width", out);
}

fn void test_snap_style_height() @test {
	String out = glaze::style()
		.height(3)
		.render("tall");
	snapshot::assert_snapshot(SNAP, "style_height", out);
}

fn void test_snap_style_width_height() @test {
	String out = glaze::style()
		.width(12)
		.height(4)
		.render("box");
	snapshot::assert_snapshot(SNAP, "style_width_height", out);
}

// ============================================================
// Style.render — padding
// ============================================================

fn void test_snap_style_padding() @test {
	String out = glaze::style()
		.padding(1, 2, 1, 2)
		.render("padded");
	snapshot::assert_snapshot(SNAP, "style_padding", out);
}

fn void test_snap_style_padding_fg() @test {
	String out = glaze::style()
		.padding(1, 3, 1, 3)
		.foreground(glaze::color_hex("#00ff87"))
		.render("green pad");
	snapshot::assert_snapshot(SNAP, "style_padding_fg", out);
}

// ============================================================
// Style.render — alignment
// ============================================================

fn void test_snap_style_align_center() @test {
	String out = glaze::style()
		.width(20)
		.align(glaze::Position.CENTER, glaze::Position.CENTER)
		.render("centered");
	snapshot::assert_snapshot(SNAP, "style_align_center", out);
}

fn void test_snap_style_align_right() @test {
	String out = glaze::style()
		.width(20)
		.align_horizontal(glaze::Position.RIGHT)
		.render("right");
	snapshot::assert_snapshot(SNAP, "style_align_right", out);
}

fn void test_snap_style_align_bottom() @test {
	String out = glaze::style()
		.height(5)
		.align_vertical(glaze::Position.BOTTOM)
		.render("bottom");
	snapshot::assert_snapshot(SNAP, "style_align_bottom", out);
}

// ============================================================
// Style.render — borders
// ============================================================

fn void test_snap_style_border_rounded() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.render("rounded");
	snapshot::assert_snapshot(SNAP, "style_border_rounded", out);
}

fn void test_snap_style_border_thick() @test {
	String out = glaze::style()
		.border(glaze::thick_border())
		.render("thick");
	snapshot::assert_snapshot(SNAP, "style_border_thick", out);
}

fn void test_snap_style_border_double() @test {
	String out = glaze::style()
		.border(glaze::double_border())
		.render("double");
	snapshot::assert_snapshot(SNAP, "style_border_double", out);
}

fn void test_snap_style_border_normal() @test {
	String out = glaze::style()
		.border(glaze::normal_border())
		.render("normal");
	snapshot::assert_snapshot(SNAP, "style_border_normal", out);
}

fn void test_snap_style_border_colored() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.border_fg(glaze::color_hex("#ff5fd7"))
		.render("pink border");
	snapshot::assert_snapshot(SNAP, "style_border_colored", out);
}

fn void test_snap_style_border_fg() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.foreground(glaze::color_ansi(3))
		.border_fg(glaze::color_ansi(6))
		.render("yellow text, cyan border");
	snapshot::assert_snapshot(SNAP, "style_border_fg", out);
}

fn void test_snap_style_border_padding() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.padding(1, 2, 1, 2)
		.render("border + padding");
	snapshot::assert_snapshot(SNAP, "style_border_padding", out);
}

fn void test_snap_style_border_width() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.width(20)
		.render("fixed width");
	snapshot::assert_snapshot(SNAP, "style_border_width", out);
}

// ============================================================
// Style.render — multiline
// ============================================================

fn void test_snap_style_multiline() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.render("line one\nline two\nline three");
	snapshot::assert_snapshot(SNAP, "style_multiline", out);
}

fn void test_snap_style_multiline_border_width() @test {
	String out = glaze::style()
		.border(glaze::rounded_border())
		.width(20)
		.render("short\na much longer line here\nmid");
	snapshot::assert_snapshot(SNAP, "style_multiline_border_width", out);
}

// ============================================================
// Style.render — kitchen sink
// ============================================================

fn void test_snap_style_full() @test {
	String out = glaze::style()
		.foreground(glaze::color_hex("#ffaf00"))
		.background(glaze::color_hex("#1c1c1c"))
		.bold(true)
		.border(glaze::rounded_border())
		.border_fg(glaze::color_hex("#87afaf"))
		.padding(1, 2, 1, 2)
		.width(24)
		.align_horizontal(glaze::Position.CENTER)
		.render("full style");
	snapshot::assert_snapshot(SNAP, "style_full", out);
}

// ============================================================
// Border.wrap — standalone
// ============================================================

fn void test_snap_border_wrap_rounded() @test {
	String out = glaze::rounded_border().wrap("box");
	snapshot::assert_snapshot(SNAP, "border_wrap_rounded", out);
}

fn void test_snap_border_wrap_multiline() @test {
	String out = glaze::thick_border().wrap("top\nbottom");
	snapshot::assert_snapshot(SNAP, "border_wrap_multiline", out);
}

// ============================================================
// place / join
// ============================================================

fn void test_snap_place_center() @test {
	String placed = glaze::place(20, 5, "hi");
	String out = glaze::style().background(glaze::color_hex("#333333")).render(placed);
	snapshot::assert_snapshot(SNAP, "place_center", out);
}

fn void test_snap_place_pos() @test {
	String placed = glaze::place_pos(20, 5, glaze::Position.LEFT, glaze::Position.TOP, "tl");
	String out = glaze::style().background(glaze::color_hex("#333333")).render(placed);
	snapshot::assert_snapshot(SNAP, "place_pos", out);
}

fn void test_snap_place_horizontal() @test {
	String placed = glaze::place_pos(20, 5, glaze::Position.RIGHT, glaze::Position.CENTER, "mid");
	String out = glaze::style().background(glaze::color_hex("#333333")).render(placed);
	snapshot::assert_snapshot(SNAP, "place_horizontal", out);
}

fn void test_snap_place_vertical() @test {
	String placed = glaze::place_pos(20, 5, glaze::Position.CENTER, glaze::Position.BOTTOM, "bot");
	String out = glaze::style().background(glaze::color_hex("#333333")).render(placed);
	snapshot::assert_snapshot(SNAP, "place_vertical", out);
}

fn void test_snap_join_horizontal() @test {
	String out = glaze::join_horizontal("left", "right", 2);
	snapshot::assert_snapshot(SNAP, "join_horizontal", out);
}

fn void test_snap_join_vertical() @test {
	String out = glaze::join_vertical(glaze::Position.LEFT, "top", "bottom");
	snapshot::assert_snapshot(SNAP, "join_vertical", out);
}

fn void test_snap_join_horizontal_pos() @test {
	String out = glaze::join_horizontal_pos(glaze::Position.BOTTOM, "short", "tall\nline2", 1);
	snapshot::assert_snapshot(SNAP, "join_horizontal_pos", out);
}

fn void test_snap_join_vertical_pos() @test {
	String out = glaze::join_vertical_pos(glaze::Position.RIGHT, "left", "right");
	snapshot::assert_snapshot(SNAP, "join_vertical_pos", out);
}

// ============================================================
// clip_lines
// ============================================================

fn void test_snap_clip_lines() @test {
	String out = glaze::clip_lines("a\nb\nc\nd\ne", 3);
	snapshot::assert_snapshot(SNAP, "clip_lines", out);
}

fn void test_snap_clip_lines_short() @test {
	String out = glaze::clip_lines("only one", 5);
	snapshot::assert_snapshot(SNAP, "clip_lines_short", out);
}

// ============================================================
// glaze::progress_bar (standalone function)
// ============================================================

fn void test_snap_progress_bar_glaze() @test {
	String out = glaze::progress_bar(20, 50, "█", "░", glaze::color_ansi(2), glaze::color_ansi(8));
	snapshot::assert_snapshot(SNAP, "progress_bar", out);
}

fn void test_snap_progress_bar_full() @test {
	String out = glaze::progress_bar(16, 100, "#", "-", glaze::color_ansi(2), glaze::color_ansi(8));
	snapshot::assert_snapshot(SNAP, "progress_bar_full", out);
}

fn void test_snap_progress_bar_empty() @test {
	String out = glaze::progress_bar(16, 0, "#", "-", glaze::color_ansi(2), glaze::color_ansi(8));
	snapshot::assert_snapshot(SNAP, "progress_bar_empty", out);
}

// ============================================================
// string_width — Unicode display width
// ============================================================

fn void test_string_width_ascii() @test {
	assert(glaze::string_width("hello") == 5);
	assert(glaze::string_width("ab") == 2);
}

fn void test_string_width_arrows() @test {
	assert(glaze::string_width("↑") == 1);
	assert(glaze::string_width("↓") == 1);
	assert(glaze::string_width("↑↓") == 2);
	assert(glaze::string_width("Use ↑↓ to move") == 14);
}

fn void test_string_width_box_drawing() @test {
	assert(glaze::string_width("─") == 1);
	assert(glaze::string_width("╭──╮") == 4);
	assert(glaze::string_width("│") == 1);
}

fn void test_string_width_braille() @test {
	assert(glaze::string_width("⠋") == 1);
	assert(glaze::string_width("⠙⠹⠸") == 3);
}

fn void test_string_width_emoji() @test {
	assert(glaze::string_width("🎉") == 2);
}

fn void test_string_width_ansi_skipped() @test {
	// ANSI escape sequences must not contribute to display width
	String styled = glaze::style().foreground(glaze::color_hex("#ff0000")).render("hello");
	assert(glaze::string_width(styled) == 5);
}

// ============================================================
// string_width — escape-sequence skipping
// ============================================================

fn void test_string_width_skips_csi() @test {
	assert(glaze::string_width("\x1b[31mred\x1b[0m") == 3);
	assert(glaze::string_width("\x1b[38;2;255;128;0mx\x1b[0m") == 1);
}

fn void test_string_width_skips_osc() @test {
	// OSC payloads legitimately contain letters. Treating them like a CSI
	// ended the scan on the first letter and counted the rest as visible
	// text, so this measured 10 instead of 0. viewport.c3 emits OSC 52 for
	// clipboard writes, so this really does flow through here.
	assert(glaze::string_width("\x1b]52;c;QUJDRA==\x07") == 0);
	// ST-terminated form (ESC \) as well as BEL.
	assert(glaze::string_width("\x1b]0;window title\x1b\\") == 0);
	assert(glaze::string_width("\x1b]52;c;QQ==\x07ab") == 2);
}

fn void test_string_width_counts_wide_and_combining() @test {
	assert(glaze::string_width("日本") == 4);
	assert(glaze::string_width("é") == 1); // combining acute adds no width
	assert(glaze::string_width("") == 0);
}

fn void test_string_width_unterminated_escape() @test {
	// Must not run past the end of the string.
	assert(glaze::string_width("\x1b[31") == 0);
	assert(glaze::string_width("\x1b") == 0);
	assert(glaze::string_width("\x1b]52;c;") == 0);
}
