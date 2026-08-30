module node_test;


import std::core::dstring;
import std::core::mem;
import xray;
import boba;

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

fn int Fixed.measure(&self, int width) @dynamic => self.h;
fn int Fixed.measure_width(&self, int height) @dynamic => self.w;

fn xray::ContentCursor Fixed.cursor(&self, xray::Rect r) @dynamic {
	if (!self.want_cursor) return { };
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

	xray::Node* r = xray::vstack().add(xray::content_node(top).height(xray::cells(1)))
		.add(xray::content_node(mid).fill(1))
		.add(xray::content_node(bot).height(xray::cells(1)));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
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

	xray::Node* r = xray::hstack().add(xray::content_node(left).width(xray::cells(6)))
		.add(xray::content_node(right).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 4));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 4);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(left.got.x == 0 && left.got.w == 6, "fixed left column");
	assert(right.got.x == 6 && right.got.w == 14, "right fills");
	assert(right.got.h == 4, "full height");
}

fn void test_nested_stacks_solve_through() @test {
	Fixed* body = fixed(0, 0);

	xray::Node* r = xray::vstack().add(xray::vstack().height(xray::cells(2)))
		.add(xray::hstack().fill(1).add(xray::vstack().width(xray::cells(4))).add(xray::content_node(body).fill(1)));
	r.solve(xray::new_rect(0, 0, 30, 12));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 12);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(body.got.x == 4, "past the sidebar");
	assert(body.got.y == 2, "below the header");
	assert(body.got.w == 26 && body.got.h == 10, "fills what is left");
}

fn void test_centered_node_fits_content() @test {
	Fixed* modal = fixed(0, 3);

	xray::Node* r = xray::root().add(xray::content_node(modal).width(xray::cells(10)).center());
	r.solve(xray::new_rect(0, 0, 40, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	// Height comes from measure(), width from the explicit constraint.
	assert(modal.got.h == 3, "sized to content");
	assert(modal.got.w == 10, "explicit width kept");
	assert(modal.got.x == 15, "horizontally centered");
	assert(modal.got.y == 8, "vertically centered");
}

fn void test_zstack_paints_later_children_on_top() @test {
	xray::Node* r = xray::root().add(xray::content_node(fixed(0, 0, "a")))
		.add(xray::content_node(fixed(2, 1, "b")).width(xray::cells(2)).center());
	r.solve(xray::new_rect(0, 0, 6, 3));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(6, 3);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(sb.cell_at(0, 0).content[0] == 'a', "base layer");
	assert(sb.cell_at(2, 1).content[0] == 'b', "overlay on top");
}

fn void test_cursor_reported_in_screen_coordinates() @test {
	Fixed* input = fixed(0, 1);
	input.want_cursor = true;

	xray::Node* r = xray::vstack().add(xray::vstack().height(xray::cells(4))).add(xray::content_node(input).fill(1));
	r.solve(xray::new_rect(0, 0, 10, 8));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 8);
	defer {
		sb.destroy();
		mem::free(sb);
	}
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
	defer {
		sb.destroy();
		mem::free(sb);
	}
	assert(!sb.paint(r).cursor.has_cursor, "no cursor claimed");
}

fn void test_repaint_interval_is_the_smallest_requested() @test {
	xray::Node* r = xray::vstack().add(xray::content_node(fixed(0, 1)).repaint_after(500))
		.add(xray::content_node(fixed(0, 1)).repaint_after(80))
		.add(xray::content_node(fixed(0, 1)));
	r.solve(xray::new_rect(0, 0, 10, 3));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 3);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	assert(sb.paint(r).repaint_ms == 80, "fastest node wins");
}

fn void test_natural_height_sums_children() @test {
	xray::Node* r = xray::vstack().add(xray::content_node(fixed(0, 2))).add(xray::content_node(fixed(0, 3)));
	assert(r.natural_height(20) == 5, "2 + 3");
}

fn void test_natural_height_counts_gap_and_padding() @test {
	xray::Node* r = xray::vstack().with_gap(1).with_padding(2, 0, 1, 0).add(xray::content_node(fixed(0, 2)))
		.add(xray::content_node(fixed(0, 3)));
	assert(r.natural_height(20) == 9, "2 + 3 + 1 gap + 3 padding");
}

fn void test_fill_fits_content_when_the_parent_has_no_fixed_height() @test {
	// Inline mode: nothing constrains the column, so a fill child reports
	// what its content needs rather than expanding.
	xray::Node* r = xray::vstack().add(xray::content_node(fixed(0, 1)).height(xray::cells(1)))
		.add(xray::content_node(fixed(0, 4)).fill(1));
	assert(r.natural_height(20) == 5, "1 + 4");
}

fn void test_fill_divides_when_the_parent_has_a_fixed_height() @test {
	Fixed* body = fixed(0, 4);

	xray::Node* r = xray::vstack().height(xray::cells(10)).add(xray::content_node(fixed(0, 1)).height(xray::cells(1)))
		.add(xray::content_node(body).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(body.got.h == 9, "takes the leftover, not its content height");
}

fn void test_padding_insets_children() @test {
	Fixed* inner = fixed(0, 0);

	xray::Node* r = xray::vstack().with_padding(1, 2, 1, 2).add(xray::content_node(inner).fill(1));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(inner.got.x == 2 && inner.got.y == 1, "inset origin");
	assert(inner.got.w == 16 && inner.got.h == 8, "inset size");
}

fn void test_gap_separates_children() @test {
	Fixed* a = fixed(0, 0);
	Fixed* b = fixed(0, 0);

	xray::Node* r = xray::vstack().with_gap(2).add(xray::content_node(a).height(xray::cells(3)))
		.add(xray::content_node(b).height(xray::cells(3)));
	r.solve(xray::new_rect(0, 0, 10, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(10, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(a.got.y == 0, "first child at the top");
	assert(b.got.y == 5, "second child past the gap");
}

// Components in a tree. A component sizes itself from the rect the layout
// gives it, so the app stops assigning widths and heights by hand.

fn void test_component_is_sized_by_the_layout() @test {
	boba::List lst = boba::new_list();
	lst.add_item("one", "");
	lst.add_item("two", "");

	xray::Node* r = xray::vstack().add(xray::content_node(&lst).fill(1));
	r.solve(xray::new_rect(0, 0, 30, 12));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 12);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(lst.width == 30, "width taken from the rect");
	assert(lst.height == 12, "height taken from the rect");
}

fn void test_focused_input_reports_its_cursor() @test {
	boba::TextInput inp = boba::new_text_input();
	inp.focused = true;
	inp.insert('h');
	inp.insert('i');

	// Two rows above the input, so the cursor's row must be offset by them.
	xray::Node* r = xray::vstack().add(xray::vstack().height(xray::cells(2)))
		.add(xray::content_node(&inp).height(xray::cells(1)));
	r.solve(xray::new_rect(0, 0, 20, 5));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 5);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	xray::PaintResult res = sb.paint(r);

	assert(res.cursor.has_cursor, "focused input claims the cursor");
	assert(res.cursor.y == 2, "row comes from the layout, not a hand count");
	assert(res.cursor.x == 2, "column is the caret offset");
}

fn void test_unfocused_input_does_not_claim_the_cursor() @test {
	boba::TextInput a = boba::new_text_input();
	boba::TextInput b = boba::new_text_input();
	a.focused = true;
	b.focused = false;

	// The unfocused input is painted last. Without each component reporting
	// whether it owns the cursor, last-one-wins would put it in the wrong box.
	xray::Node* r = xray::vstack().add(xray::content_node(&a).height(xray::cells(1)))
		.add(xray::content_node(&b).height(xray::cells(1)));
	r.solve(xray::new_rect(0, 0, 20, 2));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 2);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	xray::PaintResult res = sb.paint(r);

	assert(res.cursor.has_cursor, "the focused one claims it");
	assert(res.cursor.y == 0, "and it is the first input, not the last painted");
}

// A component under center() is sized from what it reports on both axes.
// Reporting only a height leaves it one row tall and no columns wide, which
// paints nothing.
fn void test_centered_component_has_a_width() @test {
	boba::Timer t = boba::new_timer(90);

	xray::Node* n = xray::content_node(&t).center();
	xray::root().add(n).solve(xray::new_rect(0, 0, 40, 10));

	assert(n.rect().h == 1, "one row tall");
	assert(n.rect().w > 0, "and wide enough to show the clock");
}

// at() pins a node to a known offset inside a stack, for content whose
// position is decided by something other than the layout — a dropdown under
// the menu title that opened it.
fn void test_at_pins_a_node_and_fits_it() @test {
	Fixed* menu = fixed(20, 4);

	xray::Node* r = xray::root().add(xray::content_node(menu).at(8, 1));
	r.solve(xray::new_rect(0, 0, 40, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(menu.got.x == 8 && menu.got.y == 1, "pinned where asked");
	assert(menu.got.w == 20 && menu.got.h == 4, "and sized to its content");
}

fn void test_at_keeps_an_explicit_size() @test {
	Fixed* box = fixed(0, 4);

	xray::Node* r = xray::root().add(xray::content_node(box).width(xray::cells(12)).at(3, 2));
	r.solve(xray::new_rect(0, 0, 40, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(box.got.w == 12, "explicit width survives at()");
	assert(box.got.x == 3, "still pinned");
}

// Content that is sometimes hidden returns null rather than an empty node, so
// the caller adds it unconditionally.
fn void test_add_ignores_a_null_child() @test {
	xray::Node* r = xray::root().add(xray::content_node(fixed(4, 1))).add(null);

	assert(r.count() == 1, "the null child was not added");
}

// ── offset() ────────────────────────────────────────────────────────────────

// offset displaces a node from where it was placed, without resizing it.
fn void test_offset_shifts_a_centred_node() @test {
	Fixed* f = fixed(10, 4);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(10)).height(xray::cells(4)).center().offset(0, -3));
	r.solve(xray::new_rect(0, 0, 30, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	// Centred would be x=10, y=8; the offset lifts it three rows.
	assert(f.got.x == 10, "x stays centred, got %d", f.got.x);
	assert(f.got.y == 5, "y lifted by 3, got %d", f.got.y);
}

// The point of offset over padding: the node keeps its size, so its background
// does not stretch to cover the displacement.
fn void test_offset_does_not_resize() @test {
	Fixed* f = fixed(10, 4);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(10)).height(xray::cells(4)).center().offset(4, 2));
	r.solve(xray::new_rect(0, 0, 30, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(f.got.w == 10 && f.got.h == 4, "size unchanged, got %dx%d", f.got.w, f.got.h);
}

// offset composes with a pin too, rather than being an alternative to it.
fn void test_offset_composes_with_at() @test {
	Fixed* f = fixed(6, 2);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(6)).height(xray::cells(2)).at(3, 4).offset(2, 1));
	r.solve(xray::new_rect(0, 0, 30, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(f.got.x == 5, "pinned x plus offset, got %d", f.got.x);
	assert(f.got.y == 5, "pinned y plus offset, got %d", f.got.y);
}

// A zero offset must leave placement exactly as it was, so the field is
// invisible to every node that does not use it.
fn void test_zero_offset_changes_nothing() @test {
	Fixed* f      = fixed(10, 4);
	xray::Node* r = xray::root().add(xray::content_node(f).width(xray::cells(10)).height(xray::cells(4)).center());
	r.solve(xray::new_rect(0, 0, 30, 20));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 20);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(f.got.x == 10 && f.got.y == 8, "centred as before, got %d,%d", f.got.x, f.got.y);
}

// In a column, offsetting one child must not move its siblings -- that is the
// difference from changing its size.
fn void test_offset_in_a_column_leaves_siblings_alone() @test {
	Fixed* top = fixed(0, 1);
	Fixed* mid = fixed(0, 1);
	Fixed* bot = fixed(0, 1);

	xray::Node* r = xray::vstack().add(xray::content_node(top).height(xray::cells(1)))
		.add(xray::content_node(mid).height(xray::cells(1)).offset(3, 0))
		.add(xray::content_node(bot).height(xray::cells(1)));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	sb.paint(r);

	assert(mid.got.x == 3, "offset child moved, got %d", mid.got.x);
	assert(top.got.x == 0 && bot.got.x == 0, "siblings unmoved");
	assert(top.got.y == 0 && mid.got.y == 1 && bot.got.y == 2, "rows unchanged");
}
// ── shadows and alpha ───────────────────────────────────────────────────────

// A shadow is cast by the node, so it fades with it. Without this a modal
// animating in would show a solid shadow under translucent content.
fn void test_shadow_fades_with_node_alpha() @test {
	// Same tree twice, once opaque and once half-faded, comparing the shadow
	// cell just outside the node's own rect.
	int[2] alphas = { 0, 128 };
	int[2] darkness;

	for (int k = 0; k < 2; k++) {
		Fixed* f = fixed(6, 2);
		xray::Node* n = xray::content_node(f).width(xray::cells(6)).height(xray::cells(2)).at(1, 1)
			.shadow(xray::shadow(1, 1, 255, 0).with_color(xray::color_rgb(0, 0, 0)));
		if (alphas[k] != 0) n.alpha((char)alphas[k]);
		xray::Node* r = xray::root().add(n);
		r.solve(xray::new_rect(0, 0, 20, 10));

		xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
		defer {
			sb.destroy();
			mem::free(sb);
		}
		// Start from white so a black shadow is visible as a drop in value.
		for (sz y = 0; y < 10; y++) {
			for (sz x = 0; x < 20; x++) {
				xray::Cell* c = sb.cell_at(x, y);
				c.style.bg = xray::color_rgb(255, 255, 255);
			}
		}
		sb.paint(r);

		// (7,3) is inside the shadow (node spans x 1..6, y 1..2; shadow is
		// offset by 1) and outside the node itself.
		xray::Cell* shade = sb.cell_at(7, 3);
		darkness[k] = 255 - (int)shade.style.bg.r;
	}

	assert(darkness[0] > 0, "opaque node casts a shadow (got %d)", darkness[0]);
	assert(darkness[1] > 0, "faded node still casts one (got %d)", darkness[1]);
	assert(darkness[1] < darkness[0], "a half-faded node casts a lighter shadow: %d vs %d", darkness[1], darkness[0]);
}

// alpha 0 is the unset default and means "opaque", so it must not wipe out a
// shadow on every node that never calls .alpha().
fn void test_shadow_unaffected_by_zero_alpha() @test {
	Fixed* f = fixed(6, 2);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(6)).height(xray::cells(2)).at(1, 1)
			.shadow(xray::shadow(1, 1, 200, 0).with_color(xray::color_rgb(0, 0, 0))));
	r.solve(xray::new_rect(0, 0, 20, 10));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 10);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	for (sz y = 0; y < 10; y++) {
		for (sz x = 0; x < 20; x++) {
			sb.cell_at(x, y).style.bg = xray::color_rgb(255, 255, 255);
		}
	}
	sb.paint(r);

	xray::Cell* shade = sb.cell_at(7, 3);
	assert(shade.style.bg.r < 100, "unset alpha leaves the shadow at full strength, got r=%d", (int)shade.style.bg.r);
}
// A blurred shadow's fringe should step evenly. blend_over is linear in alpha,
// so an even alpha ramp is what the eye reads as a smooth gradient; the
// quadratic falloff this replaced dropped most of its opacity in the first
// step and banded there.
fn void test_blurred_shadow_falls_off_evenly() @test {
	Fixed* f = fixed(8, 2);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(8)).height(xray::cells(2)).at(2, 2)
			.shadow(xray::shadow(1, 1, 200, 3).with_color(xray::color_rgb(0, 0, 0))));
	r.solve(xray::new_rect(0, 0, 20, 14));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 14);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	for (sz y = 0; y < 14; y++) {
		for (sz x = 0; x < 20; x++) sb.cell_at(x, y).style.bg = xray::color_rgb(200, 200, 200);
	}
	sb.paint(r);

	int prev     = -1;
	int min_step =  999;
	int max_step =  0;
	for (sz y = 4; y <= 8; y++) {
		int v = (int)sb.cell_at(6, y).style.bg.r;
		if (prev >= 0) {
			int step = v - prev;
			if (step < min_step) min_step = step;
			if (step > max_step) max_step = step;
		}
		prev = v;
	}

	// The fringe lightens the whole way out, and no single step carries most of
	// the drop. Steps taper towards the outer edge rather than being equal.
	assert(min_step > 0, "monotonic, got a step of %d", min_step);
	assert(max_step <= 60, "no step dominates the fringe: max=%d", max_step);
}

// With half_blocks on, a blank fringe cell becomes a ▀ carrying one colour above
// and another below, so the vertical gradient gets twice as many steps.
fn void test_half_block_shadow_doubles_vertical_resolution() @test {
	Fixed* f = fixed(8, 2);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(8)).height(xray::cells(2)).at(2, 2)
			.shadow(xray::shadow(1, 1, 200, 3, half_blocks: true).with_color(xray::color_rgb(0, 0, 0))));
	r.solve(xray::new_rect(0, 0, 20, 14));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 14);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	for (sz y = 0; y < 14; y++) {
		for (sz x = 0; x < 20; x++) sb.cell_at(x, y).style.bg = xray::color_rgb(200, 200, 200);
	}
	sb.paint(r);

	int splits   =  0;
	int prev     = -1;
	int max_step =  0;
	for (sz y = 4; y <= 9; y++) {
		xray::Cell* c = sb.cell_at(6, y);
		bool split    = c.content_str() == "▀";
		if (split) splits++;
		int[2] halves = { split ? (int)c.style.fg.r : (int)c.style.bg.r, (int)c.style.bg.r };
		for (int k = 0; k < 2; k++) {
			if (prev >= 0 && halves[k] - prev > max_step) max_step = halves[k] - prev;
			prev = halves[k];
		}
	}

	assert(splits > 0, "the fringe uses half blocks, got %d split cells", splits);
	// About half the step size of the whole-cell fringe.
	assert(max_step <= 25, "half-block steps are smaller: max=%d", max_step);
}

// A shadow leaves glyphs alone unless half_blocks asks for them. A space
// painted by content looks exactly like a blank cell, so claiming blanks is
// only safe where the caller knows what is underneath.
fn void test_shadow_leaves_glyphs_alone_by_default() @test {
	Fixed* f = fixed(8, 2);
	xray::Node* r = xray::root()
		.add(xray::content_node(f).width(xray::cells(8)).height(xray::cells(2)).at(2, 2)
			.shadow(xray::shadow(1, 1, 200, 3).with_color(xray::color_rgb(0, 0, 0))));
	r.solve(xray::new_rect(0, 0, 20, 14));

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 14);
	defer {
		sb.destroy();
		mem::free(sb);
	}
	for (sz y = 0; y < 14; y++) {
		for (sz x = 0; x < 20; x++) sb.cell_at(x, y).style.bg = xray::color_rgb(200, 200, 200);
	}
	sb.render_ansi_string(2, 5, "AB CD", xray::default_style());
	sb.paint(r);

	DString got = dstring::temp();
	for (sz x = 2; x < 7; x++) got.append_string(sb.cell_at(x, 5).content_str());
	assert(got.str_view() == "AB CD", "text survives the shadow, got '%s'", got.str_view());
}