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
