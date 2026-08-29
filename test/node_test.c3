module node_test;


import std::core::dstring;
import std::core::mem;
import xray;

// Fixed is test content of a known size that records the rect it was rendered
// at, so a test can assert on layout without parsing the painted output.
struct Fixed (xray::Content) {
	int w, h;
	String fill;
	xray::Rect got;
	bool want_cursor;
}

fn String Fixed.render(&self, xray::Rect r) @dynamic {
	self.got = r;
	DString out = dstring::temp();
	for (int y = 0; y < r.h; y++) {
		if (y > 0) out.append_char('\n');
		for (int x = 0; x < r.w; x++) out.append_string(self.fill);
	}
	return out.str_view();
}

fn int Fixed.measure(&self, int cross) @dynamic => self.h;

fn xray::ContentCursor Fixed.cursor(&self, xray::Rect r) @dynamic {
	if (!self.want_cursor) return {};
	return { .x = r.x + 1, .y = r.y + 2, .has_cursor = true };
}

fn Fixed* fixed(int w, int h, String fill = "x") {
	Fixed* f = mem::tnew(Fixed);
	f.w = w;
	f.h = h;
	f.fill = fill;
	return f;
}

fn void test_vstack_divides_main_axis() @test {
	Fixed* top = fixed(0, 1);
	Fixed* mid = fixed(0, 0);
	Fixed* bot = fixed(0, 1);

	xray::Node* r = xray::vstack()
		.add(xray::content_node(top).height(xray::cells(1)))
		.add(xray::content_node(mid).fill(1))
		.add(xray::content_node(bot).height(xray::cells(1)));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(top.got.y == 0 && top.got.h == 1, "top row");
	assert(mid.got.y == 1 && mid.got.h == 8, "middle takes the rest");
	assert(bot.got.y == 9 && bot.got.h == 1, "bottom row");
	// Children stretch across the cross axis by default.
	assert(mid.got.w == 20, "full width");
}

fn void test_hstack_divides_cross_axis() @test {
	Fixed* left  = fixed(0, 0);
	Fixed* right = fixed(0, 0);

	xray::Node* r = xray::hstack()
		.add(xray::content_node(left).width(xray::cells(6)))
		.add(xray::content_node(right).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 4));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 4);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(left.got.x == 0 && left.got.w == 6, "fixed left column");
	assert(right.got.x == 6 && right.got.w == 14, "right fills");
	assert(right.got.h == 4, "full height");
}

fn void test_nested_stacks_solve_through() @test {
	Fixed* body = fixed(0, 0);

	xray::Node* r = xray::vstack()
		.add(xray::vstack().height(xray::cells(2)))
		.add(xray::hstack()
			.fill(1)
			.add(xray::vstack().width(xray::cells(4)))
			.add(xray::content_node(body).fill(1)));
	r.solve(xray::new_rect(0, 0, 30, 12));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 12);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(body.got.x == 4, "past the sidebar");
	assert(body.got.y == 2, "below the header");
	assert(body.got.w == 26 && body.got.h == 10, "fills what is left");
}

fn void test_centered_node_fits_content() @test {
	Fixed* modal = fixed(0, 3);

	xray::Node* r = xray::root()
		.add(xray::content_node(modal).width(xray::cells(10)).center());
	r.solve(xray::new_rect(0, 0, 40, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 20);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	// Height comes from measure(), width from the explicit constraint.
	assert(modal.got.h == 3, "sized to content");
	assert(modal.got.w == 10, "explicit width kept");
	assert(modal.got.x == 15, "horizontally centered");
	assert(modal.got.y == 8, "vertically centered");
}

fn void test_zstack_paints_later_children_on_top() @test {
	xray::Node* r = xray::root()
		.add(xray::content_node(fixed(0, 0, "a")))
		.add(xray::content_node(fixed(2, 1, "b")).width(xray::cells(2)).center());
	r.solve(xray::new_rect(0, 0, 6, 3));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(6, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(sb.cell_at(0, 0).content[0] == 'a', "base layer");
	assert(sb.cell_at(2, 1).content[0] == 'b', "overlay on top");
}

fn void test_cursor_reported_in_screen_coordinates() @test {
	Fixed* input = fixed(0, 1);
	input.want_cursor = true;

	xray::Node* r = xray::vstack()
		.add(xray::vstack().height(xray::cells(4)))
		.add(xray::content_node(input).fill(1));
	r.solve(xray::new_rect(0, 0, 10, 8));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 8);
	defer { sb.destroy(); mem::free(sb); }
	xray::PaintResult res = sb.paint(r);

	assert(res.cursor.has_cursor, "cursor claimed");
	// Content reports rect-relative +1/+2; the rect starts at row 4.
	assert(res.cursor.x == 1, "column");
	assert(res.cursor.y == 6, "row offset by the header");
}

fn void test_content_that_declines_the_cursor_is_ignored() @test {
	xray::Node* r = xray::vstack().add(xray::content_node(fixed(0, 1)));
	r.solve(xray::new_rect(0, 0, 10, 2));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 2);
	defer { sb.destroy(); mem::free(sb); }
	assert(!sb.paint(r).cursor.has_cursor, "no cursor claimed");
}

fn void test_repaint_interval_is_the_smallest_requested() @test {
	xray::Node* r = xray::vstack()
		.add(xray::content_node(fixed(0, 1)).repaint_after(500))
		.add(xray::content_node(fixed(0, 1)).repaint_after(80))
		.add(xray::content_node(fixed(0, 1)));
	r.solve(xray::new_rect(0, 0, 10, 3));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	assert(sb.paint(r).repaint_ms == 80, "fastest node wins");
}

fn void test_natural_height_sums_children() @test {
	xray::Node* r = xray::vstack()
		.add(xray::content_node(fixed(0, 2)))
		.add(xray::content_node(fixed(0, 3)));
	assert(r.natural_height(20) == 5, "2 + 3");
}

fn void test_natural_height_counts_gap_and_padding() @test {
	xray::Node* r = xray::vstack()
		.with_gap(1)
		.with_padding(2, 0, 1, 0)
		.add(xray::content_node(fixed(0, 2)))
		.add(xray::content_node(fixed(0, 3)));
	assert(r.natural_height(20) == 9, "2 + 3 + 1 gap + 3 padding");
}

fn void test_fill_fits_content_when_the_parent_has_no_fixed_height() @test {
	// Inline mode: nothing constrains the column, so a fill child reports
	// what its content needs rather than expanding.
	xray::Node* r = xray::vstack()
		.add(xray::content_node(fixed(0, 1)).height(xray::cells(1)))
		.add(xray::content_node(fixed(0, 4)).fill(1));
	assert(r.natural_height(20) == 5, "1 + 4");
}

fn void test_fill_divides_when_the_parent_has_a_fixed_height() @test {
	Fixed* body = fixed(0, 4);

	xray::Node* r = xray::vstack()
		.height(xray::cells(10))
		.add(xray::content_node(fixed(0, 1)).height(xray::cells(1)))
		.add(xray::content_node(body).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(body.got.h == 9, "takes the leftover, not its content height");
}

fn void test_padding_insets_children() @test {
	Fixed* inner = fixed(0, 0);

	xray::Node* r = xray::vstack()
		.with_padding(1, 2, 1, 2)
		.add(xray::content_node(inner).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(inner.got.x == 2 && inner.got.y == 1, "inset origin");
	assert(inner.got.w == 16 && inner.got.h == 8, "inset size");
}

fn void test_gap_separates_children() @test {
	Fixed* a = fixed(0, 0);
	Fixed* b = fixed(0, 0);

	xray::Node* r = xray::vstack()
		.with_gap(2)
		.add(xray::content_node(a).height(xray::cells(3)))
		.add(xray::content_node(b).height(xray::cells(3)));
	r.solve(xray::new_rect(0, 0, 10, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 10);
	defer { sb.destroy(); mem::free(sb); }
	sb.paint(r);

	assert(a.got.y == 0, "first child at the top");
	assert(b.got.y == 5, "second child past the gap");
}
