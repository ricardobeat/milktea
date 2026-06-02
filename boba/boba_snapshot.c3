module boba_snapshot @test;

import snapshot;
import boba;
import glaze;

const String SNAP = "boba";

// ============================================================
// List
// ============================================================

fn void test_snap_list_basic() @test {
	boba::List lst = boba::new_list();
	lst.set_size(30, 5);
	lst.add_item("Buy milk", "from the store");
	lst.add_item("Write code", "in C3");
	lst.add_item("Walk dog", "around the block");
	String out = lst.view();
	snapshot::assert_snapshot(SNAP, "list_basic", out);
}

fn void test_snap_list_single() @test {
	boba::List lst = boba::new_list();
	lst.set_size(24, 3);
	lst.add_item("Only item", "sole entry");
	String out = lst.view();
	snapshot::assert_snapshot(SNAP, "list_single", out);
}

fn void test_snap_list_long() @test {
	boba::List lst = boba::new_list();
	lst.set_size(32, 6);
	lst.add_item("First", "");
	lst.add_item("Second", "");
	lst.add_item("Third", "");
	lst.add_item("Fourth", "");
	lst.add_item("Fifth", "");
	String out = lst.view();
	snapshot::assert_snapshot(SNAP, "list_long", out);
}

// ============================================================
// Progress (boba widget)
// ============================================================

fn void test_snap_progress_half() @test {
	boba::Progress p = boba::new_progress(20, 50);
	String out = p.view();
	snapshot::assert_snapshot(SNAP, "progress_half", out);
}

fn void test_snap_progress_full() @test {
	boba::Progress p = boba::new_progress(20, 100);
	String out = p.view();
	snapshot::assert_snapshot(SNAP, "progress_full", out);
}

fn void test_snap_progress_empty() @test {
	boba::Progress p = boba::new_progress(20, 0);
	String out = p.view();
	snapshot::assert_snapshot(SNAP, "progress_empty", out);
}

fn void test_snap_progress_with_percent() @test {
	boba::Progress p = boba::new_progress(24, 75);
	String out = p.view_with_percent();
	snapshot::assert_snapshot(SNAP, "progress_with_percent", out);
}

fn void test_snap_progress_custom_chars() @test {
	boba::Progress p = boba::new_progress(20, 50);
	p.with_chars("█", "░");
	String out = p.view();
	snapshot::assert_snapshot(SNAP, "progress_custom_chars", out);
}

// ============================================================
// Pagination
// ============================================================

fn void test_snap_pagination_basic() @test {
	boba::Pagination pg = boba::new_pagination(10, 50);
	String out = pg.view();
	snapshot::assert_snapshot(SNAP, "pagination_basic", out);
}

fn void test_snap_pagination_middle() @test {
	boba::Pagination pg = boba::new_pagination(10, 100);
	pg.goto_page(3);
	String out = pg.view();
	snapshot::assert_snapshot(SNAP, "pagination_middle", out);
}

fn void test_snap_pagination_last() @test {
	boba::Pagination pg = boba::new_pagination(10, 55);
	pg.goto_page(5);
	String out = pg.view();
	snapshot::assert_snapshot(SNAP, "pagination_last", out);
}

fn void test_snap_pagination_numbers() @test {
	boba::Pagination pg = boba::new_pagination(10, 50);
	pg.with_kind(boba::PaginatorType.NUMBERS);
	String out = pg.view();
	snapshot::assert_snapshot(SNAP, "pagination_numbers", out);
}

// ============================================================
// Table
// ============================================================

fn void test_snap_table_basic() @test {
	boba::Table t = boba::new_table();
	t.width = 40;
	t.height = 8;
	t.add_column("Name", 12);
	t.add_column("Value", 8);
	t.add_row2("alpha", "100");
	t.add_row2("beta", "200");
	t.add_row2("gamma", "300");
	String out = t.view();
	snapshot::assert_snapshot(SNAP, "table_basic", out);
}

fn void test_snap_table_single_col() @test {
	boba::Table t = boba::new_table();
	t.width = 20;
	t.height = 5;
	t.add_column("Item", 16);
	t.add_row("one");
	t.add_row("two");
	String out = t.view();
	snapshot::assert_snapshot(SNAP, "table_single_col", out);
}

fn void test_snap_table_three_cols() @test {
	boba::Table t = boba::new_table();
	t.width = 48;
	t.height = 8;
	t.add_column("A", 10);
	t.add_column("B", 10);
	t.add_column("C", 10);
	t.add_row3("a1", "b1", "c1");
	t.add_row3("a2", "b2", "c2");
	String out = t.view();
	snapshot::assert_snapshot(SNAP, "table_three_cols", out);
}

// ============================================================
// Help
// ============================================================

fn void test_snap_help_basic() @test {
	boba::Help h = boba::new_help();
	h.add_entry("q", "quit");
	h.add_entry("↑/↓", "navigate");
	h.add_entry("enter", "select");
	String out = h.view();
	snapshot::assert_snapshot(SNAP, "help_basic", out);
}

fn void test_snap_help_default() @test {
	boba::Help h = boba::default_help();
	String out = h.view();
	snapshot::assert_snapshot(SNAP, "help_default", out);
}

fn void test_snap_help_vertical() @test {
	boba::Help h = boba::new_help();
	h.add_entry("q", "quit");
	h.add_entry("j/k", "scroll");
	h.add_entry("/", "search");
	String out = h.view_vertical();
	snapshot::assert_snapshot(SNAP, "help_vertical", out);
}

// ============================================================
// TextInput
// ============================================================

fn void test_snap_textinput_empty() @test {
	boba::TextInput ti = boba::new_text_input();
	String out = ti.view();
	snapshot::assert_snapshot(SNAP, "textinput_empty", out);
}

fn void test_snap_textinput_placeholder() @test {
	boba::TextInput ti = boba::new_text_input();
	ti.with_placeholder("Type here...");
	String out = ti.view();
	snapshot::assert_snapshot(SNAP, "textinput_placeholder", out);
}

fn void test_snap_textinput_with_text() @test {
	boba::TextInput ti = boba::new_text_input();
	ti.insert_string("hello world");
	String out = ti.view();
	snapshot::assert_snapshot(SNAP, "textinput_with_text", out);
}

fn void test_snap_textinput_password() @test {
	boba::TextInput ti = boba::new_text_input();
	ti.with_password();
	ti.insert_string("secret123");
	String out = ti.view();
	snapshot::assert_snapshot(SNAP, "textinput_password", out);
}

// ============================================================
// Textarea
// ============================================================

fn void test_snap_textarea_empty() @test {
	boba::Textarea ta = boba::new_textarea(30, 5);
	String out = ta.view();
	snapshot::assert_snapshot(SNAP, "textarea_empty", out);
}

fn void test_snap_textarea_with_text() @test {
	boba::Textarea ta = boba::new_textarea(30, 5);
	foreach (ch : "hello") {
		ta.insert(ch);
	}
	ta.insert('\n');
	foreach (ch : "world") {
		ta.insert(ch);
	}
	String out = ta.view();
	snapshot::assert_snapshot(SNAP, "textarea_with_text", out);
}

fn void test_snap_textarea_placeholder() @test {
	boba::Textarea ta = boba::new_textarea(30, 5);
	ta.with_placeholder("Start typing...");
	String out = ta.view();
	snapshot::assert_snapshot(SNAP, "textarea_placeholder", out);
}
