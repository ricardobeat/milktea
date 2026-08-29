module milktea;

import glaze;
import xray;

// The bridge between a glaze style and the geometry a layout works in. glaze
// describes how text is framed — border, padding — and xray places things in
// rects; neither knows about the other, so the conversion lives here.

// content_rect is where a style's text actually starts inside its rect: past
// the border, if any, and then the padding. Content that owns a caret uses it
// so that changing a border or padding cannot leave the cursor on top of one.
fn xray::Rect content_rect(glaze::Style s, xray::Rect r) {
	return r.inset(
		s.pad_left + (s.border.left.len > 0 ? 1 : 0),
		s.pad_top + (s.border.top.len > 0 ? 1 : 0),
		s.pad_right + (s.border.right.len > 0 ? 1 : 0),
		s.pad_bottom + (s.border.bottom.len > 0 ? 1 : 0));
}

// frame_height and frame_width are the rows and columns a style spends on its
// own border and padding, before any content. Content adds these to its text
// size to say how big it wants to be.
fn int frame_height(glaze::Style s) {
	int n = s.pad_top + s.pad_bottom;
	if (s.border.top.len > 0) n++;
	if (s.border.bottom.len > 0) n++;
	return n;
}

fn int frame_width(glaze::Style s) {
	int n = s.pad_left + s.pad_right;
	if (s.border.left.len > 0) n++;
	if (s.border.right.len > 0) n++;
	return n;
}

// to_cell_color converts a glaze color into the one xray paints with. An app
// picks colors in glaze terms — that is where a palette lives — but effects
// that xray draws, such as a node's drop shadow, take an xray color.
//
// Only a truecolor value carries rgb; anything else has no rgb to give, so it
// becomes the default and lets the effect use its own.
fn xray::Color to_cell_color(glaze::Color c) {
	if (c.kind != glaze::ColorKind.TRUECOLOR) return {};
	return xray::color_rgb(c.r, c.g, c.b);
}

// CursorStyle is re-exported so a component can hold one without naming xray.
alias CursorStyle = xray::CursorStyle;
alias place_cursor = xray::place_cursor;
