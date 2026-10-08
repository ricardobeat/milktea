module zstack_compositing @test;
import milktea;
import glaze;
import xray;
import std::io;

struct Probe { bool flip; }
fn milktea::Cmd Probe.init(&self) @dynamic => null;
fn milktea::Cmd Probe.update(&self, milktea::Msg msg) @dynamic => null;
fn milktea::View Probe.view(&self) @dynamic {
	glaze::Style card_a = glaze::style().with_width(20).with_height(10)
		.with_border(glaze::ROUNDED).border_fg(glaze::color_hex("#ff0000"));
	glaze::Style card_b = glaze::style().with_width(20).with_height(10)
		.with_border(glaze::ROUNDED).border_fg(glaze::color_hex("#00ff00"));
	milktea::Node* screen = milktea::root()
		.add(milktea::text("footer").at(0, 20));
	if (self.flip) {
		screen.add(milktea::text("B", card_b).at(10, 2));
		screen.add(milktea::text("A", card_a).at(0, 0));
	} else {
		screen.add(milktea::text("A", card_a).at(0, 0));
		screen.add(milktea::text("B", card_b).at(10, 2));
	}
	return milktea::draw(screen);
}

fn void test_zstack_at_composites_in_order() @test {
	Probe p1 = { .flip = false };
	DString o1 = dstring::temp();
	milktea::Program pr1 = milktea::@test_program(&p1, &o1, 60, 24, { .alt_screen = true });
	pr1.send({ .kind = milktea::MsgKind.QUIT });
	pr1.run()!!;
	String a = o1.str_view();

	Probe p2 = { .flip = true };
	DString o2 = dstring::temp();
	milktea::Program pr2 = milktea::@test_program(&p2, &o2, 60, 24, { .alt_screen = true });
	pr2.send({ .kind = milktea::MsgKind.QUIT });
	pr2.run()!!;
	String b = o2.str_view();

	// Both cards and the footer are painted, and flipping the add order
	// changes the composited output.
	assert(a.contains("footer"), "footer missing");
	assert(a.contains("A") && a.contains("B"), "both cards should paint");
	assert(a.contains("footer"), "footer missing");
	assert(a != b, "z-order flip must change the composited frame");

	// .at() sizes a node from its style when the style names a size.
	milktea::Node* n = milktea::root()
		.add(milktea::text("A", glaze::style().with_width(20).with_height(10)).at(0, 0))
		.add(milktea::text("B", glaze::style().with_width(20).with_height(10)).at(10, 2));
	n.solve(xray::new_rect(0, 0, 60, 24));
	assert(n.child_rect(0).w == 20 && n.child_rect(0).h == 10, "card A sized from style");
	assert(n.child_rect(1).x == 10 && n.child_rect(1).y == 2, "card B pinned by at()");
}
