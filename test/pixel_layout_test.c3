module pixel_layout_test;

import xray;
import milktea;
import glaze;
import std::core::mem;
import std::collections::list;

const xray::LayoutMetrics PIXELS = { .pixels = true, .cell_w = 10, .cell_h = 20 };

fn void test_pixel_padding_sizes_fixed_bar_and_fill_sibling() @test {
	xray::Node* body = xray::vstack();
	xray::Node* text = milktea::text({}, "bar").height(xray::cells(1));
	xray::Node* bar = xray::vstack().height(xray::cells(1))
		.decorate(xray::solid(xray::color_rgb(255, 0, 0)).padding(4, 4, 4, 4)).add(text);
	xray::Node* root = xray::vstack().add(body).add(bar);
	root.solve({ .w = 203, .h = 107 }, PIXELS);
	expect_rect(body.rect(), xray::new_rect(0, 0, 203, 79));
	expect_rect(bar.rect(), xray::new_rect(0, 79, 203, 28));
	expect_rect(text.rect(), xray::new_rect(4, 83, 195, 20));
	expect_rect(text.content_cell_rect(), xray::new_rect(0, 4, 19, 1));
	root.solve({ .w = 20, .h = 5 });
	expect_rect(body.rect(), xray::new_rect(0, 0, 20, 4));
	expect_rect(bar.rect(), xray::new_rect(0, 4, 20, 1));
	expect_rect(text.rect(), bar.rect());
}

fn void test_pixel_fit_asymmetric_nested_padding_and_font_metrics() @test {
	xray::Node* leaf = milktea::text({}, "abc").fit_width().fit_height()
		.decorate(xray::solid(xray::color_rgb(255, 0, 0)).padding(1, 2, 3, 4));
	xray::Node* box = xray::vstack().fit_width().fit_height().add(leaf)
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(5, 6, 7, 8));
	xray::Node* root = xray::root().add(box);
	root.solve({ .w = 200, .h = 200 }, PIXELS);
	expect_rect(box.rect(), xray::new_rect(0, 0, 50, 36));
	expect_rect(leaf.rect(), xray::new_rect(8, 5, 36, 24));
	expect_rect(leaf.content_layout_rect(), xray::new_rect(12, 6, 30, 20));
	root.solve({ .w = 200, .h = 200 }, { .pixels = true, .cell_w = 7, .cell_h = 13 });
	assert(box.rect().w == 41 && box.rect().h == 29);
	expect_rect(leaf.content_layout_rect(), xray::new_rect(12, 6, 21, 13));
}

fn void test_pixel_percentage_fill_gap_and_pinned_offsets() @test {
	xray::Node* a = xray::vstack().width(xray::percent(50));
	xray::Node* b = xray::vstack();
	xray::Node* row = xray::hstack().with_gap(1).add(a).add(b);
	row.solve({ .w = 213, .h = 47 }, PIXELS);
	assert(a.rect().w + b.rect().w + 10 == 213);
	assert(b.rect().x == a.rect().w + 10);
	assert(a.rect().h == 47 && b.rect().h == 47);
	xray::Node* pinned = xray::vstack().at(2, 3).width(xray::cells(2)).height(xray::cells(1));
	xray::Node* root = xray::root().add(pinned);
	root.solve({ .w = 200, .h = 200 }, PIXELS);
	expect_rect(pinned.rect(), xray::new_rect(20, 60, 20, 20));
}

fn void test_pixel_bounded_fit_and_wrapping() @test {
	xray::Node* text = milktea::text({}, "abcdefghij").max_width(4).fit_height()
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(3, 4, 5, 6));
	xray::Node* root = xray::root().add(text);
	root.solve({ .w = 200, .h = 200 }, PIXELS);
	assert(text.rect().w == 50);
	assert(text.rect().h == 68);
	assert(text.content_cell_rect().w == 4 && text.content_cell_rect().h == 3);
}

struct Hit { sz count, col, row, entered, left; }
fn void clicked(void* ctx, String id, sz col, sz row) {
	Hit* h = (Hit*)ctx;
	h.count++;
	h.col = col;
	h.row = row;
}
fn void entered(void* ctx, String id, sz col, sz row) { ((Hit*)ctx).entered++; }
fn void left(void* ctx, String id, sz col, sz row) { ((Hit*)ctx).left++; }

fn void test_pixel_hit_boundaries_and_content_local_cells() @test {
	Hit hit;
	xray::Node* child = milktea::text({}, "abc").width(xray::cells(3)).height(xray::cells(1))
		.id_with(&hit).on_click(&clicked).on_hover_in(&entered).on_hover_out(&left);
	xray::Node* root = xray::root().decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(3, 2, 1, 4)).add(child);
	root.solve({ .w = 200, .h = 100 }, PIXELS);
	List{xray::ClickTarget} list;
	list.tinit();
	xray::collect_click_targets(root, &list);
	xray::ClickTarget[] targets = list.array_view();
	sz count = (sz)targets.len;
	assert(count == 1);
	xray::dispatch_click(targets[:count], 3, 3, false);
	assert(hit.count == 0);
	xray::dispatch_click(targets[:count], 4, 3, false);
	assert(hit.count == 1 && hit.col == 0 && hit.row == 0);
	xray::dispatch_click(targets[:count], 13, 22, false);
	assert(hit.count == 2 && hit.col == 0 && hit.row == 0);
	xray::dispatch_click(targets[:count], 14, 3, false);
	assert(hit.count == 3 && hit.col == 1);
	xray::dispatch_click(targets[:count], 34, 3, false);
	xray::dispatch_click(targets[:count], 4, 23, false);
	assert(hit.count == 3);
	xray::dispatch_hover(targets[:count], 4, 3, {}, 0, 3, 3, false);
	xray::dispatch_hover(targets[:count], 3, 3, {}, 0, 4, 3, false);
	assert(hit.entered == 1 && hit.left == 1);
	child.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(1, 2, 3, 4));
	root.solve({ .w = 200, .h = 100 }, PIXELS);
	list.clear();
	xray::collect_click_targets(root, &list);
	targets = list.array_view();
	count = (sz)targets.len;
	xray::dispatch_click(targets[:count], 17, 4, false);
	assert(hit.col == 0 && hit.row == 0);
	xray::dispatch_click(targets[:count], 18, 4, false);
	assert(hit.col == 1);
}

struct CursorText (xray::Content) { bool unused; }
fn String CursorText.render(&self, xray::Rect r) @dynamic => "ab";
fn xray::ContentCursor CursorText.cursor(&self, xray::Rect r) @dynamic {
	return xray::place_cursor(r, 1, 0, { .draw = &draw_cursor });
}
fn String draw_cursor(sz x, sz y, bool blink, String under) => "_";

fn void test_pixel_paint_and_cursor_origins_are_not_cell_snapped() @test {
	CursorText content;
	xray::Node* child = xray::content_node(&content).width(xray::cells(2)).height(xray::cells(1));
	xray::Node* root = xray::root()
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(3, 2, 1, 4)).add(child);
	root.solve({ .w = 103, .h = 61 }, PIXELS);
	xray::ScreenBuffer* buf = xray::new_screen_buffer(11, 4);
	defer { buf.destroy(); mem::free(buf); }
	buf.record_paint = true;
	buf.paint(root);
	xray::PaintOp[] ops = buf.paint_ops.array_view();
	assert(ops.len == 4);
	assert(ops[0].decoration.pixel_rect && ops[0].decoration.rect.w == 103);
	assert(ops[1].pixels && ops[1].col == 4 && ops[1].row == 3);
	assert(ops[2].col == 14 && ops[2].row == 3);
	assert(ops[3].col == 14 && ops[3].row == 3 && ops[3].cell.content[0] == '_');
}

fn void test_pixel_padding_does_not_change_terminal_cells() @test {
	xray::Node* plain = milktea::text({}, "hello").fit_width().fit_height();
	xray::Node* decorated = milktea::text({}, "hello").fit_width().fit_height()
		.decorate(xray::solid(xray::color_rgb(255, 0, 0)).padding(7, 3, 5, 1));
	xray::Node* a = xray::root().add(plain);
	xray::Node* b = xray::root().add(decorated);
	a.solve({ .w = 10, .h = 5 });
	b.solve({ .w = 10, .h = 5 });
	expect_rect(plain.rect(), decorated.rect());
	xray::ScreenBuffer* ba = xray::new_screen_buffer(10, 5);
	xray::ScreenBuffer* bb = xray::new_screen_buffer(10, 5);
	defer { ba.destroy(); bb.destroy(); mem::free(ba); mem::free(bb); }
	ba.paint(a);
	bb.paint(b);
	for (sz i = 0; i < 50; i++) assert(ba.cells[i].eq(bb.cells[i]));
}

fn void expect_rect(xray::Rect actual, xray::Rect expected) {
	assert(actual.x == expected.x && actual.y == expected.y
		&& actual.w == expected.w && actual.h == expected.h);
}

fn sz custom_height(void* ctx, sz width) {
	*(sz*)ctx = width;
	return 2;
}

fn void test_pixel_custom_fit_retains_cell_units() @test {
	sz measured_width = -1;
	xray::Node* child = xray::vstack()
		.height(xray::fit(&custom_height, &measured_width))
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(3, 4, 5, 6));
	xray::Node* root = xray::root().add(child);
	root.solve({ .w = 129, .h = 200 }, PIXELS);
	assert(measured_width == 11);
	assert(child.rect().h == 48);
	child.height(xray::fit(null, null));
	root.solve({ .w = 129, .h = 200 }, PIXELS);
	assert(child.rect().h == 200);
}

fn void test_pixel_partial_cell_background_reaches_box_edge() @test {
	xray::Node* root = milktea::text({ .bg = glaze::color_hex("#204060") }, "");
	root.solve({ .w = 23, .h = 47 }, PIXELS);
	xray::ScreenBuffer* buf = xray::new_screen_buffer(3, 3);
	defer { buf.destroy(); mem::free(buf); }
	buf.record_paint = true;
	buf.paint(root);
	xray::PaintOp[] ops = buf.paint_ops.array_view();
	assert(ops.len == 4);
	assert(ops[3].col == 10 && ops[3].row == 20);
	assert(ops[3].bg_w == 13 && ops[3].bg_h == 27);
}

fn void test_pixel_tiny_padded_box_has_no_text_or_negative_extent() @test {
	xray::Node* leaf = milktea::text({}, "abc")
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(4, 4, 4, 4));
	xray::Node* root = xray::root().add(leaf);
	root.solve({ .w = 3, .h = 2 }, PIXELS);
	assert(leaf.content_cell_rect().w == 0 && leaf.content_cell_rect().h == 0);
	xray::ScreenBuffer* buf = xray::new_screen_buffer(1, 1);
	defer { buf.destroy(); mem::free(buf); }
	buf.record_paint = true;
	buf.paint(root);
	assert(buf.paint_ops.len() == 1);
}

fn void test_pixel_overlap_does_not_repaint_wide_neighbour_at_wrong_origin() @test {
	xray::Node* root = xray::root()
		.add(milktea::text({}, "界").width(xray::cells(2)).height(xray::cells(1)))
		.add(milktea::text({}, "B").at(1, 0).width(xray::cells(1)).height(xray::cells(1))
			.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(0, 0, 0, 4)));
	root.solve({ .w = 100, .h = 40 }, PIXELS);
	xray::ScreenBuffer* buf = xray::new_screen_buffer(10, 2);
	defer { buf.destroy(); mem::free(buf); }
	buf.record_paint = true;
	buf.paint(root);
	bool found;
	foreach (op : buf.paint_ops.array_view()) {
		if (op.kind != xray::PaintKind.CELL) continue;
		assert(op.col != 4);
		if (op.cell.content_len > 0 && op.cell.content[0] == 'B') {
			assert(op.col == 14);
			found = true;
		}
	}
	assert(found);
}

fn void test_pixel_partial_offscreen_cell_is_recorded_for_framebuffer_clipping() @test {
	xray::Node* root = xray::root()
		.decorate(xray::solid(xray::color_rgb(0, 0, 0)).padding(3, 0, 0, 4))
		.add(milktea::text({}, "ab").at(-1, -1).width(xray::cells(2)).height(xray::cells(1)));
	root.solve({ .w = 100, .h = 40 }, PIXELS);
	xray::ScreenBuffer* buf = xray::new_screen_buffer(10, 2);
	defer { buf.destroy(); mem::free(buf); }
	buf.record_paint = true;
	buf.paint(root);
	xray::PaintOp[] ops = buf.paint_ops.array_view();
	assert(ops.len == 3);
	assert(ops[1].col == -6 && ops[1].row == -17);
	assert(ops[2].col == 4 && ops[2].row == -17);
}

fn void test_pixel_fixed_size_does_not_scale_with_font() @test {
	xray::Node* circle = xray::vstack().width(xray::pixels(14, 2))
		.height(xray::pixels(14, 1)).center();
	xray::Node* root = xray::root().add(circle);
	root.solve({ .w = 40, .h = 30 }, PIXELS);
	expect_rect(circle.rect(), xray::new_rect(13, 8, 14, 14));
	root.solve({ .w = 40, .h = 30 }, { .pixels = true, .cell_w = 5, .cell_h = 11 });
	expect_rect(circle.rect(), xray::new_rect(13, 8, 14, 14));
	root.solve({ .w = 4, .h = 3 });
	expect_rect(circle.rect(), xray::new_rect(1, 1, 2, 1));
}

// A blocking node stops a click from reaching what is beneath it, and while
// the pointer is over it the covered nodes are not hovered: moving onto a
// modal reads as leaving the list behind it.
fn void test_block_pointer_covers_what_is_beneath() @test {
	Hit hit;
	xray::Node* under = milktea::text({}, "row").width(xray::cells(10)).height(xray::cells(1))
		.id_with(&hit).on_click(&clicked).on_hover_in(&entered).on_hover_out(&left);
	xray::Node* modal = xray::root().width(xray::cells(5)).height(xray::cells(5)).at(0, 0).block_pointer();
	xray::Node* root = xray::root().add(under).add(modal);
	root.solve(xray::new_rect(0, 0, 20, 10));

	List{xray::ClickTarget} list;
	list.tinit();
	xray::collect_click_targets(root, &list);
	xray::ClickTarget[] targets = list.array_view();

	// Under the modal: no click, no hover.
	xray::dispatch_click(targets, 2, 0, false);
	assert(hit.count == 0, "the click stops at the modal");
	xray::dispatch_hover(targets, 2, 0, {}, 0, 15, 5, false);
	assert(hit.entered == 0, "no hover under the modal");

	// Beside it, the row behaves as before.
	xray::dispatch_click(targets, 7, 0, false);
	assert(hit.count == 1, "the row still takes clicks outside the modal");
	xray::dispatch_hover(targets, 7, 0, {}, 0, 2, 0, false);
	assert(hit.entered == 1, "moving off the modal onto the row hovers it");
	xray::dispatch_hover(targets, 2, 0, {}, 0, 7, 0, false);
	assert(hit.left == 1, "moving onto the modal leaves the row");
}
