module paint_stream_test;

import xray;
import std::core::mem;

struct Text (xray::Content) { String value; }
fn String Text.render(&self, xray::Rect r) @dynamic => self.value;

fn void test_paint_stream_preserves_parent_child_sibling_order() @test {
	Text parent = { "\e[41mP\e[0m" };
	Text child = { "\e[44mC\e[0m" };
	Text popup = { "\e[42mZ\e[0m" };
	xray::Node* panel = xray::content_node(&parent)
		.decorate(xray::solid(xray::color_rgb(255, 0, 0)).round(3.0f))
		.add(xray::content_node(&child).at(0, 0).width(xray::cells(1)).height(xray::cells(1)));
	xray::Node* root = xray::root().add(panel)
		.add(xray::content_node(&popup).at(0, 0).width(xray::cells(1)).height(xray::cells(1)));
	root.solve(xray::new_rect(0, 0, 4, 2));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(4, 2);
	defer { sb.destroy(); mem::free(sb); }
	sb.record_paint = true;
	sb.paint(root);
	xray::PaintOp[] ops = sb.paint_ops.array_view();
	assert(ops.len == 4);
	assert(ops[0].kind == xray::PaintKind.DECORATION);
	assert(ops[1].cell.content[0] == 'P');
	assert(ops[1].cell.style.bg.kind == xray::ColorKind.TRANSPARENT);
	assert(ops[2].cell.content[0] == 'C');
	assert(ops[2].cell.style.bg.kind != xray::ColorKind.TRANSPARENT);
	assert(ops[3].cell.content[0] == 'Z');
	assert(sb.cells[0].content[0] == 'Z');
}

fn void test_paint_stream_records_equal_overwrites_and_clips_to_screen() @test {
	Text same = { "\e[41mXX\e[0m" };
	xray::Node* root = xray::root()
		.add(xray::content_node(&same).at(-1, 0).width(xray::cells(2)).height(xray::cells(1)))
		.add(xray::content_node(&same).at(-1, 0).width(xray::cells(2)).height(xray::cells(1)));
	root.solve(xray::new_rect(0, 0, 4, 2));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(4, 2);
	defer { sb.destroy(); mem::free(sb); }
	sb.record_paint = true;
	sb.paint(root);
	xray::PaintOp[] ops = sb.paint_ops.array_view();
	assert(ops.len == 2, "equal writes must still cover earlier decorations");
	foreach (op : ops) {
		assert(op.col == 0 && op.row == 0);
		assert(op.cell.content[0] == 'X');
	}
	sb.paint(root);
	assert(sb.paint_ops.len() == 2, "commands reset each frame");
}

fn void test_paint_stream_does_not_change_terminal_cells() @test {
	Text text = { "\e[41mTest\e[0m" };
	xray::Node* root = xray::content_node(&text)
		.decorate(xray::linear(xray::color_rgb(0, 0, 0), xray::color_rgb(255, 255, 255)));
	root.solve(xray::new_rect(0, 0, 4, 2));
	xray::ScreenBuffer* terminal = xray::new_screen_buffer(4, 2);
	xray::ScreenBuffer* gui = xray::new_screen_buffer(4, 2);
	defer { terminal.destroy(); mem::free(terminal); gui.destroy(); mem::free(gui); }
	gui.record_paint = true;
	terminal.paint(root);
	gui.paint(root);
	assert(!terminal.paint_ops.is_initialized());
	foreach (i, cell : terminal.cells) assert(cell.eq(gui.cells[i]));
}

fn void test_shadow_stream_follows_tree_order() @test {
	Text text = { "\e[41mX\e[0m" };
	xray::Node* root = xray::content_node(&text)
		.at(1, 1).width(xray::cells(1)).height(xray::cells(1))
		.shadow(xray::shadow(1, 0))
		.decorate(xray::solid(xray::color_rgb(255, 0, 0)));
	root = xray::root().add(root);
	root.solve(xray::new_rect(0, 0, 4, 3));
	xray::ScreenBuffer* sb = xray::new_screen_buffer(4, 3);
	defer { sb.destroy(); mem::free(sb); }
	sb.record_paint = true;
	sb.paint(root);
	xray::PaintOp[] ops = sb.paint_ops.array_view();
	assert(ops.len == 3);
	assert(ops[0].kind == xray::PaintKind.TINT);
	assert(ops[1].kind == xray::PaintKind.DECORATION);
	assert(ops[2].kind == xray::PaintKind.CELL);
}
