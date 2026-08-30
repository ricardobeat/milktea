module milktea;

import std::core::mem;
import glaze;
import xray;

// Tree layout. A view is built as a tree of nodes, solved against the screen,
// then painted at the coordinates the solver chose:
//
//   fn milktea::View Model.view(&self) @dynamic {
//       return milktea::draw(milktea::root()
//           .add(milktea::vstack()
//               .add(milktea::text(title_s, "Title").with_height(1))
//               .add(milktea::text(body_s, self.body).fill(1))));
//   }
//
// The string-building API (glaze::join_vertical over rects) still works and is
// the better fit for simple stacked output. Use a tree when pieces overlap,
// when nesting gets deep, or when a component should size itself.

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
alias at_least = xray::at_least;
alias at_most  = xray::at_most;

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
struct StyledText (xray::Content) {
	glaze::Style style;
	String text;
}

fn String StyledText.render(&self, xray::Rect r) @dynamic {
	return self.style.with_width(r.w).with_height(r.h).render(self.text);
}

// measure and measure_width report what the text needs before layout has
// picked a size: its own extent plus whatever the style frames it with. They
// are consulted for a centered modal and under draw_inline, where nothing
// else fixes that axis.
fn int StyledText.measure(&self, int width) @dynamic {
	int lines = 1;
	foreach (c : self.text) if (c == '\n') lines++;
	return lines + frame_height(self.style);
}

fn int StyledText.measure_width(&self, int height) @dynamic {
	int widest = 0;
	usz start = 0;
	for (usz i = 0; i <= self.text.len; i++) {
		if (i < self.text.len && self.text[i] != '\n') continue;
		int w = glaze::string_width(self.text[start:i - start]);
		if (w > widest) widest = w;
		start = i + 1;
	}
	return widest + frame_width(self.style);
}

// text puts a styled string in the tree.
fn Node* text(glaze::Style style, String s) {
	StyledText* st = mem::tnew(StyledText);
	st.style = style;
	st.text = s;
	return xray::content_node(st);
}

// draw solves the tree against the whole terminal and paints it.
fn View draw(Node* root) {
	return draw_in(root, screen_width(), screen_height(), true);
}

// draw_inline sizes the tree to its content and paints it below whatever is
// already on screen, leaving the user's scrollback alone. The block is capped
// at the terminal height: taller than that cannot be addressed relatively
// without scrolling.
fn View draw_inline(Node* root) {
	int w = screen_width();
	int h = root != null ? root.natural_height(w) : 0;
	if (h < 1) h = 1;
	if (h > screen_height()) h = screen_height();
	return draw_in(root, w, h, false);
}

fn View draw_in(Node* root, int w, int h, bool alt) @local {
	// The painted grid lives on the Program so it can be reused across frames
	// and freed when the program stops. A view is rebuilt on every keystroke;
	// a fresh grid each time would churn the heap.
	if (root == null || w < 1 || h < 1 || g_program == null) return new_view("");

	if (g_program.draw_buf == null) {
		g_program.draw_buf = xray::new_screen_buffer((sz)w, (sz)h);
	} else if (g_program.draw_buf.width != (sz)w || g_program.draw_buf.height != (sz)h) {
		g_program.draw_buf.resize((sz)w, (sz)h);
	}
	xray::ScreenBuffer* buf = g_program.draw_buf;
	buf.clear();

	root.solve(xray::new_rect(0, 0, w, h));
	xray::PaintResult res = buf.paint(root, &g_program.draw_scratch, (long)time_ms());

	// Mouse hit-testing wants this frame's geometry, not last frame's — clear
	// and refill every draw() so a click always lands against what is
	// actually on screen right now.
	g_program.click_target_count = 0;
	xray::collect_click_targets(root, g_program.click_targets[..], &g_program.click_target_count);

	View v = {
		.cells        = buf.cells,
		.cells_width  = (sz)w,
		.cells_height = (sz)h,
		.alt_screen   = alt,
	};
	// A drawn cursor is already in the grid, so the terminal cursor stays
	// hidden — showing both would put two cursors on screen.
	if (res.cursor.has_cursor && res.cursor.draw == null) {
		v = v.set_cursor_shape(res.cursor.x, res.cursor.y,
			(CursorShape)res.cursor.shape, res.cursor.blink);
		if (res.cursor.color.len > 0) v = v.set_cursor_color(res.cursor.color);
	}
	// A node that animates asks to be painted again rather than making the
	// app run a timer for it. Cancel first: view() runs every frame, so
	// without it each frame would leave another timer behind. The buffer
	// doubles as the owner token — one draw tree, one repaint timer.
	cancel(buf);
	if (res.repaint_ms > 0) {
		// every(), not tick(): the deadline is snapped to the next multiple of
		// the interval in absolute time, so the frame this arms lands on the
		// same grid as the last one. tick() would wait the full interval from
		// *now*, adding however long this frame took to every period — a rate
		// that sags under load and drifts out of step with the terminal's own
		// refresh. The repaint is re-armed from scratch each frame, so the
		// snapping is what keeps successive frames evenly spaced.
		every((sz)res.repaint_ms, &tick_msg, buf);
	}
	return v;
}
