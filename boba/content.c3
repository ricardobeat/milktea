module boba;

import milktea;
import xray;
import glaze;

// Content implementations, so a component can be added to a layout tree
// directly:
//
//   milktea::vstack()
//       .add(milktea::text(title_s, "Files").height(milktea::cells(1)))
//       .add(&self.list)
//
// render takes the size the layout settled on and stores it on the component
// before calling view(). That is impure, but components already keep their
// size as state and need it outside of rendering — Viewport reads self.height
// in handle_key to scroll by a page, before any render happens.
//
// Components that own a cursor implement cursor() and report it only while
// focused, so an unfocused input does not fight a focused one for it.

fn String List.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn String Table.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn String Viewport.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn String FilePicker.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

// A progress bar is the one component whose whole job is to span its rect.
fn String Progress.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	return self.view();
}

// The rest draw one line of their own width, so the rect only bounds them.

fn String Help.render(&self, xray::Rect r) @dynamic => self.view();

fn String Pagination.render(&self, xray::Rect r) @dynamic => self.view();

fn String Spinner.render(&self, xray::Rect r) @dynamic => self.view();

fn String Stopwatch.render(&self, xray::Rect r) @dynamic => self.view();

fn String Timer.render(&self, xray::Rect r) @dynamic => self.view();

fn int Help.measure(&self, int width) @dynamic => 1;
fn int Progress.measure(&self, int width) @dynamic => 1;
fn int Pagination.measure(&self, int width) @dynamic => 1;
fn int Spinner.measure(&self, int width) @dynamic => 1;
fn int Stopwatch.measure(&self, int width) @dynamic => 1;
fn int Timer.measure(&self, int width) @dynamic => 1;

// TextInput is one row, and its cursor sits at the caret offset within it.

fn String TextInput.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

// One row of text, plus whatever the style frames it with.
fn int TextInput.measure(&self, int width) @dynamic {
	glaze::Style s = self.focused ? self.focused_style : self.blurred_style;
	int frame = 0;
	if (s.border_style.top.len > 0) frame++;
	if (s.border_style.bottom.len > 0) frame++;
	return 1 + s.pad_top + s.pad_bottom + frame;
}

fn xray::ContentCursor TextInput.cursor(&self, xray::Rect r) @dynamic {
	if (!self.focused) return {};
	// The style frames the text, so the caret sits inside the border and
	// padding rather than at the rect's own corner. Reading it from the style
	// means changing the border cannot move the cursor off the text.
	glaze::Style s = self.focused_style;
	int inset_x = s.pad_left + (s.border_style.left.len > 0 ? 1 : 0);
	int inset_y = s.pad_top + (s.border_style.top.len > 0 ? 1 : 0);
	return {
		.x = r.x + inset_x + self.cursor_col(),
		.y = r.y + inset_y,
		.has_cursor = true,
		.draw = self.cursor_draw,
		.blink_ms = self.cursor_blink_ms,
		.shape = (int)self.cursor_shape,
		.blink = self.cursor_blink,
		.color = self.cursor_color,
	};
}

// Textarea tracks its caret as a row and column within its own text; the
// layout supplies the origin those are relative to.

fn String Textarea.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	self.height = r.h;
	return self.view();
}

fn int Textarea.measure(&self, int width) @dynamic {
	int lc = self.line_count();
	return lc < 1 ? 1 : lc;
}

fn xray::ContentCursor Textarea.cursor(&self, xray::Rect r) @dynamic {
	if (!self.focused) return {};
	// scroll_offset is the first visible line, so the caret's screen row is
	// its distance from there. Off-screen means no cursor to place.
	int row = self.cursor_row - self.scroll_offset;
	if (row < 0 || row >= r.h) return {};
	return {
		.x = r.x + self.text_offset() + self.cursor_col,
		.y = r.y + row,
		.has_cursor = true,
	};
}
