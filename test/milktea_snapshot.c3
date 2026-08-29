module milktea_snapshot;

import snapshot;
import milktea;
import glaze;
import xray;
import xray::layout;

const String SNAP = "milktea";

fn void test_snap_vstack_basic() @test {
	xray::Rect area = xray::new_rect(0, 0, 40, 10);

	xray::Rect r0, r1;
	layout::vstack(area, {
		layout::slot(layout::cells(3),    &r0),
		layout::slot(layout::fill(1),   &r1),
	});

	glaze::Style header_s = glaze::new_style().foreground(glaze::color_hex("#00ffcc")).set_bold(true);
	glaze::Style body_s   = glaze::new_style().foreground(glaze::color_hex("#aaaaaa"));
	String v0 = r0.render(header_s, "Header");
	String v1 = r1.render(body_s,   "Body content goes here");

	String out = glaze::join_vertical(glaze::Position.LEFT, v0, v1);
	snapshot::assert_snapshot(SNAP, "vstack_basic", out);
}

fn void test_snap_hstack_basic() @test {
	xray::Rect area = xray::new_rect(0, 0, 60, 3);

	xray::Rect r0, r1;
	layout::hstack(area, {
		layout::slot(layout::cells(20),   &r0),
		layout::slot(layout::fill(1),   &r1),
	});

	glaze::Style left_s  = glaze::new_style().foreground(glaze::color_hex("#ff5fd7"));
	glaze::Style right_s = glaze::new_style().foreground(glaze::color_hex("#5fafd7"));
	String v0 = r0.render(left_s,  "Left");
	String v1 = r1.render(right_s, "Right fills remaining");

	String out = glaze::join_horizontal(v0, v1, 0);
	snapshot::assert_snapshot(SNAP, "hstack_basic", out);
}

fn void test_snap_vstack_with_border() @test {
	xray::Rect area = xray::new_rect(0, 0, 40, 12);

	xray::Rect r0, r1, r2;
	layout::vstack(area, {
		layout::slot(layout::cells(1),    &r0),
		layout::slot(layout::fill(1),   &r1),
		layout::slot(layout::cells(1),    &r2),
	});

	glaze::Style title_s  = glaze::new_style().foreground(glaze::color_hex("#00ffcc")).set_bold(true);
	glaze::Style body_s   = glaze::new_style().foreground(glaze::color_hex("#aaaaaa"))
		.set_border(glaze::rounded_border()).padding(1, 1, 1, 1);
	glaze::Style status_s = glaze::new_style().foreground(glaze::color_hex("#555555"));
	String v0 = r0.render(title_s,  "Title");
	String v1 = r1.render(body_s,   "Bordered content area");
	String v2 = r2.render(status_s, "Status bar");

	String out = glaze::join_vertical(glaze::Position.LEFT, v0, v1);
	out = glaze::join_vertical(glaze::Position.LEFT, out, v2);
	snapshot::assert_snapshot(SNAP, "vstack_with_border", out);
}

fn void test_snap_hstack_three_cols() @test {
	xray::Rect area = xray::new_rect(0, 0, 60, 3);

	xray::Rect r0, r1, r2;
	layout::hstack(area, {
		layout::slot(layout::cells(15),   &r0),
		layout::slot(layout::fill(2),   &r1),
		layout::slot(layout::fill(1),   &r2),
	});

	glaze::Style sidebar_s = glaze::new_style().foreground(glaze::color_hex("#ff5fd7"));
	glaze::Style main_s    = glaze::new_style().foreground(glaze::color_hex("#5fd7ff"));
	glaze::Style side_s    = glaze::new_style().foreground(glaze::color_hex("#d7ff5f"));
	String v0 = r0.render(sidebar_s, "Sidebar");
	String v1 = r1.render(main_s,    "Main");
	String v2 = r2.render(side_s,    "Side");

	String out = glaze::join_horizontal(v0, v1, 0);
	out = glaze::join_horizontal(out, v2, 0);
	snapshot::assert_snapshot(SNAP, "hstack_three_cols", out);
}

