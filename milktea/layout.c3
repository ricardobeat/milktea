module milktea;

import std::core::dstring;
import glaze;
import xray;

// Layout tracks rows and auto-computes cursor position for View construction.
// Eliminates manual row counting and cursor arithmetic.
// 
// Example:
//   Layout l = new_layout();
//   l.write_line(title.render("Sign Up"));
//   l.write_line("");
//   l.write_input_line("Nickname:", input.view(), focused, input.cursor_x());
//   l.write_line("");
//   l.write_line(hint.render("TAB to switch"));
//   return l.view();
struct Layout {
	DString out;
	int row; // current row (0-indexed, incremented by writeln)
	int cur_row; // cursor row (-1 = no cursor)
	int cur_col; // cursor column
	bool alt_screen;
}

// new_layout creates a Layout for inline mode.
fn Layout new_layout() {
	return { .out = dstring::temp(), .row = 0, .cur_row = -1, .cur_col = 0 };
}

// new_alt_layout creates a Layout for alt-screen mode.
fn Layout new_alt_layout() {
	return { .out = dstring::temp(), .row = 0, .cur_row = -1, .cur_col = 0, .alt_screen = true };
}

// write appends content without advancing the row counter.
// Use for partial line content.
fn Layout* Layout.write(Layout* self, String s) {
	self.out.append_string(s);
	return self;
}

// write_line appends content followed by a newline, advancing the row.
fn Layout* Layout.write_line(Layout* self, String s) {
	self.out.append_string(s);
	self.out.append_char('\n');
	self.row++;
	return self;
}

// write_input_line writes a label + value pair, tracking cursor if focused.
// label_width is the visual width of the label (use glaze::string_width or hardcode).
// cursor_offset is the cursor position within the value (0 = start).
fn Layout* Layout.write_input_line(
	Layout* self,
	String label,
	String value,
	bool focused,
	int cursor_offset,
	int label_width
) {
	self.out.append_string(label);
	self.out.append_char(' ');
	self.out.append_string(value);
	if (focused) {
		self.cur_row = self.row;
		self.cur_col = label_width + 1 + cursor_offset;
	}
	self.out.append_char('\n');
	self.row++;
	return self;
}

// view builds the final View from the accumulated layout.
fn View Layout.view(Layout* self) {
	View v;
	if (self.alt_screen) {
		v = new_alt_screen_view(self.out.str_view());
	} else {
		v = new_view(self.out.str_view());
	}
	if (self.cur_row >= 0) {
		v.has_cursor = true;
		v.cursor = new_cursor(self.cur_col, self.cur_row);
	}
	return v;
}

// ============================================================
// LayoutNode — declarative constraint-based layout
// ============================================================

const sz MAX_LAYOUT_NODES = 16;

// LayoutNode pairs a layout constraint with a glaze style and content string.
// Used with hstack / vstack for declarative composition.
struct LayoutNode @mustinit {
	xray::Constraint constraint;
	glaze::Style     style;
	String           content;
}

// hstack resolves constraints horizontally, renders each node, and joins them.
// gap sets the number of empty columns between nodes (default 0).
fn String hstack(xray::Rect area, LayoutNode[] nodes, int gap = 0) {
	sz n = nodes.len;
	if (n == 0) return "";
	if (n > MAX_LAYOUT_NODES) n = MAX_LAYOUT_NODES;

	xray::Constraint[MAX_LAYOUT_NODES] cs;
	for (sz i = 0; i < n; i++) cs[i] = nodes[i].constraint;

	xray::Rect[MAX_LAYOUT_NODES] rects;
	xray::layout_h_gap(area, cs[0:n], gap, rects[0:n]);

	String[MAX_LAYOUT_NODES] views;
	for (sz i = 0; i < n; i++) {
		views[i] = nodes[i].style.set_width(rects[i].w).set_height(rects[i].h).render(nodes[i].content);
	}

	String result = views[0];
	for (sz i = 1; i < n; i++) {
		result = glaze::join_horizontal(result, views[i], gap);
	}
	return result;
}

// vstack resolves constraints vertically, renders each node, and joins them.
// gap sets the number of empty rows between nodes (default 0).
fn String vstack(xray::Rect area, LayoutNode[] nodes, int gap = 0) {
	sz n = nodes.len;
	if (n == 0) return "";
	if (n > MAX_LAYOUT_NODES) n = MAX_LAYOUT_NODES;

	xray::Constraint[MAX_LAYOUT_NODES] cs;
	for (sz i = 0; i < n; i++) cs[i] = nodes[i].constraint;

	xray::Rect[MAX_LAYOUT_NODES] rects;
	xray::layout_v_gap(area, cs[0:n], gap, rects[0:n]);

	String[MAX_LAYOUT_NODES] views;
	for (sz i = 0; i < n; i++) {
		views[i] = nodes[i].style.set_width(rects[i].w).set_height(rects[i].h).render(nodes[i].content);
	}

	String result = views[0];
	for (sz i = 1; i < n; i++) {
		result = glaze::join_vertical(glaze::Position.LEFT, result, views[i]);
	}
	return result;
}