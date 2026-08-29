module xray_snapshot;

import snapshot;
import xray;

const String SNAP = "xray";

// Render each row of the screen buffer as a newline-separated string.
// Unlike render_diff_str(), this produces inline output with no cursor
// positioning — safe for snapshot preview.
fn String render_rows(xray::ScreenBuffer* sb) @local {
	DString out = dstring::temp();
	xray::Style pen = xray::default_style();
	for (int row = 0; row < sb.height; row++) {
		for (int col = 0; col < sb.width; col++) {
			Cell* c = sb.cell_at(col, row);
			String sgr = c.style.diff_sgr(pen);
			if (sgr.len > 0) {
				out.append_string(sgr);
				pen = c.style;
			}
			out.append_string(c.content_str());
		}
		if (row < sb.height - 1) out.append_char('\n');
	}
	if (!pen.is_empty()) out.append_string("\x1b[0m");
	return out.str_view();
}

// ============================================================
// Layout — constraint basics
// ============================================================

fn void test_snap_layout_h_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 40, .h = 1 };
	xray::Constraint[2] cs = { xray::fill(1), xray::fill(1) };
	xray::Rect[2] out;
	xray::layout_h_gap(area, cs[..], 1, out[..]);

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

	snapshot::assert_snapshot(SNAP, "layout_h_fill", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_v_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 20, .h = 6 };
	xray::Constraint[2] cs = { xray::fill(1), xray::fill(1) };
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

	snapshot::assert_snapshot(SNAP, "layout_v_fill", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_len_fill() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 30, .h = 1 };
	xray::Constraint[2] cs = { xray::cells(10), xray::fill(1) };
	xray::Rect[2] out;
	xray::layout_h(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 1);
	sb.clear();
	xray::Style s1 = xray::default_style().set_fg(xray::color_ansi(2)).set_bg(xray::color_ansi(0));
	xray::Style s2 = xray::default_style().set_fg(xray::color_ansi(7)).set_bg(xray::color_ansi(4));
	sb.set_string(out[0].x, 0, "fixed-10", s1);
	sb.set_string(out[1].x, 0, "fill-rest", s2);

	snapshot::assert_snapshot(SNAP, "layout_h_len_fill", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_three_cols() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 36, .h = 1 };
	xray::Constraint[3] cs = { xray::cells(8), xray::fill(1), xray::cells(8) };
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

	snapshot::assert_snapshot(SNAP, "layout_h_three_cols", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_v_three_rows() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 20, .h = 9 };
	xray::Constraint[3] cs = { xray::cells(2), xray::fill(1), xray::cells(2) };
	xray::Rect[3] out;
	xray::layout_v(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(20, 9);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(7));
	sb.set_string(0, out[0].y, "hdr", sty);
	sb.set_string(0, out[1].y, "body", sty);
	sb.set_string(0, out[2].y, "ftr", sty);

	snapshot::assert_snapshot(SNAP, "layout_v_three_rows", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// Layout — percent, min, max constraints
// ============================================================

fn void test_snap_layout_h_percent() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 40, .h = 1 };
	xray::Constraint[2] cs = { xray::percent(25), xray::fill(1) };
	xray::Rect[2] out;
	xray::layout_h(area, cs[..], out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(40, 1);
	sb.clear();
	xray::Style s1 = xray::default_style().set_fg(xray::color_ansi(5));
	xray::Style s2 = xray::default_style().set_fg(xray::color_ansi(6));
	sb.set_string(out[0].x, 0, "25pct", s1);
	sb.set_string(out[1].x, 0, "fill", s2);

	snapshot::assert_snapshot(SNAP, "layout_h_percent", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

fn void test_snap_layout_h_gap() @test {
	xray::Rect area = { .x = 0, .y = 0, .w = 30, .h = 1 };
	xray::Constraint[3] cs = { xray::fill(1), xray::fill(1), xray::fill(1) };
	xray::Rect[3] out;
	xray::layout_h_gap(area, cs[..], 2, out[..]);

	xray::ScreenBuffer* sb = xray::new_screen_buffer(30, 1);
	sb.clear();
	xray::Style sty = xray::default_style().set_fg(xray::color_ansi(2));
	sb.set_string(out[0].x, 0, "A", sty);
	sb.set_string(out[1].x, 0, "B", sty);
	sb.set_string(out[2].x, 0, "C", sty);

	snapshot::assert_snapshot(SNAP, "layout_h_gap", render_rows(sb));
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

	snapshot::assert_snapshot(SNAP, "screen_plain_text", render_rows(sb));
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

	snapshot::assert_snapshot(SNAP, "screen_styled_text", render_rows(sb));
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

	snapshot::assert_snapshot(SNAP, "screen_truecolor", render_rows(sb));
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

	snapshot::assert_snapshot(SNAP, "screen_bordered", render_rows(sb));
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

	snapshot::assert_snapshot(SNAP, "screen_two_bordered", render_rows(sb));
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
	xray::Constraint[2] cs = { xray::cells(3), xray::fill(1) };
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

	snapshot::assert_snapshot(SNAP, "screen_layout_render", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}

// ============================================================
// Complex nested layout
// ============================================================

fn void test_snap_screen_nested_layout() @test {
	xray::ScreenBuffer* sb = xray::new_screen_buffer(60, 24);
	sb.clear();

	xray::Rect screen = { .x = 0, .y = 0, .w = 60, .h = 24 };

	// Top-level: header(3) + body(fill) + footer(2)
	xray::Constraint[3] vcs = { xray::cells(3), xray::fill(1), xray::cells(2) };
	xray::Rect[3] vzones;
	xray::layout_v(screen, vcs[..], vzones[..]);

	// Body: sidebar(18) + content(fill)
	xray::Constraint[2] hcs = { xray::cells(18), xray::fill(1) };
	xray::Rect[2] hzones;
	xray::layout_h(vzones[1], hcs[..], hzones[..]);

	// Styles
	xray::Style hdr_sty = xray::default_style().set_fg(xray::color_hex("#ffffff")).set_bg(xray::color_hex("#1a5276")).set_bold(true);
	xray::Style sidebar_sty = xray::default_style().set_fg(xray::color_hex("#aed6f1"));
	xray::Style content_sty = xray::default_style().set_fg(xray::color_hex("#f0f0f0"));
	xray::Style footer_sty = xray::default_style().set_fg(xray::color_hex("#888888"));
	xray::Style accent_sty = xray::default_style().set_fg(xray::color_hex("#ff5fd7")).set_bold(true);

	xray::Style bdr_cyan = xray::default_style().set_fg(xray::color_hex("#00afaf"));
	xray::Style bdr_magenta = xray::default_style().set_fg(xray::color_hex("#d75fd7"));
	xray::Style bdr_yellow = xray::default_style().set_fg(xray::color_hex("#ffd700"));

	// Header: full-width bar with title
	sb.set_string(1, vzones[0].y, "  Dashboard", hdr_sty);
	sb.set_string(40, vzones[0].y, "v1.0.0", footer_sty);

	// Sidebar: bordered with nav items
	Rect side_inner = sb.draw_border(hzones[0], xray::rounded_border(), bdr_cyan);
	sb.set_string(side_inner.x, side_inner.y, "Navigation", accent_sty);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 1), "  Home", sidebar_sty);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 2), "  Files", sidebar_sty);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 3), "  Search", sidebar_sty);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 4), "  Settings", sidebar_sty);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 6), "───────────", bdr_cyan);
	sb.set_string(side_inner.x, (sz)(side_inner.y + 7), "  About", sidebar_sty);

	// Content: nested split — main area + info card
	xray::Rect content_area = hzones[1];
	xray::Constraint[2] ccs = { xray::fill(1), xray::cells(6) };
	xray::Rect[2] czones;
	xray::layout_v(content_area, ccs[..], czones[..]);

	// Main content bordered box
	Rect main_inner = sb.draw_border(czones[0], xray::normal_border(), bdr_magenta);
	sb.set_string(main_inner.x, main_inner.y, "Main content area", content_sty);
	sb.set_string(main_inner.x, (sz)(main_inner.y + 1), "with multiple lines", content_sty);

	// Info card
	Rect card_inner = sb.draw_border(czones[1], xray::rounded_border(), bdr_yellow);
	sb.set_string(card_inner.x, card_inner.y, "Info", accent_sty);
	sb.set_string(card_inner.x, (sz)(card_inner.y + 1), " items: 42", footer_sty);

	// Footer: status bar
	sb.set_string(1, vzones[2].y, "ready", xray::default_style().set_fg(xray::color_hex("#00ff87")));
	sb.set_string(40, vzones[2].y, "ctrl-q quit", footer_sty);

	snapshot::assert_snapshot(SNAP, "screen_nested_layout", render_rows(sb));
	sb.destroy();
	mem::free(sb);
}
