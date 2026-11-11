module pattern_test;

import milktea;

// ── pattern_find ────────────────────────────────────────────────────────────

fn void test_literal_finds_substring() @test {
	sz a, b;
	assert(milktea::pattern_find("save", "click save now", 0, &a, &b));
	assert(a == 6 && b == 10, "span 6..10, got %d..%d", a, b);
}

fn void test_dot_matches_any_char() @test {
	sz a, b;
	assert(milktea::pattern_find("s.ve", "save", 0, &a, &b));
	assert(a == 0 && b == 4, "span 0..4, got %d..%d", a, b);
}

fn void test_star_backtracks() @test {
	// "a.*b" must match the whole of "abxb": greedy then give back.
	sz a, b;
	assert(milktea::pattern_find("a.*b", "abxb", 0, &a, &b));
	assert(a == 0 && b == 4, "span 0..4, got %d..%d", a, b);
}

fn void test_star_matches_zero() @test {
	sz a, b;
	assert(milktea::pattern_find("x*ab", "ab", 0, &a, &b));
	assert(a == 0 && b == 2, "span 0..2, got %d..%d", a, b);
}

fn void test_plus_needs_one() @test {
	sz a, b;
	assert(!milktea::pattern_find("x+ab", "ab", 0, &a, &b));
	assert(milktea::pattern_find("x+ab", "xxab", 0, &a, &b));
	assert(a == 0 && b == 4, "span 0..4, got %d..%d", a, b);
}

fn void test_question_marks_optional() @test {
	sz a, b;
	assert(milktea::pattern_find("colou?r", "color", 0, &a, &b));
	assert(milktea::pattern_find("colou?r", "colour", 0, &a, &b));
}

fn void test_caret_anchors_to_start() @test {
	sz a, b;
	assert(!milktea::pattern_find("^save", "click save", 0, &a, &b));
	assert(milktea::pattern_find("^save", "save now", 0, &a, &b));
	assert(a == 0 && b == 4, "span 0..4, got %d..%d", a, b);
}

fn void test_dollar_anchors_to_end() @test {
	sz a, b;
	assert(!milktea::pattern_find("save$", "save now", 0, &a, &b));
	assert(milktea::pattern_find("save$", "now save", 0, &a, &b));
	assert(a == 4 && b == 8, "span 4..8, got %d..%d", a, b);
}

fn void test_digit_word_space_escapes() @test {
	sz a, b;
	assert(milktea::pattern_find("\\d+", "x 42 y", 0, &a, &b));
	assert(a == 2 && b == 4, "span 2..4, got %d..%d", a, b);
	assert(milktea::pattern_find("\\w+", "a-b", 0, &a, &b));
	assert(a == 0 && b == 1, "span 0..1, got %d..%d", a, b);
	assert(milktea::pattern_find("a\\sb", "a b", 0, &a, &b));
	assert(a == 0 && b == 3, "span 0..3, got %d..%d", a, b);
}

fn void test_nth_finds_the_nth_match() @test {
	sz a, b;
	assert(milktea::pattern_find("ab", "ab ab ab", 1, &a, &b));
	assert(a == 3 && b == 5, "second match 3..5, got %d..%d", a, b);
	assert(milktea::pattern_find("ab", "ab", 2, &a, &b) == false, "no third match");
}

fn void test_empty_pattern_finds_nothing() @test {
	sz a, b;
	assert(!milktea::pattern_find("", "anything", 0, &a, &b));
	assert(!milktea::pattern_find("x*", "qqq", 0, &a, &b), "zero-length match is not a match");
}
