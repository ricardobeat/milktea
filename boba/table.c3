module boba;

import milktea;
import glaze;
import std::core::dstring;

// TableColumn defines a column in a table.
struct TableColumn {
	String title;
	int width;
}

// TableRow represents a row of data.
struct TableRow {
	String[8] cells;
	int cell_count;
}

// Table is a structured data display component.
struct Table {
	TableColumn[16] columns;
	int col_count;
	TableRow[64] rows;
	int row_count;
	int cursor;
	int scroll_offset;
	int width;
	int height;
	bool has_header;
	glaze::Style header_style;
	glaze::Style cursor_style;
	glaze::Style row_style;
	glaze::Style border_style;
}

// new_table creates an empty table.
fn Table new_table() {
	Table t = { };
	t.has_header = true;
	t.header_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	t.cursor_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true);
	t.row_style = glaze::new_style().foreground(glaze::color_hex("#cccccc"));
	t.border_style = glaze::new_style().foreground(glaze::color_hex("#444444"));
	return t;
}

// add_column adds a column with the given title and width.
fn void Table.add_column(&self, String title, int width) {
	if (self.col_count >= 16) return;
	self.columns[self.col_count] = { .title = title, .width = width };
	self.col_count++;
}

// add_row adds a row with the given cell values.
fn void Table.add_row(&self, String c0) {
	if (self.row_count >= 256) return;
	TableRow r = { };
	r.cells[0] = c0;
	r.cell_count = 1;
	self.rows[self.row_count] = r;
	self.row_count++;
}

// add_row2 adds a row with 2 cells.
fn void Table.add_row2(&self, String c0, String c1) {
	if (self.row_count >= 256) return;
	TableRow r = { };
	r.cells[0] = c0;
	r.cells[1] = c1;
	r.cell_count = 2;
	self.rows[self.row_count] = r;
	self.row_count++;
}

// add_row3 adds a row with 3 cells.
fn void Table.add_row3(&self, String c0, String c1, String c2) {
	if (self.row_count >= 256) return;
	TableRow r = { };
	r.cells[0] = c0;
	r.cells[1] = c1;
	r.cells[2] = c2;
	r.cell_count = 3;
	self.rows[self.row_count] = r;
	self.row_count++;
}

// handle_key processes table navigation keybindings.
// Returns true if the key was consumed.
fn bool Table.handle_key(&self, milktea::KeyMsg k) {
	int visible = self.height - 2;
	if (visible < 1) visible = 1;

	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.cursor > 0) self.cursor--;
			return true;
		case milktea::KeyCode.DOWN:
			if (self.cursor < self.row_count - 1) self.cursor++;
			return true;
		case milktea::KeyCode.HOME:
			self.cursor = 0;
			return true;
		case milktea::KeyCode.END:
			self.cursor = self.row_count - 1;
			return true;
		case milktea::KeyCode.PAGE_UP:
			self.cursor -= visible;
			if (self.cursor < 0) self.cursor = 0;
			return true;
		case milktea::KeyCode.PAGE_DOWN:
			self.cursor += visible;
			if (self.cursor >= self.row_count) self.cursor = self.row_count - 1;
			return true;
		default:
			return false;
	}
}

// view returns the rendered table string.
fn String Table.view(&self) {
	int visible = self.height - 2;
	if (visible < 1) visible = 1;

	// Adjust scroll
	if (self.cursor < self.scroll_offset) self.scroll_offset = self.cursor;
	if (self.cursor >= self.scroll_offset + visible) self.scroll_offset = self.cursor - visible + 1;

	DString out = dstring::temp();

	// Header
	if (self.has_header) {
		for (int c = 0; c < self.col_count; c++) {
			String cell = self.columns[c].title;
			// Pad/truncate to width



			if (cell.len < self.columns[c].width) {
				DString padded = dstring::temp();
				padded.append_string(cell);
				for (int p = (int)cell.len; p < self.columns[c].width; p++) padded.append_char(' ');
				cell = padded.str_view();
			} else if (cell.len > self.columns[c].width) {
				cell = (String)cell[:self.columns[c].width];
			}
			out.append_string(self.header_style.render(cell));
			if (c < self.col_count - 1) out.append_char(' ');
		}
		out.append_char('\n');

		// Separator
		int total_w = 0;
		for (int c = 0; c < self.col_count; c++) total_w += self.columns[c].width;
		total_w += self.col_count - 1;
		for (int i = 0; i < total_w; i++) out.append_string("\xe2\x94\x80");
		out.append_char('\n');
	}

	// Rows
	int end = self.scroll_offset + visible;
	if (end > self.row_count) end = self.row_count;

	for (int r = self.scroll_offset; r < end; r++) {
		TableRow row       = self.rows[r];
		glaze::Style rs = (r == self.cursor) ? self.cursor_style : self.row_style;

		for (int c = 0; c < self.col_count; c++) {
			String cell = "";
			if (c < row.cell_count) cell = row.cells[c];

			if (cell.len < self.columns[c].width) {
				DString padded = dstring::temp();
				padded.append_string(cell);
				for (int p = (int)cell.len; p < self.columns[c].width; p++) padded.append_char(' ');
				cell = padded.str_view();
			} else if (cell.len > self.columns[c].width) {
				cell = (String)cell[:self.columns[c].width];
			}
			out.append_string(rs.render(cell));
			if (c < self.col_count - 1) out.append_char(' ');
		}
		out.append_char('\n');
	}

	return out.str_view();
}