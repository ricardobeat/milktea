module hover_style_test;
import glaze;
import xray;
import milktea;
import std::core::dstring;

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

// ---- focus ----------------------------------------------------------------

struct FocusProbe {
	bool modal;
	milktea::KeyMsg[] keys;
	// What update() saw focused on each 'x' key: 'a', 'b', 'm' or '-'.
	char[8] seen;
	sz count;
}

fn milktea::Cmd FocusProbe.init(&self) @dynamic {
	foreach (k : self.keys) milktea::g_program.send({ .kind = milktea::MsgKind.KEY, .key = k });
	milktea::g_program.send({ .kind = milktea::MsgKind.QUIT });
	return null;
}

fn milktea::Cmd FocusProbe.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY || msg.key.rune != 'x' || self.count >= 8) return null;
	char c = '-';
	if (milktea::is_focused_named("a")) c = 'a';
	if (milktea::is_focused_named("b")) c = 'b';
	if (milktea::is_focused_named("m")) c = 'm';
	self.seen[self.count++] = c;
	return null;
}

fn milktea::Node* FocusProbe.view(&self) @dynamic {
	milktea::Node* root = milktea::root().add(milktea::vstack()
		.add(milktea::text("a").id("a").focusable().height(xray::cells(1)))
		.add(milktea::text("b").id("b").focusable().height(xray::cells(1))));
	if (self.modal) {
		root.add(milktea::vstack().block_pointer().width(xray::cells(6)).height(xray::cells(2)).at(10, 5)
			.add(milktea::text("m").id("m").focusable()));
	}
	return root;
}

fn String run_focus(FocusProbe* p, milktea::KeyMsg[] keys) {
	DString o = dstring::temp();
	milktea::Program pr = milktea::@test_program(p, &o, 40, 10, { .alt_screen = true });
	p.keys = keys;
	pr.run()!!;
	return (String)p.seen[:p.count];
}

const milktea::KeyMsg TAB = { .code = TAB };
const milktea::KeyMsg BACKTAB = { .code = TAB, .shift = true };
const milktea::KeyMsg PROBE = { .code = RUNE, .rune = 'x' };

fn void test_tab_cycles_focus() @test {
	FocusProbe p;
	String seen = run_focus(&p, { PROBE, TAB, PROBE, TAB, PROBE, TAB, PROBE, BACKTAB, PROBE });
	assert(seen == "-abab", "got %s", seen);
}

fn void test_modal_traps_focus() @test {
	FocusProbe p = { .modal = true };
	String seen = run_focus(&p, { PROBE, TAB, PROBE });
	assert(seen == "mm", "got %s", seen);
}

fn void test_focus_style_paints() @test {
	xray::Node* root = xray::vstack()
		.add(milktea::text("a").id("a").focusable().style({}, focus: { .bg = BLUE }).height(xray::cells(1)))
		.add(milktea::text("b").id("b").focusable().style({}, focus: { .bg = BLUE }).height(xray::cells(1)));
	root.solve(xray::new_rect(0, 0, 10, 3));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.focus_str = "b";
	sb.paint(root);
	assert(!same(sb.cell_at(0, 0).style.bg, BLUE), "unfocused node keeps its bg");
	assert(same(sb.cell_at(0, 1).style.bg, BLUE), "focused node takes its focus bg");
}

// A node used to hold at most 32 children, and in an optimised build the
// 33rd overwrote memory past the array (ted's sidebar, in a tall window).
fn void test_node_takes_many_children() @test {
	xray::Node* v = xray::vstack();
	for (sz i = 0; i < 100; i++) v.add(milktea::text("x").height(xray::cells(1)));
	assert(v.count() == 100);
	v.solve(xray::new_rect(0, 0, 10, 100));
	assert(v.child_rect(99).y == 99, "the last child is laid out where it belongs");
}

// A colourless solid decoration is filled with the node's background as the
// style paints it, hover included; a decoration with its own colour keeps it.
fn xray::Color decoration_fill(xray::Decoration d, sz px, sz py) {
	xray::Node* n = xray::vstack().style({ .bg = GREY }, hover: { .bg = BLUE })
		.width(xray::cells(4)).height(xray::cells(1)).decorate(d);
	xray::Node* root = xray::vstack().add(n);
	root.solve(xray::new_rect(0, 0, 10, 3));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.record_paints();
	sb.pointer_on = px >= 0;
	sb.pointer_x = px;
	sb.pointer_y = py;
	sb.paint(root);
	foreach (op : sb.paint_ops.array_view()) {
		if (op.kind == xray::PaintKind.DECORATION) return op.decoration.color;
	}
	return {};
}

fn void test_decoration_takes_style_bg() @test {
	assert(same(decoration_fill(xray::solid().round(4.0f), -1, -1), GREY), "solid() fills with the style's bg");
	assert(same(decoration_fill(xray::solid().round(4.0f), 1, 0), BLUE), "and with the hover bg under the pointer");
	assert(same(decoration_fill(xray::solid(RED), 1, 0), RED), "an explicit colour is kept");
}
