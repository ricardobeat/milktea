module xray_snapshot;

import snapshot;
import xray;

const String SNAP = "xray";

// ============================================================
// Layout — constraint basics
// ============================================================

fn void test_snap_layout_h_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 40, .h = 1 };
	xray::Constraint[2] cs = { xray::constraint_fill(1), xray::constraint_fill(1) };
	xray::Rect[2] out;
	xray::layout_h(area, cs[..], out[..]);

	// Render the two halves as bordered boxes
	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 3);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(2));
	xray::Style bdr_sty = xray::default_style().set_fg(xray::color_ansi(6));

	xray::Rect left_box = { .x = 0, .y = 0, .w = out[0].w, .h = 3 };
	xray::Rect right_box = { .x = out[1].x, .y = 0, .w = out[1].w, .h = 3 };
	xray::Border b = xray::rounded_border();
	Rect li = sb.draw_border(left_box, b, bdr_sty);
	Rect ri = sb.draw_border(right_box, b, bdr_sty);
	sb.set_string(li.x, li.y, "L", sty);
	sb.set_string(ri.x, ri.y, "R", sty);

	snapshot::assert_snapshot(SNAP, "layout_h_fill", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_v_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 20, .h = 6 };
	xray::Constraint[2] cs = { xray::constraint_fill(1), xray::constraint_fill(1) };
	xray::Rect[2] out;
	xray::layout_v(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 6);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(3));
	xray::Style bdr_sty = xray::default_style().set_fg(xray::color_ansi(6));
	xray::Border b = xray::rounded_border();

	Rect tbi = sb.draw_border(out[0], b, bdr_sty);
	Rect bbi = sb.draw_border(out[1], b, bdr_sty);
	sb.set_string(tbi.x, tbi.y, "top", sty);
	sb.set_string(bbi.x, bbi.y, "bot", sty);

	snapshot::assert_snapshot(SNAP, "layout_v_fill", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_len_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 30, .h = 1 };
	xray::Constraint[2] cs = { xray::constraint_len(10), xray::constraint_fill(1) };
	xray::Rect[2] out;
	xray::layout_h(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 1);
	sb.clear();
	xray::Style s1 = xray::default_style().set_fg(xray::color_ansi(2)).set_bg(xray::color_ansi(0));
	xray::Style s2 = xray::default_style().set_fg(xray::color_ansi(7)).set_bg(xray::color_ansi(4));
	sb.set_string(out[0].x, 0, "fixed-10", s1);
	sb.set_string(out[1].x, 0, "fill-rest", s2);

	snapshot::assert_snapshot(SNAP, "layout_h_len_fill", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_three_cols() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 36, .h = 1 };
	xray::Constraint[3] cs = { xray::constraint_len(8), xray::constraint_fill(1), xray::constraint_len(8) };
	xray::Rect[3] out;
	xray::layout_h(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(36, 1);
	sb.clear();
	xray::Style sa = xray::default_style().set_fg(xray::color_ansi(1));
	xray::Style sb_sty = xray::default_style().set_fg(xray::color_ansi(2));
	xray::Style sc = xray::default_style().set_fg(xray::color_ansi(4));
	sb.set_string(out[0].x, 0, "left", sa);
	sb.set_string(out[1].x, 0, "center", sb_sty);
	sb.set_string(out[2].x, 0, "right", sc);

	snapshot::assert_snapshot(SNAP, "layout_h_three_cols", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_v_three_rows() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 20, .h = 9 };
	xray::Constraint[3] cs = { xray::constraint_len(2), xray::constraint_fill(1), xray::constraint_len(2) };
	xray::Rect[3] out;
	xray::layout_v(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 9);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(7));
	sb.set_string(0, out[0].y, "hdr", sty);
	sb.set_string(0, out[1].y, "body", sty);
	sb.set_string(0, out[2].y, "ftr", sty);

	snapshot::assert_snapshot(SNAP, "layout_v_three_rows", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// Layout — percent, min, max constraints
// ============================================================

fn void test_snap_layout_h_percent() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 40, .h = 1 };
	xray::Constraint[2] cs = { xray::constraint_percent(25), xray::constraint_fill(1) };
	xray::Rect[2] out;
	xray::layout_h(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 1);
	sb.clear();
	xray::Style s1 = xray::default_style().set_fg(xray::color_ansi(5));
	xray::Style s2 = xray::default_style().set_fg(xray::color_ansi(6));
	sb.set_string(out[0].x, 0, "25pct", s1);
	sb.set_string(out[1].x, 0, "fill", s2);

	snapshot::assert_snapshot(SNAP, "layout_h_percent", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_gap() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 30, .h = 1 };
	xray::Constraint[3] cs = { xray::constraint_fill(1), xray::constraint_fill(1), xray::constraint_fill(1) };
	xray::Rect[3] out;
	xray::layout_h_gap(area, cs[..], 2, out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 1);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(2));
	sb.set_string(out[0].x, 0, "A", sty);
	sb.set_string(out[1].x, 0, "B", sty);
	sb.set_string(out[2].x, 0, "C", sty);

	snapshot::assert_snapshot(SNAP, "layout_h_gap", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// ScreenBuffer — text rendering
// ============================================================

fn void test_snap_screen_plain_text() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 3);
	sb.clear();
	xray::Style sty = xray::default_style();
	sb.set_string(0, 0, "hello world", sty);
	sb.set_string(0, 1, "second line", sty);
	sb.set_string(0, 2, "third", sty);

	snapshot::assert_snapshot(SNAP, "screen_plain_text", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_screen_styled_text() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(24, 1);
	sb.clear();
	xray::Style red = xray::default_style().set_fg(xray::color_ansi(1)).set_bold(true);
	xray::Style grn = xray::default_style().set_fg(xray::color_ansi(2));
	sb.set_string(0, 0, "RED", red);
	sb.set_string(4, 0, "green", grn);

	snapshot::assert_snapshot(SNAP, "screen_styled_text", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_screen_truecolor() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 1);
	sb.clear();
	xray::Style s1 = xray::default_style().set_fg(xray::color_hex("#ff5fd7"));
	xray::Style s2 = xray::default_style().set_bg(xray::color_hex("#005f87")).set_fg(xray::color_hex("#ffffff"));
	sb.set_string(0, 0, "pink", s1);
	sb.set_string(5, 0, "blue", s2);

	snapshot::assert_snapshot(SNAP, "screen_truecolor", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// ScreenBuffer — bordered regions
// ============================================================

fn void test_snap_screen_bordered() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 5);
	sb.clear();
	xray::Rect box = { .x = 0, .y = 0, .w = 20, .h = 5 };
	xray::Style bdr_sty = xray::default_style().set_fg(xray::color_ansi(6));
	xray::Border b = xray::rounded_border();
	Rect inner = sb.draw_border(box, b, bdr_sty);
	xray::Style txt = xray::default_style().set_fg(xray::color_ansi(7));
	sb.set_string(inner.x, inner.y, "inside", txt);

	snapshot::assert_snapshot(SNAP, "screen_bordered", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_screen_two_bordered() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 5);
	sb.clear();
	xray::Style bdr_sty = xray::default_style().set_fg(xray::color_ansi(5));
	xray::Style txt = xray::default_style().set_fg(xray::color_ansi(7));
	xray::Border b = xray::rounded_border();

	xray::Rect left = { .x = 0, .y = 0, .w = 20, .h = 5 };
	xray::Rect right = { .x = 20, .y = 0, .w = 20, .h = 5 };
	Rect li = sb.draw_border(left, b, bdr_sty);
	Rect ri = sb.draw_border(right, b, bdr_sty);
	sb.set_string(li.x, li.y, "left", txt);
	sb.set_string(ri.x, ri.y, "right", txt);

	snapshot::assert_snapshot(SNAP, "screen_two_bordered", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// ScreenBuffer — combined layout + render
// ============================================================

fn void test_snap_screen_layout_render() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 7);
	sb.clear();

	// Header + body layout
	xray::Rect screen = { .x = 0, .y = 0, .w = 40, .h = 7 };
	xray::Constraint[2] cs = { xray::constraint_len(3), xray::constraint_fill(1) };
	xray::Rect[2] zones;
	xray::layout_v(screen, cs[..], zones[..]);

	xray::Style hdr_sty = xray::default_style().set_fg(xray::color_hex("#ffffff")).set_bg(xray::color_hex("#005f87")).set_bold(true);
	xray::Style bdr_sty = xray::default_style().set_fg(xray::color_ansi(6));
	xray::Style txt_sty = xray::default_style().set_fg(xray::color_ansi(7));
	xray::Border b = xray::rounded_border();

	// Header: fill with bg color
	String hdr_text = "  My Application";
	sb.set_string(0, zones[0].y, hdr_text, hdr_sty);

	// Body: bordered box with content
	Rect inner = sb.draw_border(zones[1], b, bdr_sty);
	sb.set_string(inner.x, inner.y, "content here", txt_sty);

	snapshot::assert_snapshot(SNAP, "screen_layout_render", sb.render_diff_str());
	sb.destroy();
	mem::free(sb);
}
