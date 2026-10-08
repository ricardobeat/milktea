module milktea;

import std::core::mem;
import glaze;
import xray;

// Tree layout. A view is a tree of nodes, which the runtime solves against the
// screen and paints at the coordinates the solver chose:
//
//   fn milktea::Node* Model.view(&self) @dynamic {
//       return milktea::vstack()
//           .add(milktea::text("Title", title_s))
//           .add(milktea::text(self.body, body_s).fill(1));
//   }
//
// A whole screen built as one glaze string is a tree of one: text(s). A frame
// drawn cell by cell is canvas(buf) or grid(cells, w, h).

// Re-exports, so an app needs to import only milktea and glaze.
alias Node           = xray::Node;
alias Rect           = xray::Rect;
// Content is aliased for reference and parameter types. Declaring that a
// struct implements it still needs the xray name — `struct Foo (xray::Content)`
// — because c3c 0.8.3 does not resolve an alias in an implements-list.
alias Content        = xray::Content;
alias ContentCursor  = xray::ContentCursor;
alias Shadow         = xray::Shadow;
alias InnerShadow    = xray::InnerShadow;
alias Constraint     = xray::Constraint;

// component wraps anything implementing Content as a leaf node. Every boba
// component has its own node() — .add(self.list.node()) — so this is for
// content types an app defines itself.
alias component = xray::content_node;

alias root    = xray::root;
alias vstack  = xray::vstack;
alias hstack  = xray::hstack;
alias zstack  = xray::zstack;
alias shadow  = xray::shadow;
alias inner_shadow = xray::inner_shadow;

// Sizing constraints, re-exported so .with_height(cells(1)) needs no xray prefix.
alias cells    = xray::cells;
alias fill     = xray::fill;
alias percent  = xray::percent;
alias min      = xray::min;
alias max      = xray::max;
alias fit      = xray::fit;

// Alignment constants, named for what they do to a node rather than for the
// axis they act on.
const xray::JustifyContent START   = xray::JustifyContent.JUSTIFY_START;
const xray::JustifyContent CENTER  = xray::JustifyContent.JUSTIFY_CENTER;
const xray::JustifyContent END     = xray::JustifyContent.JUSTIFY_END;
const xray::JustifyContent BETWEEN = xray::JustifyContent.JUSTIFY_SPACE_BETWEEN;
const xray::JustifyContent AROUND  = xray::JustifyContent.JUSTIFY_SPACE_AROUND;
const xray::JustifyContent EVENLY  = xray::JustifyContent.JUSTIFY_SPACE_EVENLY;

const xray::AlignItems STRETCH      = xray::AlignItems.ALIGN_STRETCH;
const xray::AlignItems ALIGN_START  = xray::AlignItems.ALIGN_START;
const xray::AlignItems ALIGN_CENTER = xray::AlignItems.ALIGN_CENTER;
const xray::AlignItems ALIGN_END    = xray::AlignItems.ALIGN_END;

// StyledText is the bridge between the tree and glaze: it holds a style and a
// string, and renders them at whatever size the layout settled on. Sizing at
// paint time rather than build time is what makes .fill(1) meaningful on a
// bordered box — the border is drawn around the final rect, not around the
// text's own width.
struct StyledText (xray::Content) @private {
	glaze::Style style;
	String text;
	bool plain;
}

fn String StyledText.render(&self, xray::Rect r) @dynamic {
	if (self.plain) return self.text;
	return self.style.with_width(r.w).with_height(r.h).render(self.text);
}

// measure and measure_width report what the text needs before layout has
// picked a size: its own extent plus whatever the style frames it with. They
// are consulted for a centered modal and under draw_inline, where nothing
// else fixes that axis.
//
// A style carrying an explicit size names the answer outright: render() sizes
// the box to it, so measuring the text instead would hand the node a rect
// smaller than what it paints.
fn sz StyledText.measure(&self, sz width) @dynamic {
	if (self.style.height > 0) return self.style.height;
	sz lines = 1;
	foreach (c : self.text) if (c == '\n') lines++;
	return lines + frame_height(self.style);
}

fn sz StyledText.measure_width(&self, sz height) @dynamic {
	if (self.style.width > 0) return self.style.width;
	sz widest = 0;
	usz start = 0;
	for (usz i = 0; i <= self.text.len; i++) {
		if (i < self.text.len && self.text[i] != '\n') continue;
		sz w = glaze::string_width(self.text[start:i - start]);
		if (w > widest) widest = w;
		start = i + 1;
	}
	return widest + frame_width(self.style);
}

// text puts a string in the tree, styled by `style` (plain by default).
//
// Unstyled, the string is painted as it is, escapes and all, rather than
// fitted to the rect: a screen built with glaze already has its own shape.
fn Node* text(String s, glaze::Style style = {}) {
	StyledText* st = mem::tnew(StyledText);
	st.style = style;
	st.text = s;
	glaze::Style plain = {};
	st.plain = mem::equals(&style, &plain, glaze::Style::size);
	return xray::content_node(st);
}

// Grid is a cell grid owned by the caller, painted into the tree as it is.
struct Grid (xray::Content) @private {
	xray::Cell[] cells;
	sz w, h;
	xray::ContentCursor cursor_at;
}

fn void Grid.paint(&self, xray::ScreenBuffer* dst, xray::Rect r) @dynamic {
	dst.put_cells(self.cells, self.w, self.h, r);
}

fn sz Grid.measure(&self, sz width) @dynamic => self.h;
fn sz Grid.measure_width(&self, sz height) @dynamic => self.w;

fn xray::ContentCursor Grid.cursor(&self, xray::Rect r) @dynamic {
	if (!self.cursor_at.has_cursor) return {};
	xray::ContentCursor c = self.cursor_at;
	c.x += r.x;
	c.y += r.y;
	return c;
}

// canvas puts a ScreenBuffer's cells in the tree: a frame drawn cell by cell,
// such as a game's. `cursor`, if it has one, is relative to the buffer's top
// left. The buffer must outlive the frame; the usual owner is the model.
fn Node* canvas(xray::ScreenBuffer* buf, ContentCursor cursor = {}) {
	return grid(buf.cells, buf.width, buf.height, cursor);
}

// grid is canvas for a cell slice the caller allocated itself, `w` cells wide
// and `h` tall.
fn Node* grid(xray::Cell[] cells, sz w, sz h, ContentCursor cursor = {}) {
	Grid* g = mem::tnew(Grid);
	*g = { .cells = cells, .w = w, .h = h, .cursor_at = cursor };
	return xray::content_node(g);
}

// draw solves the tree against the whole terminal and paints it.
fn View draw(Node* root) @private {
	return draw_in(root, screen_width(), screen_height());
}

// draw_inline sizes the tree to its content height, so the painted block is
// only as tall as the tree needs. The block is capped at the terminal height:
// taller than that cannot be addressed relatively without scrolling.
fn View draw_inline(Node* root) @private {
	sz w = screen_width();
	sz h = root != null ? root.natural_height(w) : 0;
	if (h < 1) h = 1;
	if (h > screen_height()) h = screen_height();
	return draw_in(root, w, h);
}

fn View draw_in(Node* root, sz w, sz h) @local {
	// The painted grid lives on the Program so it can be reused across frames
	// and freed when the program stops. A view is rebuilt on every keystroke;
	// a fresh grid each time would churn the heap.
	if (root == null || w < 1 || h < 1 || g_program == null) return view("");

	if (g_program.draw_buf == null) {
		g_program.draw_buf = xray::new_screen_buffer((sz)w, (sz)h);
	} else if (g_program.draw_buf.width != (sz)w || g_program.draw_buf.height != (sz)h) {
		g_program.draw_buf.resize((sz)w, (sz)h);
	}
	xray::ScreenBuffer* buf = g_program.draw_buf;
	buf.clear();

	root.solve(xray::new_rect(0, 0, w, h));
	xray::PaintResult res = buf.paint(root, &g_program.draw_scratch, frame_ms());

	// Mouse hit-testing wants this frame's geometry, not last frame's — clear
	// and refill every draw() so a click always lands against what is
	// actually on screen right now.
	g_program.click_target_count = 0;
	xray::collect_click_targets(root, g_program.click_targets[..], &g_program.click_target_count);

	View v = {
		.cells        = buf.cells,
		.cells_width  = (sz)w,
		.cells_height = (sz)h,
	};
	// A drawn cursor is already in the grid, so the terminal cursor stays
	// hidden — showing both would put two cursors on screen.
	if (res.cursor.has_cursor && res.cursor.draw == null) {
		v = v.set_cursor_shape(res.cursor.x, res.cursor.y,
			(CursorShape)res.cursor.shape, res.cursor.blink);
		if (res.cursor.color.len > 0) v = v.set_cursor_color(res.cursor.color);
	}
	// A node that animates asks to be painted again rather than making the
	// app run a timer for it; the tree's soonest request becomes the view's.
	v.repaint_ms = res.repaint_ms;
	return v;
}
