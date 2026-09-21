module boba;

import milktea;
import xray;
import glaze;
import std::io;
import std::core::dstring;
import std::core::mem;

// FilePicker is a file browser component.
struct FilePicker (xray::Content) {
	char[64][64] names;
	int[64] name_lens;
	bool[64] is_dirs;
	int count;
	int cursor;
	int scroll;
	// Distinct from cursor (the keyboard position): the row that the user
	// clicked, kept across frames so its highlight survives until the next
	// click moves it. -1 = no row selected yet.
	int selected;
	// Row currently under the pointer, -1 if none. The picker manages this
	// itself through each row node's on_hover_in/out hooks; the app does not
	// have to touch it.
	int hover;
	String current_dir;
	String selected_name;
	int width;
	int height;
	glaze::Style cursor_style;
	glaze::Style selected_style;
	glaze::Style hover_style;
	glaze::Style dir_style;
	glaze::Style file_style;
	glaze::Style title_style;
	glaze::Style hint_style;
	glaze::Style error_style;
	// Row-click callback the app registers through on_row_click. Fires when
	// any visible row is pressed, with the row's name and a flag for whether
	// it is a directory. The app usually responds by loading the dir or
	// opening the file; both are single-line setters and need no col/row
	// arithmetic.
	FilePickerRowFn on_row_click_fn;
	void* on_row_click_ctx;
}

// FilePickerRowFn is what FilePicker.on_row_click takes. id is the per-call
// ctx the app registered; name is the row's filename (without the trailing
// slash, for both files and directories); is_dir reports the kind; col, row
// are the press position in cells (rarely useful — the name is the identity).
alias FilePickerRowFn = fn void(void* id, String name, bool is_dir, int col, int row);

// new_file_picker creates a file picker starting in the given directory.
fn FilePicker new_file_picker(String start_dir) {
	FilePicker fp = { };
	fp.current_dir = start_dir;
	fp.selected = -1;
	fp.hover = -1;
	fp.cursor_style = glaze::style().foreground(glaze::color_hex("#ff00ff")).with_bold(true);
	fp.selected_style = glaze::style().background(glaze::color_hex("#444444")).foreground(glaze::color_hex("#ffffff")).with_bold(true);
	fp.hover_style = glaze::style().background(glaze::color_hex("#2a2a2a")).foreground(glaze::color_hex("#ffffff"));
	fp.dir_style = glaze::style().foreground(glaze::color_hex("#00d7ff"));
	fp.file_style = glaze::style().foreground(glaze::color_hex("#cccccc"));
	fp.title_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	fp.hint_style = glaze::style().foreground(glaze::color_hex("#666666"));
	fp.error_style = glaze::style().foreground(glaze::color_hex("#ff0000"));
	return fp;
}

// on_row_click registers the app's handler for presses on visible rows. The
// callback fires once per click with the row's file name and a flag for
// whether it is a directory; the picker resolves "which row" internally and
// updates its own `selected` / `selected_name` fields before calling.
//
// ctx is whatever the app wants back from the callback — typically &self, the
// owning editor. The picker keeps the address; the picker itself lives for
// the duration of the app, so ctx stays valid across frames.
fn void FilePicker.on_row_click(&self, FilePickerRowFn cb, void* ctx) {
	self.on_row_click_fn = cb;
	self.on_row_click_ctx = ctx;
}

// load_dir loads the contents of a directory.
fn void FilePicker.load_dir(&self, String path) {
	self.selected_name = "";
	self.selected = -1;
	self.hover = -1;
	self.count = 0;
	self.cursor = 0;
	self.scroll = 0;
	self.current_dir = path;

	@pool() {
		char[512] path_buf;
		// Truncate rather than overflow: the loop stops at 511, so the
		// terminator must be clamped too. ENTER appends "/name" per directory
		// level with no bound, so long paths are reachable in normal use.
		sz path_len = path.len < 511 ? path.len : 511;
		for (sz i = 0; i < path_len; i++) {
			path_buf[i] = path[i];
		}
		path_buf[path_len] = 0;

		char[64 * 64] name_buf;
		int[64] dir_flags;

		int n = c3_list_dir(&path_buf[0], &name_buf[0], &dir_flags[0], 64);

		for (int i = 0; i < n && self.count < 64; i++) {
			self.is_dirs[self.count] = (dir_flags[i] != 0);

			int offset = i * 64;
			sz j       = 0;
			while (j < 63 && name_buf[offset + j] != 0) {
				self.names[self.count][j] = name_buf[offset + j];
				j++;
			}
			self.names[self.count][j] = 0;
			self.name_lens[self.count] = (int)j;

			// Skip hidden files (except . and ..)
			if (j > 0 && self.names[self.count][0] == '.'
				&& !(j == 1 || (j == 2 && self.names[self.count][1] == '.'))) {
				continue;
			}

			self.count++;
		}
	};
}

extern fn int c3_list_dir(char* path, char* names, int* is_dirs, int max_entries);

// clear_selection drops the row a click chose. Navigating with the arrows
// means the cursor is the current row again, and a list showing two
// highlighted rows — one the keyboard's, one the pointer's — is a list whose
// selection looks like it ignores the arrow keys.
fn void FilePicker.clear_selection(&self) {
	self.selected = -1;
	self.selected_name = "";
}

// handle_key processes file picker keybindings.
// Returns true if the key was consumed.
fn bool FilePicker.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.cursor > 0) self.cursor--;
			self.clear_selection();
			return true;
		case milktea::KeyCode.DOWN:
			if (self.cursor < self.count - 1) self.cursor++;
			self.clear_selection();
			return true;
		case milktea::KeyCode.ENTER:
			if (self.cursor < self.count && self.is_dirs[self.cursor]) {
				// Don't navigate into "."
				if (self.name_lens[self.cursor] == 1 && self.names[self.cursor][0] == '.') {
					return true;
				}
				DString new_path = dstring::temp();
				new_path.append_string(self.current_dir);
				new_path.append_char('/');
				new_path.append_string((String)self.names[self.cursor][:self.name_lens[self.cursor]]);
				self.load_dir(new_path.str_view());
			} else if (self.cursor < self.count) {
				self.selected = self.cursor;
				self.selected_name = (String)self.names[self.cursor][:self.name_lens[self.cursor]];
			}
			return true;
		case milktea::KeyCode.BACKSPACE:
		case milktea::KeyCode.LEFT:
			// Go to parent directory
			if (self.current_dir.len > 1) {
				sz last_slash = self.current_dir.len - 1;
				while (last_slash > 0 && self.current_dir[last_slash] != '/') last_slash--;
				if (last_slash > 0) {
					self.load_dir((String)self.current_dir[:last_slash]);
				} else {
					self.load_dir("/");
				}
			}
			return true;
		default:
			return false;
	}
}

// view returns the rendered file picker string.
fn String FilePicker.view(&self) {
	DString out = dstring::temp();
	out.append_string(self.title_style.render(string::tformat("Files: %s", self.current_dir)));
	out.append_char('\n');

	int visible = self.height - 4;
	if (visible < 1) visible = 1;

	// Adjust scroll
	if (self.cursor < self.scroll) self.scroll = self.cursor;
	if (self.cursor >= self.scroll + visible) self.scroll = self.cursor - visible + 1;

	int end = self.scroll + visible;
	if (end > self.count) end = self.count;

	for (int i = self.scroll; i < end; i++) {
		String name   = (String)self.names[i][:self.name_lens[i]];
		String suffix = self.is_dirs[i] ? "/" : "";
		String marker = (i == self.cursor) ? "> " : "  ";

		if (i == self.cursor) {
			out.append_string(self.cursor_style.render(string::tformat("%s%s%s", marker, name, suffix)));
		} else if (self.is_dirs[i]) {
			out.append_string(self.dir_style.render(string::tformat("%s%s%s", marker, name, suffix)));
		} else {
			out.append_string(self.file_style.render(string::tformat("%s%s%s", marker, name, suffix)));
		}
		out.append_char('\n');
	}

	out.append_char('\n');
	out.append_string(self.hint_style.render("Enter: open | Backspace: parent | q: quit"));
	return out.str_view();
}

// ── layout tree ──────────────────────────────────────────────────────────────

fn String FilePicker.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn int FilePicker.measure(&self, int width) @dynamic => self.height;
fn int FilePicker.measure_width(&self, int height) @dynamic => self.width;

fn xray::Node* FilePicker.node(&self) => xray::content_node(self);

// ── click / hover wiring ─────────────────────────────────────────────────────
//
// The picker manages hover and selected internally: row nodes fire
// picker_row_hover_in / *_out so the picker knows which row the pointer is
// over (regardless of whether the app registered an on_row_click), and
// picker_row_clicked updates the selected index before delegating to the
// app's registered callback. The app never has to walk a target list to
// figure out which row was clicked.
//
// A click also moves the cursor, since the cursor is the keyboard's idea of
// the current row and a click is the pointer saying which row that is: leave
// it behind and the next arrow key moves the highlight away from the row the
// user just clicked, which reads as the list ignoring the keyboard.
//
// ctx for picker_row_clicked / hover_in / hover_out is a fresh PickRowCtx on
// tmem that captures &self + index, so the framework only sees a void* and
// the picker's static handler does the cast.

struct PickRowCtx {
	FilePicker* picker;
	int index;
}

fn void picker_row_clicked(void* id, String id_str, int col, int row) @local {
	PickRowCtx* rc = (PickRowCtx*)id;
	FilePicker* fp = rc.picker;
	int i = rc.index;
	if (i < 0 || i >= fp.count) return;
	fp.cursor = i;
	fp.selected = i;
	fp.selected_name = (String)fp.names[i][:fp.name_lens[i]];
	if (fp.on_row_click_fn != null) {
		fp.on_row_click_fn(fp.on_row_click_ctx,
			fp.selected_name, fp.is_dirs[i], col, row);
	}
}

fn void picker_row_hover_in(void* id, String id_str, int col, int row) @local {
	PickRowCtx* rc = (PickRowCtx*)id;
	rc.picker.hover = rc.index;
}

fn void picker_row_hover_out(void* id, String id_str, int col, int row) @local {
	PickRowCtx* rc = (PickRowCtx*)id;
	if (rc.picker.hover == rc.index) rc.picker.hover = -1;
}

// row_node builds one row as an xray node, picking the style from the row's
// relationship to cursor / selected / hover. ctx is a fresh PickRowCtx that
// the node tree keeps alive for the frame — tmem handles the cleanup.
fn xray::Node* FilePicker.row_node(&self, int i) {
	String name = (String)self.names[i][:self.name_lens[i]];
	String suffix = self.is_dirs[i] ? "/" : "";
	glaze::Style* s;
	if (i == self.cursor) { s = &self.cursor_style; }
	else if (i == self.selected) { s = &self.selected_style; }
	else if (i == self.hover) { s = &self.hover_style; }
	else if (self.is_dirs[i]) { s = &self.dir_style; }
	else { s = &self.file_style; }
	String marker = (i == self.cursor) || (i == self.selected) ? "> " : "  ";
	String label = string::tformat("%s%s%s", marker, name, suffix);
	PickRowCtx* rc = mem::tnew(PickRowCtx);
	rc.picker = self;
	rc.index = i;
	xray::Node* n = milktea::text(*s, label).height(milktea::cells(1));
	n.id_with(rc)
		.on_click(&picker_row_clicked)
		.on_hover_in(&picker_row_hover_in)
		.on_hover_out(&picker_row_hover_out);
	return n;
}

// tree_node returns the picker as a real layout tree: a vstack of one node
// per visible row, each clickable and hover-aware. Apps building a sidebar
// or dialog from a FilePicker use this in their view() — the alternative,
// rendering the picker as one content node, makes the rows invisible to
// mouse hit-testing.
//
// scroll is reconciled with cursor here, the same way view() does for the
// string form, so the visible rows in the tree match the rows the terminal
// would see.
fn xray::Node* FilePicker.tree_node(&self) {
	int visible = self.height - 4;
	if (visible < 1) visible = 1;
	if (self.cursor < self.scroll) self.scroll = self.cursor;
	if (self.cursor >= self.scroll + visible) self.scroll = self.cursor - visible + 1;
	int end = self.scroll + visible;
	if (end > self.count) end = self.count;

	xray::Node* v = xray::vstack();
	v.add(milktea::text(self.title_style, string::tformat("Files: %s", self.current_dir))
		.height(milktea::cells(1)));
	for (int i = self.scroll; i < end; i++) {
		v.add(self.row_node(i));
	}
	// Pad with empty rows so the picker's total height matches the rect the
	// app laid out, otherwise the next thing under it slides up when fewer
	// than `visible` rows exist.
	int pad = visible - (end - self.scroll);
	for (int i = 0; i < pad; i++) {
		v.add(milktea::text(self.file_style, "").height(milktea::cells(1)));
	}
	v.add(milktea::text(self.hint_style, "Enter: open | Backspace: parent | q: quit")
		.height(milktea::cells(1)));
	return v;
}
