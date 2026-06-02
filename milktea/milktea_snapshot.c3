module milktea_snapshot;

import snapshot;
import milktea;
import glaze;
import xray;

const String SNAP = "milktea";

fn String render_layout(String layout_str) {
	// LayoutNode output is already a flat ANSI string — return as-is.
	return layout_str;
}

fn void test_snap_vstack_basic() @test {
	xray::Rect area = xray::new_rect(0, 0, 40, 10);

	milktea::LayoutNode[2] nodes = {
		{
			xray::constraint_len(3),
			glaze::new_style().foreground(glaze::color_hex("#00ffcc")).set_bold(true),
			"Header",
		},
		{
			xray::constraint_fill(1),
			glaze::new_style().foreground(glaze::color_hex("#aaaaaa")),
			"Body content goes here",
		},
	};

	String out = milktea::vstack(area, nodes[..]);
	snapshot::assert_snapshot(SNAP, "vstack_basic", out);
}

fn void test_snap_hstack_basic() @test {
	xray::Rect area = xray::new_rect(0, 0, 60, 3);

	milktea::LayoutNode[2] nodes = {
		{
			xray::constraint_len(20),
			glaze::new_style().foreground(glaze::color_hex("#ff5fd7")),
			"Left",
		},
		{
			xray::constraint_fill(1),
			glaze::new_style().foreground(glaze::color_hex("#5fafd7")),
			"Right fills remaining",
		},
	};

	String out = milktea::hstack(area, nodes[..]);
	snapshot::assert_snapshot(SNAP, "hstack_basic", out);
}

fn void test_snap_vstack_with_border() @test {
	xray::Rect area = xray::new_rect(0, 0, 40, 12);

	milktea::LayoutNode[3] nodes = {
		{
			xray::constraint_len(1),
			glaze::new_style().foreground(glaze::color_hex("#00ffcc")).set_bold(true).set_width(40),
			"Title",
		},
		{
			xray::constraint_fill(1),
			glaze::new_style()
				.foreground(glaze::color_hex("#aaaaaa"))
				.set_border(glaze::rounded_border())
				.padding(1, 1, 1, 1),
			"Bordered content area",
		},
		{
			xray::constraint_len(1),
			glaze::new_style().foreground(glaze::color_hex("#555555")).set_width(40),
			"Status bar",
		},
	};

	String out = milktea::vstack(area, nodes[..]);
	snapshot::assert_snapshot(SNAP, "vstack_with_border", out);
}

fn void test_snap_hstack_three_cols() @test {
	xray::Rect area = xray::new_rect(0, 0, 60, 3);

	milktea::LayoutNode[3] nodes = {
		{
			xray::constraint_len(15),
			glaze::new_style().foreground(glaze::color_hex("#ff5fd7")),
			"Sidebar",
		},
		{
			xray::constraint_fill(2),
			glaze::new_style().foreground(glaze::color_hex("#5fd7ff")),
			"Main",
		},
		{
			xray::constraint_fill(1),
			glaze::new_style().foreground(glaze::color_hex("#d7ff5f")),
			"Side",
		},
	};

	String out = milktea::hstack(area, nodes[..]);
	snapshot::assert_snapshot(SNAP, "hstack_three_cols", out);
}
