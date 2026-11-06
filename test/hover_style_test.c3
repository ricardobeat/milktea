module hover_style_test;
import glaze;
import xray;
import milktea;

const glaze::Color RED = { .kind = TRUECOLOR, .r = 255 };
const glaze::Color BLUE = { .kind = TRUECOLOR, .b = 255 };
const glaze::Color GREEN = { .kind = TRUECOLOR, .g = 255 };
const glaze::Color GREY = { .kind = TRUECOLOR, .r = 40, .g = 40, .b = 40 };

fn bool same(glaze::Color a, glaze::Color b) => a.kind == b.kind && a.r == b.r && a.g == b.g && a.b == b.b;

// row is a menu-like item: a box with a fg and a hover style, holding an
// hstack of two labels that set no colour.
fn xray::Node* row(glaze::Style hover = {}) {
	return xray::hstack().style({ .bg = GREY, .fg = RED }, hover: hover)
		.height(xray::cells(1)).width(xray::cells(10))
		.add(xray::hstack().add(milktea::text("ab").width(xray::cells(2)))
			.add(milktea::text("cd", { .fg = GREEN }).width(xray::cells(2))));
}

fn xray::ScreenBuffer* paint(xray::Node* root, sz px = -1, sz py = -1) {
	root.solve(xray::new_rect(0, 0, 10, 3));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 3);
	sb.pointer_on = px >= 0;
	sb.pointer_x = px;
	sb.pointer_y = py;
	sb.paint(root);
	return sb;
}

fn void test_fg_inherits_through_layout_nodes() @test {
	xray::ScreenBuffer* sb = paint(xray::vstack().add(row()));
	defer { sb.destroy(); mem::free(sb); }
	assert(same(sb.cell_at(0, 0).style.fg, RED), "unstyled text takes the nearest ancestor's fg");
	assert(same(sb.cell_at(2, 0).style.fg, GREEN), "text with its own fg keeps it");
}

fn void test_fg_does_not_leak_to_siblings() @test {
	xray::Node* root = xray::vstack().add(row()).add(milktea::text("ef").height(xray::cells(1)));
	xray::ScreenBuffer* sb = paint(root);
	defer { sb.destroy(); mem::free(sb); }
	assert(!same(sb.cell_at(0, 1).style.fg, RED), "a sibling after the row must not inherit its fg");
}

fn void test_hover_applies_only_under_pointer() @test {
	glaze::Style hover = { .bg = BLUE, .fg = GREEN };
	xray::ScreenBuffer* off = paint(xray::vstack().add(row(hover)), 5, 2);
	defer { off.destroy(); mem::free(off); }
	assert(same(off.cell_at(8, 0).style.bg, GREY), "not hovered: base bg");
	assert(same(off.cell_at(0, 0).style.fg, RED), "not hovered: base fg");

	xray::ScreenBuffer* on = paint(xray::vstack().add(row(hover)), 5, 0);
	defer { on.destroy(); mem::free(on); }
	assert(same(on.cell_at(8, 0).style.bg, BLUE), "hovered: hover bg");
	assert(same(on.cell_at(0, 0).style.fg, GREEN), "hovered: hover fg reaches nested text");
}

fn void test_hover_blocked_by_later_node() @test {
	glaze::Style hover = { .bg = BLUE };
	xray::Node* root = xray::root()
		.add(xray::vstack().add(row(hover)))
		.add(xray::vstack().block_pointer().width(xray::cells(10)).height(xray::cells(3)).at(0, 0));
	xray::ScreenBuffer* sb = paint(root, 5, 0);
	defer { sb.destroy(); mem::free(sb); }
	assert(same(sb.cell_at(8, 0).style.bg, GREY), "a blocking node over the row stops its hover");
}

fn void test_style_twice_keeps_hover() @test {
	xray::Node* n = xray::vstack().style({ .bg = GREY }, hover: { .bg = BLUE }).style({ .fg = RED });
	assert(same(n.hover_box.bg, BLUE) && same(n.box.bg, GREY) && same(n.fg, RED));
}
