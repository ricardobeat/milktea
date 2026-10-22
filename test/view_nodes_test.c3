module view_nodes_test;
import milktea;
import xray;
import glaze;
import std::core::mem;

fn xray::ScreenBuffer* painted(milktea::Node* root, sz w, sz h, xray::PaintResult* res = null) {
	root.solve(xray::new_rect(0, 0, w, h));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(w, h);
	xray::PaintResult r = sb.paint(root);
	if (res) *res = r;
	return sb;
}

fn void free_buffer(xray::ScreenBuffer* sb) {
	sb.destroy();
	mem::free(sb);
}

fn void test_canvas_copies_the_buffer_where_the_layout_puts_it() @test {
	xray::ScreenBuffer* frame = xray::new_screen_buffer(3, 2);
	defer free_buffer(frame);
	frame.set_string(0, 0, "abc", xray::default_style());
	frame.set_string(0, 1, "def", xray::default_style());

	xray::ScreenBuffer* sb = painted(milktea::root().add(milktea::canvas(frame).at(2, 1)), 10, 4);
	defer free_buffer(sb);

	assert(sb.cell_at(2, 1).content[0] == 'a');
	assert(sb.cell_at(4, 2).content[0] == 'f');
	assert(sb.cell_at(1, 1).content[0] == ' ', "nothing left of it");
}

fn void test_canvas_is_clipped_to_its_rect() @test {
	xray::ScreenBuffer* frame = xray::new_screen_buffer(4, 1);
	defer free_buffer(frame);
	frame.set_string(0, 0, "wxyz", xray::default_style());

	xray::ScreenBuffer* sb = painted(milktea::hstack()
		.add(milktea::canvas(frame).width(milktea::cells(2)))
		.add(milktea::text("|")), 10, 1);
	defer free_buffer(sb);

	assert(sb.cell_at(1, 0).content[0] == 'x');
	assert(sb.cell_at(2, 0).content[0] == '|', "the neighbour is not painted over");
}

fn void test_canvas_cursor_is_relative_to_the_grid() @test {
	xray::ScreenBuffer* frame = xray::new_screen_buffer(4, 2);
	defer free_buffer(frame);

	xray::PaintResult res;
	xray::ScreenBuffer* sb = painted(milktea::root()
		.add(milktea::canvas(frame, { .x = 1, .y = 1, .has_cursor = true }).at(3, 2)), 10, 5, &res);
	defer free_buffer(sb);

	assert(res.cursor.has_cursor);
	assert(res.cursor.x == 4 && res.cursor.y == 3, "got %d,%d", res.cursor.x, res.cursor.y);
}

fn void test_plain_text_is_painted_as_it_is() @test {
	xray::ScreenBuffer* sb = painted(milktea::root().add(milktea::text("\x1b[1mhi\x1b[0m\nyo")), 10, 3);
	defer free_buffer(sb);

	assert(sb.cell_at(0, 0).content[0] == 'h' && sb.cell_at(0, 0).style.attrs.bold);
	assert(sb.cell_at(1, 1).content[0] == 'o');
}

fn void test_plain_text_measures_its_lines() @test {
	milktea::Node* t = milktea::text("one\nthree");
	assert(t.natural_height(20) == 2);
	assert(t.natural_width(1) == 5);
}

fn void test_text_without_a_background_keeps_the_one_beneath() @test {
	xray::Color under = xray::color_rgb(10, 20, 30);
	glaze::Style fill = glaze::style().background(under);
	xray::ScreenBuffer* sb = painted(milktea::root()
		.add(milktea::text("    ", fill))
		.add(milktea::text("\x1b[1mhi\x1b[0m!")), 4, 1);
	defer free_buffer(sb);

	assert(sb.cell_at(0, 0).content[0] == 'h');
	assert(sb.cell_at(0, 0).style.bg.eq(under), "styled run");
	assert(sb.cell_at(2, 0).style.bg.eq(under), "after the reset");
	assert(sb.cell_at(3, 0).style.bg.eq(under), "untouched cell");
}

fn void test_text_with_a_background_paints_it() @test {
	glaze::Style fill = glaze::style().background(xray::color_rgb(10, 20, 30));
	glaze::Style own = glaze::style().background(xray::color_rgb(200, 0, 0));
	xray::ScreenBuffer* sb = painted(milktea::root()
		.add(milktea::text("   ", fill))
		.add(milktea::text("ab", own)), 3, 1);
	defer free_buffer(sb);

	assert(sb.cell_at(1, 0).style.bg.eq(xray::color_rgb(200, 0, 0)));
}

fn void test_children_are_laid_out_inside_a_border() @test {
	glaze::Style boxed = { .border = glaze::DOUBLE };
	milktea::Node* child = milktea::text("x");
	milktea::Node* box = milktea::vstack().style(boxed).with_padding(1, 2, 1, 2).add(child);
	milktea::Node* root = milktea::root().add(box.center());
	root.solve(xray::new_rect(0, 0, 20, 10));

	// One cell of border and the padding on each side.
	assert(box.computed_rect.w == 1 + 2 * 3);
	assert(box.computed_rect.h == 1 + 2 * 2);
	assert(child.computed_rect.x == box.computed_rect.x + 3);
	assert(child.computed_rect.y == box.computed_rect.y + 2);
}

fn void test_a_styled_row_paints_its_background_between_children() @test {
	glaze::Style bar = { .bg = glaze::color_hex("#204060"), .border = glaze::NORMAL };
	milktea::Node* row = milktea::hstack().style(bar)
		.with_justify(milktea::BETWEEN)
		.add(milktea::text("a").width(milktea::cells(1)))
		.add(milktea::text("b").width(milktea::cells(1)));
	xray::ScreenBuffer* sb = painted(milktea::root().add(row), 8, 3);
	defer free_buffer(sb);

	assert((String)sb.cell_at(0, 0).content[:3] == "┌");
	assert(sb.cell_at(1, 1).content[0] == 'a');
	assert(sb.cell_at(6, 1).content[0] == 'b');
	xray::Cell* gap = sb.cell_at(3, 1);
	assert(gap.style.bg.r == 0x20 && gap.style.bg.g == 0x40 && gap.style.bg.b == 0x60, "the box shows between the children");
}

fn void test_style_padding_adds_to_node_padding() @test {
	glaze::Style padded = { .pad_left = 2 };
	milktea::Node* child = milktea::text("x");
	milktea::Node* box = milktea::zstack().style(padded).with_padding(0, 0, 0, 1).add(child);
	milktea::root().add(box).solve(xray::new_rect(0, 0, 10, 2));

	assert(child.computed_rect.x == 3);
}

fn void test_text_padding_moves_the_text_inside_its_background() @test {
	glaze::Style s = { .bg = glaze::color_hex("#102030") };
	milktea::Node* t = milktea::text("x", s).with_padding(0, 0, 0, 2);
	xray::ScreenBuffer* sb = painted(milktea::root().add(t), 6, 1);
	defer free_buffer(sb);

	assert(sb.cell_at(2, 0).content[0] == 'x');
	assert(sb.cell_at(0, 0).style.bg.r == 0x10, "the background covers the padding");
}

fn void test_a_translucent_box_tints_what_is_beneath() @test {
	xray::ScreenBuffer* frame = xray::new_screen_buffer(6, 3);
	defer free_buffer(frame);
	xray::Style under = xray::default_style().set_fg(xray::color_rgb(200, 200, 200)).set_bg(xray::color_rgb(100, 100, 100));
	for (sz y = 0; y < 3; y++) frame.set_string(0, y, "▀▀▀▀▀▀", under);

	glaze::Style tint = { .bg = xray::color_rgba(0, 0, 0, 128), .border = glaze::NORMAL };
	milktea::Node* box = milktea::vstack().style(tint);
	xray::ScreenBuffer* sb = painted(milktea::root().add(milktea::canvas(frame)).add(box), 6, 3);
	defer free_buffer(sb);

	xray::Cell* inside = sb.cell_at(2, 1);
	assert((String)inside.content[:3] == "▀", "the glyph beneath stays");
	assert(inside.style.bg.r / 10 == 4 && inside.style.fg.r / 10 == 9, "both colors are tinted, bg=%d fg=%d", inside.style.bg.r, inside.style.fg.r);
	xray::Cell* corner = sb.cell_at(0, 0);
	assert((String)corner.content[:3] == "┌");
	assert(corner.style.bg.r / 10 == 4, "the border sits on the tint, bg=%d", corner.style.bg.r);
}

fn void test_a_faded_translucent_box_scales_its_border_background_once() @test {
	// An inherited border background must match an explicitly identical one.
	foreach (explicit_bg : (bool[]) { false, true }) {
		xray::ScreenBuffer* sb = xray::new_screen_buffer(5, 3);
		defer free_buffer(sb);
		xray::ScreenBuffer* scratch = null;
		defer if (scratch != null) free_buffer(scratch);
		for (sz y = 0; y < 3; y++) {
			sb.set_string(0, y, "     ", xray::default_style().set_bg(xray::color_rgb(100, 100, 100)));
		}
		glaze::Style tint = { .bg = xray::color_rgba(0, 0, 0, 128), .border = glaze::HIDDEN };
		if (explicit_bg) tint.border_bg = tint.bg;
		milktea::Node* box = milktea::vstack().style(tint).alpha(128);
		box.solve(xray::new_rect(0, 0, 5, 3));
		sb.paint(box, &scratch);

		assert(sb.cell_at(2, 1).style.bg.eq(xray::color_rgb(74, 74, 74)));
		assert(sb.cell_at(0, 0).style.bg.eq(xray::color_rgb(74, 74, 74)));
	}
}

fn void test_a_transparent_border_bg_keeps_the_tint_off_the_border() @test {
	xray::ScreenBuffer* frame = xray::new_screen_buffer(6, 3);
	defer free_buffer(frame);
	xray::Style under = xray::default_style().set_bg(xray::color_rgb(100, 100, 100));
	for (sz y = 0; y < 3; y++) frame.set_string(0, y, "      ", under);

	glaze::Style tint = {
		.bg = xray::color_rgba(0, 0, 0, 128),
		.border = glaze::HIDDEN,
		.border_bg = xray::color_transparent(),
	};
	xray::ScreenBuffer* sb = painted(milktea::root().add(milktea::canvas(frame)).add(milktea::vstack().style(tint)), 6, 3);
	defer free_buffer(sb);

	assert(sb.cell_at(0, 0).style.bg.r == 100, "the border cell is untouched, bg=%d", sb.cell_at(0, 0).style.bg.r);
	assert(sb.cell_at(2, 1).style.bg.r / 10 == 4, "inside is tinted, bg=%d", sb.cell_at(2, 1).style.bg.r);
}
