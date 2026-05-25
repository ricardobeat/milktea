module split_editors;

import milktea;
import glaze;
import xray;
import std::io;
import std::core::string;
import std::core::dstring;

const int MAX_EDITORS = 4;
const int BUF_SIZE    = 4096;

struct Editor {
	char[BUF_SIZE] buf;
	sz len;
	int cursor;
	bool focused;
	String label;
	String placeholder;
}

fn void Editor.insert(Editor* self, char c) {
	if (self.len >= BUF_SIZE - 1) return;
	for (sz i = self.len; i > (sz)self.cursor; i--) {
		self.buf[i] = self.buf[i - 1];
	}
	self.buf[self.cursor] = c;
	self.len++;
	self.cursor++;
}

fn void Editor.backspace(Editor* self) {
	if (self.cursor == 0) return;
	for (sz i = (sz)self.cursor; i < self.len; i++) {
		self.buf[i - 1] = self.buf[i];
	}
	self.len--;
	self.cursor--;
}

fn String Editor.text(Editor* self) {
	return (String)self.buf[:self.len];
}

fn String Editor.view(Editor* self, int height, int pane_width, bool show_cursor) {
	glaze::Style focused = glaze::new_style().set_border(glaze::rounded_border())
		.set_border_fg(glaze::color_hex("#3b82f6"))
		.set_width(pane_width)
		.padding(0, 1, 0, 1);
	glaze::Style unfocused = glaze::new_style().set_border(glaze::hidden_border()).set_width(pane_width)
		.padding(0, 1, 0, 1);

	glaze::Style s = self.focused ? focused : unfocused;

	// Content width available for text (inside padding and borders)
	int content_width = pane_width - 4; // 2 padding + 2 border chars
	if (content_width < 1) content_width = 1;

	// Cursor line highlight styles
	glaze::Style cline_style = glaze::new_style().background(glaze::color_256(57))
		.foreground(glaze::color_256(230));
	glaze::Style placeholder_style = glaze::new_style().foreground(glaze::color_256(242));
	String cursor_block               = milktea::CURSOR_BLOCK;

	DString content = dstring::temp();
	content.append_string(self.label);
	content.append_char('\n');

	// Show placeholder if empty
	if (self.len == 0 && self.placeholder.len > 0) {
		String line_text = string::tformat("%2d %s", 1, self.placeholder);
		if (self.focused) {
			content.append_string(cline_style.render(line_text));
		} else {
			content.append_string(placeholder_style.render(line_text));
		}
		content.append_char('\n');
		return s.render(content.str_view());
	}

	// Show lines up to height, with word wrapping
	String txt      = self.text();
	sz line_num     = 1;
	int lines_shown = 0;
	int max_lines   = height - 4;
	if (max_lines < 1) max_lines = 1;

	// Find which line cursor is on for scrolling
	int cursor_line = 0;
	for (sz i = 0; i < self.len; i++) {
		if (i == (sz)self.cursor) break;
		if (self.buf[i] == '\n') cursor_line++;
	}

	// Skip lines before cursor to keep it visible
	int skip = 0;
	if (cursor_line > max_lines - 2) {
		skip = cursor_line - max_lines + 2;
	}

	sz line_start    = 0;
	int logical_line = 0;
	for (sz i = 0; i <= txt.len; i++) {
		bool at_end     = i == txt.len;
		bool at_newline = !at_end && txt[i] == '\n';

		if (at_end || at_newline) {
			// Word-wrap this logical line into display lines
			sz seg_start = line_start;
			while (seg_start < i) {
				sz seg_end    = seg_start;
				sz last_break = seg_start;
				int col       = 0;
				while (seg_end < i && col < content_width) {
					if (txt[seg_end] == ' ') last_break = seg_end + 1;
					col++;
					seg_end++;
				}
				// If we didn't reach the end, break at last word boundary
				if (seg_end < i && last_break > seg_start) {
					seg_end = last_break;
				}
				if (seg_end == seg_start) seg_end = seg_start + 1; // safety

				if (logical_line >= skip && lines_shown < max_lines) {
					bool is_cursor_line = self.focused && logical_line == cursor_line;
					DString line_buf    = dstring::temp();
					line_buf.append_string(string::tformat("%2d ", line_num));
					line_buf.append_string(txt[seg_start:seg_end - seg_start]);
					if (is_cursor_line && show_cursor && (sz)self.cursor >= seg_start && (sz)self.cursor <= seg_end) {
						line_buf.append_string(cursor_block);
					}
					if (is_cursor_line) {
						// Pad cursor line to full content width so highlight extends across
						int used = 3 + (int)(seg_end - seg_start);
						if (show_cursor && (sz)self.cursor >= seg_start && (sz)self.cursor <= seg_end) used++;
						for (int p = used; p < content_width; p++) line_buf.append_char(' ');
						content.append_string(cline_style.render(line_buf.str_view()));
					} else {
						content.append_string(line_buf.str_view());
					}
					content.append_char('\n');
					lines_shown++;
				}
				logical_line++;
				seg_start = seg_end;
			}

			// If cursor is at the end of this logical line (e.g. right after
			// pressing Enter), render an empty line with the cursor visible.
			if (at_newline && (sz)self.cursor == i + 1 && logical_line + 1 >= skip && lines_shown < max_lines) {
				bool is_cursor_line = self.focused && logical_line + 1 == cursor_line;
				DString line_buf    = dstring::temp();
				line_buf.append_string(string::tformat("%2d ", (int)(line_num + 1)));
				if (is_cursor_line && show_cursor) {
					line_buf.append_string(cursor_block);
				}
				if (is_cursor_line) {
					// Pad cursor line to full content width
					int used = 4; // "NN " + cursor block
					for (int p = used; p < content_width; p++) line_buf.append_char(' ');
					content.append_string(cline_style.render(line_buf.str_view()));
				} else {
					content.append_string(line_buf.str_view());
				}
				content.append_char('\n');
				lines_shown++;
				logical_line++;
			}
			line_num++;
			line_start = i + 1;
			if (at_end) break;
		}
	}

	return s.render(content.str_view());
}

struct SplitModel {
	Editor[4] editors;
	int count;
	int focus;
	int height;
	int width;
	int cursor_blink;
}

fn milktea::Cmd SplitModel.init(SplitModel* self) @dynamic {
	self.count = 2;
	self.focus = 0;
	self.editors[0].label = "Editor 1";
	self.editors[0].focused = true;
	self.editors[0].placeholder = "type something";
	self.editors[1].label = "Editor 2";
	self.editors[1].placeholder = "type something";
	self.editors[2].label = "Editor 3";
	self.editors[3].label = "Editor 4";
	return milktea::tick(500);
}


fn milktea::Cmd SplitModel.update(SplitModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind == milktea::MsgKind.TICK) {
		self.cursor_blink = 1 - self.cursor_blink;
		return milktea::tick(500);
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.TAB:
			if (k.shift) {
				// Shift-Tab: previous pane
				self.editors[self.focus].focused = false;
				self.focus--;
				if (self.focus < 0) self.focus = self.count - 1;
				self.editors[self.focus].focused = true;
			} else {
				// Tab: next pane
				self.editors[self.focus].focused = false;
				self.focus = (self.focus + 1) % self.count;
				self.editors[self.focus].focused = true;
			}
		case milktea::KeyCode.BACKSPACE:
			self.editors[self.focus].backspace();
		case milktea::KeyCode.ENTER:
			self.editors[self.focus].insert('\n');
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.ctrl) {
				if (k.rune == 'n') {
					// Ctrl+N - add editor
					if (self.count < MAX_EDITORS) self.count++;
				}
				if (k.rune == 'w') {
					// Ctrl+W - remove editor
					if (self.count > 1) {
						self.editors[self.focus].focused = false;
						self.count--;
						if (self.focus >= self.count) self.focus = self.count - 1;
						self.editors[self.focus].focused = true;
					}
				}
			} else {
				self.editors[self.focus].insert(k.rune);
			}
		default:
	}
	return null;
}

fn milktea::View SplitModel.view(SplitModel* self) @dynamic {
	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));
	bool show_cursor     = self.cursor_blink != 0;

	int edit_h = self.height - 3;
	if (edit_h < 5) edit_h = 5;

	xray::Constraint[4] pane_cs;
	for (int i = 0; i < self.count; i++) pane_cs[i] = xray::constraint_fill(1);
	xray::Rect[4] pane_rects;
	xray::layout_h(xray::new_rect(0, 0, self.width, edit_h), pane_cs[0:self.count], pane_rects[0:self.count]);

	DString out = dstring::temp();
	String[4] views;
	for (int i = 0; i < self.count; i++) {
		int pane_w = pane_rects[i].w < 10 ? 10 : pane_rects[i].w;
		views[i] = self.editors[i].view(edit_h, pane_w, show_cursor);
	}

	if (self.count == 1) {
		out.append_string(views[0]);
	} else {
		String joined = views[0];
		for (int i = 1; i < self.count; i++) {
			joined = glaze::join_horizontal(joined, views[i], 0);
		}
		out.append_string(joined);
	}

	out.append_char('\n');
	out.append_string(
		hint.render(
			string::tformat(
				"TAB: next | Shift+TAB: prev | Ctrl+N: add | Ctrl+W: close | ESC: quit | Panes: %d",
				self.count
			)
		)
	);
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	SplitModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Bye!");
	return 0;
}