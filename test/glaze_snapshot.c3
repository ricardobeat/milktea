module glaze_snapshot @test;

import snapshot;
import glaze;
import std::core::dstring;

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
		.with_bold(true)
		.render("bold");
	snapshot::assert_snapshot(SNAP, "style_bold", out);
}

fn void test_snap_style_italic() @test {
	String out = glaze::style()
		.with_italic(true)
		.render("italic");
	snapshot::assert_snapshot(SNAP, "style_italic", out);
}

fn void test_snap_style_underline() @test {
	String out = glaze::style()
		.with_underline(true)
		.render("underline");
	snapshot::assert_snapshot(SNAP, "style_underline", out);
}

fn void test_snap_style_bold_fg() @test {
	String out = glaze::style()
		.with_bold(true)
		.foreground(glaze::color_ansi(2))
		.render("bold green");
	snapshot::assert_snapshot(SNAP, "style_bold_fg", out);
}

// ============================================================
// Style.render — dimensions
// ============================================================

fn void test_snap_style_width() @test {
	String out = glaze::style()
		.with_width(20)
		.render("wide");
	snapshot::assert_snapshot(SNAP, "style_width", out);
}

fn void test_snap_style_height() @test {
	String out = glaze::style()
		.with_height(3)
		.render("tall");
	snapshot::assert_snapshot(SNAP, "style_height", out);
}

fn void test_snap_style_width_height() @test {
	String out = glaze::style()
		.with_width(12)
		.with_height(4)
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
		.with_width(20)
		.align(glaze::Position.CENTER, glaze::Position.CENTER)
		.render("centered");
	snapshot::assert_snapshot(SNAP, "style_align_center", out);
}

fn void test_snap_style_align_right() @test {
	String out = glaze::style()
		.with_width(20)
		.align_horizontal(glaze::Position.RIGHT)
		.render("right");
	snapshot::assert_snapshot(SNAP, "style_align_right", out);
}

fn void test_snap_style_align_bottom() @test {
	String out = glaze::style()
		.with_height(5)
		.align_vertical(glaze::Position.BOTTOM)
		.render("bottom");
	snapshot::assert_snapshot(SNAP, "style_align_bottom", out);
}

// ============================================================
// Style.render — borders
// ============================================================

fn void test_snap_style_border_rounded() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.render("rounded");
	snapshot::assert_snapshot(SNAP, "style_border_rounded", out);
}

fn void test_snap_style_border_thick() @test {
	String out = glaze::style()
		.with_border(glaze::THICK)
		.render("thick");
	snapshot::assert_snapshot(SNAP, "style_border_thick", out);
}

fn void test_snap_style_border_double() @test {
	String out = glaze::style()
		.with_border(glaze::DOUBLE)
		.render("double");
	snapshot::assert_snapshot(SNAP, "style_border_double", out);
}

fn void test_snap_style_border_normal() @test {
	String out = glaze::style()
		.with_border(glaze::NORMAL)
		.render("normal");
	snapshot::assert_snapshot(SNAP, "style_border_normal", out);
}

fn void test_snap_style_border_colored() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex("#ff5fd7"))
		.render("pink border");
	snapshot::assert_snapshot(SNAP, "style_border_colored", out);
}

fn void test_snap_style_border_fg() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.foreground(glaze::color_ansi(3))
		.border_fg(glaze::color_ansi(6))
		.render("yellow text, cyan border");
	snapshot::assert_snapshot(SNAP, "style_border_fg", out);
}

fn void test_snap_style_border_padding() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.padding(1, 2, 1, 2)
		.render("border + padding");
	snapshot::assert_snapshot(SNAP, "style_border_padding", out);
}

fn void test_snap_style_border_width() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.with_width(20)
		.render("fixed width");
	snapshot::assert_snapshot(SNAP, "style_border_width", out);
}

// ============================================================
// Style.render — multiline
// ============================================================

fn void test_snap_style_multiline() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.render("line one\nline two\nline three");
	snapshot::assert_snapshot(SNAP, "style_multiline", out);
}

fn void test_snap_style_multiline_border_width() @test {
	String out = glaze::style()
		.with_border(glaze::ROUNDED)
		.with_width(20)
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
		.with_bold(true)
		.with_border(glaze::ROUNDED)
		.border_fg(glaze::color_hex("#87afaf"))
		.padding(1, 2, 1, 2)
		.with_width(24)
		.align_horizontal(glaze::Position.CENTER)
		.render("full style");
	snapshot::assert_snapshot(SNAP, "style_full", out);
}

// ============================================================
// Border.wrap — standalone
// ============================================================

fn void test_snap_border_wrap_rounded() @test {
	String out = glaze::ROUNDED.wrap("box");
	snapshot::assert_snapshot(SNAP, "border_wrap_rounded", out);
}

fn void test_snap_border_wrap_multiline() @test {
	String out = glaze::THICK.wrap("top\nbottom");
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

// ============================================================
// truncate_to_width
// ============================================================

fn void test_truncate_to_width_ascii() @test {
	assert(glaze::truncate_to_width("hello world", 5) == "hello");
	assert(glaze::truncate_to_width("hi", 10) == "hi");
	assert(glaze::truncate_to_width("hi", 0) == "");
}

fn void test_truncate_to_width_keeps_wide_chars_whole() @test {
	// 日本 is 4 columns. A 3-column limit fits only the first glyph — the
	// second must be dropped, not half-included.
	assert(glaze::truncate_to_width("日本", 4) == "日本");
	assert(glaze::truncate_to_width("日本", 3) == "日");
	assert(glaze::truncate_to_width("日本", 1) == "");
}

fn void test_truncate_to_width_never_splits_escape() @test {
	// The escape costs no width and must be carried through whole; cutting at
	// a byte index would emit "\x1b[3" as literal visible text.
	String s = glaze::truncate_to_width("\x1b[31mabcdef\x1b[0m", 3);
	assert(glaze::string_width(s) == 3);
	// Whatever prefix we kept must still measure as valid styled text.
	assert(s.len > 3); // escape bytes are included but unmeasured
}

fn void test_render_long_input_is_not_truncated() @test {
	// The line table used to be a fixed stack array that silently dropped
	// content past line 256 — rendering a long log or file lost everything
	// after that, with no marker in the output.
	DString in = dstring::temp();
	for (int i = 0; i < 300; i++) {
		in.appendf("line %d\n", i);
	}
	String out = glaze::style().render(in.str_view());

	// First and last lines must both survive (the old code cut at line 256).
	String[] needles = { "line 0", "line 299" };
	foreach (needle : needles) {
		bool found = false;
		for (sz i = 0; i + needle.len <= out.len && !found; i++) {
			bool match = true;
			for (sz j = 0; j < needle.len; j++) {
				if (out[i + j] != needle[j]) {
					match = false;
					break;
				}
			}
			found = match;
		}
		assert(found);
	}
}

// A border with only some sides drawn used to cost a blank row where each
// missing side should have been, which made a partial border — a half-block
// shadow down two edges, say — unusable.
fn void test_partial_border_draws_only_its_sides() @test {
	glaze::Border shadow = { .right = "▌", .bottom = "▀", .bottom_right = "▘" };
	glaze::Style s = { .border = shadow };

	String out = s.render("ok");

	int lines = 1;
	foreach (c : out) if (c == '\n') lines++;
	assert(lines == 2, "one content row and one bottom row, not four: %s", out);
	assert(!out.starts_with("\n"), "no blank row where the top border is absent");
}

// height is the block's total height. Content taller than it used to overflow,
// so a bordered box rendered one row past the size it was given — painting
// over whatever the layout had put below it, including its own drop shadow.
fn void test_height_clips_content_that_overflows() @test {
	glaze::Style s = { .border = glaze::NORMAL, .height = 5 };

	String out = s.render("a\nb\nc\nd\ne\nf\ng");

	int lines = 1;
	foreach (c : out) if (c == '\n') lines++;
	assert(lines == 5, "five rows including the border, got %d", lines);
}

// A style re-applies itself after a reset inside its content, so the rest of
// the line keeps its background. It must leave alone the channels the content
// sets for itself immediately after that reset — otherwise nested styled
// content, such as a border drawn in its own color, comes out in the outer
// style's foreground.
fn void test_outer_style_does_not_overwrite_inner_colors() @test {
	glaze::Style inner = {
		.border = { .right = "|" },
		.border_color = glaze::color_hex("#111111"),
	};
	glaze::Style outer = { .fg = glaze::color_hex("#ffffff"), .bg = glaze::color_hex("#000055") };

	String out = outer.render(inner.render("hi"));

	// The border's own dark foreground must still be in the output.
	assert(out.contains("38;2;17;17;17"), "inner border color survived: %s", out);
}

// A border normally sits on the block's own background, which is right for a
// box drawn around its content. A border used as a drop shadow needs the
// surface behind the block instead — otherwise the half of each half-block
// cell the shadow does not cover shows the block's own face color.
fn void test_border_bg_overrides_the_block_background() @test {
	glaze::Style s = {
		.bg = glaze::color_hex("#ffff55"),
		.border = { .right = "▌" },
		.border_color = glaze::color_hex("#111111"),
		.border_bg = glaze::color_hex("#000055"),
	};

	String out = s.render("ok");

	assert(out.contains("48;2;0;0;85"), "border drawn on the surface color: %s", out);
}

// bg_gradient makes the block's background a vertical ramp rather than a flat
// color, one step per row across the finished block — border rows included,
// since the gradient runs over the whole thing.
fn void test_bg_gradient_varies_the_background_per_row() @test {
	glaze::Style s = {
		.bg = glaze::color_hex("#000000"),
		.bg_gradient = glaze::color_hex("#ffffff"),
		.height = 4,
		.width = 8,
	};

	String out = s.render("a\nb");

	// The first row keeps the start color and the last reaches the end.
	assert(out.contains("48;2;0;0;0"), "starts at bg: %s", out);
	assert(out.contains("48;2;255;255;255"), "ends at bg_gradient: %s", out);
}

fn void test_bg_gradient_leaves_the_foreground_alone() @test {
	glaze::Style s = {
		.fg = glaze::color_hex("#ff0000"),
		.bg = glaze::color_hex("#000000"),
		.bg_gradient = glaze::color_hex("#ffffff"),
		.height = 4,
	};

	String out = s.render("x\ny\nz");

	assert(out.contains("38;2;255;0;0"), "text keeps its color over the ramp");
}

// A style with no bg_gradient renders exactly as it did before the field
// existed: one background for the whole block.
fn void test_no_bg_gradient_leaves_the_background_flat() @test {
	glaze::Style s = { .bg = glaze::color_hex("#0000aa"), .height = 4, .width = 6 };

	String out = s.render("a\nb");

	assert(!out.contains("48;2;255"), "no other background appears: %s", out);
}
