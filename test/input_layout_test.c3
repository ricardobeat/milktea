module input_layout_test;
import std::core::dstring;
import milktea;
import glaze;
import xray;
import boba;

struct Mod { boba::TextInput a; boba::TextInput b; }
fn milktea::Cmd Mod.init(&self) @dynamic => null;
fn milktea::Cmd Mod.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.KEY) return milktea::quit();
	return null;
}
fn milktea::View Mod.view(&self) @dynamic {
	glaze::Style box = glaze::style().with_border(glaze::ROUNDED);
	glaze::Style nm = glaze::style().align(glaze::Position.RIGHT, glaze::Position.CENTER);
	milktea::Node* col = milktea::vstack().with_gap(1);
	col.add(milktea::hstack().height(milktea::cells(3)).with_gap(1)
		.add(milktea::text(nm, "one").width(milktea::cells(6)))
		.add(milktea::component(&self.a).fill(1)));
	col.add(milktea::hstack().height(milktea::cells(3)).with_gap(1)
		.add(milktea::text(nm, "two").width(milktea::cells(6)))
		.add(milktea::component(&self.b).fill(1)));
	return milktea::draw(milktea::root().add(col));
}

fn bool contains_seq(String h, String n) {
	if (n.len > h.len) return false;
	for (usz i = 0; i + n.len <= h.len; i++) if (h[i:n.len] == n) return true;
	return false;
}

// A bordered input in a tree: the box is drawn at the size the layout chose,
// and the caret lands inside the border without the app computing an offset.
fn void test_bordered_input_places_its_own_cursor() @test {
	Mod m;
	glaze::Style bx = glaze::style().with_border(glaze::ROUNDED);
	m.a = boba::new_text_input().with_styles(bx, bx);
	m.b = boba::new_text_input().with_styles(bx, bx);
	m.a.placeholder_style = bx;
	m.b.placeholder_style = bx;
	m.a.focused = true;
	m.a.insert('h'); m.a.insert('i');
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 30, 9, "q");
	p.run()!!;
	// strip ANSI for readability
	String s = out.str_view();
	DString d = dstring::temp();
	bool esc = false;
	foreach (c : s) {
		if (c == '\x1b') { esc = true; continue; }
		if (esc) { if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) esc = false; continue; }
		d.append_char(c == '\n' ? '/' : c);
	}
	// The caret sits inside the border, after "hi": rect x 7, +1 border, +2 text.
	assert(contains_seq(s, "\x1b[2;11H"), "cursor at row 2 col 11: %s", d.str_view());
}

// An input draws its frame from the moment it appears. The box used to come
// from placeholder_style, which carries only a color, so a field had no
// border until it had been focused and typed into.
fn void test_empty_unfocused_input_still_draws_its_border() @test {
	glaze::Style bx = glaze::style().with_border(glaze::ROUNDED);
	boba::TextInput inp = boba::new_text_input().with_styles(bx, bx);
	inp.focused = false;
	inp.width = 12;
	inp.height = 3;

	String out = inp.view();
	assert(out.contains("╭"), "top-left corner drawn: %s", out);
	assert(out.contains("╯"), "bottom-right corner drawn: %s", out);
}
