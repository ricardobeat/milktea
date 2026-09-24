module wrap_test;

import glaze;
import milktea;
import xray;

fn void test_wrap_breaks_at_spaces() @test {
	assert(glaze::wrap_text("the quick brown fox", 10) == "the quick\nbrown fox");
}

fn void test_wrap_leaves_short_text_alone() @test {
	assert(glaze::wrap_text("short", 10) == "short");
	assert(glaze::wrap_text("no width", 0) == "no width");
}

fn void test_wrap_keeps_newlines_and_indentation() @test {
	assert(glaze::wrap_text("  one two three\nfour", 9) == "  one two\nthree\nfour");
}

fn void test_wrap_breaks_a_word_wider_than_the_line() @test {
	assert(glaze::wrap_text("abcdefghij", 4) == "abcd\nefgh\nij");
}

fn void test_wrap_counts_wide_characters_by_cells() @test {
	// Each of these takes two cells, so three fit in six.
	assert(glaze::wrap_text("日本語日本", 6) == "日本語\n日本");
}

fn void test_wrap_never_splits_an_escape_sequence() @test {
	String s = "\x1b[1mbold\x1b[0m text here";
	assert(glaze::wrap_text(s, 9) == "\x1b[1mbold\x1b[0m text\nhere");
}

fn void test_render_wraps_to_its_width() @test {
	glaze::Style s = { .width = 12, .pad_left = 1, .pad_right = 1 };
	assert(s.render("the quick brown fox") == " the quick  \n brown fox  ");
}

fn void test_render_nowrap_overflows() @test {
	glaze::Style s = { .width = 5, .nowrap = true };
	assert(s.render("overflowing") == "overflowing");
}

fn void test_text_grows_taller_when_its_box_is_narrow() @test {
	glaze::Style box = { .border = glaze::ROUNDED, .pad_left = 1, .pad_right = 1 };
	xray::Node* panel = milktea::vbox(box)
		.add(milktea::text({}, "the quick brown fox jumps over"))
		.max_width(14)
		.center();
	xray::Node* r = xray::root().add(panel);
	r.solve(xray::new_rect(0, 0, 40, 20));

	assert(panel.rect().w == 14, "capped");
	// 10 cells of text per line: "the quick" / "brown fox" / "jumps over".
	assert(panel.rect().h == 3 + 2, "three wrapped lines inside the border");
}

fn void test_render_max_width_wraps_and_min_width_pads() @test {
	glaze::Style capped = { .max_width = 10 };
	assert(capped.render("the quick brown fox") == "the quick \nbrown fox ");
	assert(capped.render("short") == "short", "hugs content under the cap");

	glaze::Style floored = { .min_width = 8 };
	assert(floored.render("hi") == "hi      ");
}

fn void test_style_width_bounds_size_the_node() @test {
	xray::Node* narrow = milktea::vbox({ .min_width = 20 })
		.add(milktea::text({}, "hi"))
		.center();
	xray::Node* r = xray::root().add(narrow);
	r.solve(xray::new_rect(0, 0, 40, 20));
	assert(narrow.rect().w == 20, "the style's floor");
}

fn void test_a_later_max_width_keeps_the_style_floor() @test {
	xray::Node* panel = milktea::vbox({ .min_width = 20, .max_width = 30 })
		.add(milktea::text({}, "the quick brown fox jumps over the lazy dog"))
		.max_width(24)
		.center();
	xray::Node* r = xray::root().add(panel);
	r.solve(xray::new_rect(0, 0, 80, 20));
	assert(panel.rect().w == 24, "the call's cap wins over the style's");

	xray::Node* small = milktea::vbox({ .min_width = 20 })
		.add(milktea::text({}, "hi"))
		.max_width(24)
		.center();
	r = xray::root().add(small);
	r.solve(xray::new_rect(0, 0, 80, 20));
	assert(small.rect().w == 20, "and the style's floor still holds");
}
