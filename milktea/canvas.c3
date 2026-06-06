module milktea;

import std::core::mem;
import xray;
import glaze;

// new_cell_view creates an alt-screen View backed by a direct xray::Cell grid.
// The grid is temp-allocated (via mem::talloc_array) and initialised to
// xray::empty_cell() so every slot renders as a plain space with no style.
//
// Because view() is called inside @pool() in render_current_view, the
// temp allocation is automatically reclaimed at the end of each frame — no
// explicit free needed. Do not call new_cell_view outside a @pool() context.
fn View new_cell_view(int w, int h) {
	sz total = (sz)w * (sz)h;
	// Use the temp allocator so the grid is freed automatically at the end of
	// the enclosing @pool() block (which wraps render_current_view). This
	// prevents one Cell-grid leak per frame when view() rebuilds it every call.
	xray::Cell* ptr = mem::talloc_array(xray::Cell, total);
	xray::Cell empty = xray::empty_cell();
	for (sz i = 0; i < total; i++) {
		ptr[i] = empty;
	}
	return {
		.cells        = ptr[:total],
		.cells_width  = (sz)w,
		.cells_height = (sz)h,
		.alt_screen   = true,
	};
}

// View.draw renders styled content into the view's cell grid at the position
// and dimensions given by rect.
//
// Steps:
//   1. Calls style.render_in(rect, content) to obtain an ANSI-encoded string
//      sized to rect.w x rect.h. (render_in is provided by glaze::Style.)
//   2. Allocates a temporary ScreenBuffer of exactly (rect.w, rect.h), parses
//      the ANSI string into it, then copies each resulting cell into the view's
//      backing grid at position (rect.x + col, rect.y + row).
//
// The method uses a value receiver and returns a copy of self so calls can be
// chained:
//
//   return new_cell_view(w, h)
//       .draw(header_rect, title_style, "My App")
//       .draw(body_rect,   body_style,  body_text);
//
// All chained draw() calls share the same underlying cell grid because the slice
// header (cells.ptr) points to the same backing array across copies.
fn View View.draw(self, xray::Rect rect, glaze::Style style, String content) {
	View v = self;

	// Guard: nothing to do if the grid is uninitialised or rect is degenerate.
	if (v.cells.ptr == null || rect.w <= 0 || rect.h <= 0) return v;
	if (rect.x < 0 || rect.y < 0) return v;
	if ((sz)rect.x >= v.cells_width || (sz)rect.y >= v.cells_height) return v;

	// Render styled ANSI into a string sized to the rect.
	String ansi = style.render_in(rect, content);
	if (ansi.len == 0) return v;

	// Parse the ANSI string into a rect-sized scratch ScreenBuffer, then copy
	// the resulting cells into the view grid at (rect.x, rect.y).
	//
	// new_screen_buffer/blit_ansi is the proven path (used by overlay_char and
	// blit_ansi) — it handles SGR 256-color and truecolor correctly via the
	// existing apply_sgr parser without reimplementing it here.
	xray::ScreenBuffer* tmp = xray::new_screen_buffer((sz)rect.w, (sz)rect.h);
	defer {
		tmp.destroy();
		mem::free(tmp);
	}

	tmp.render_ansi_string(0, 0, ansi, xray::default_style());

	// Copy cells from the scratch buffer into the view grid.
	sz cw = v.cells_width;
	sz ch = v.cells_height;
	for (sz row = 0; row < (sz)rect.h; row++) {
		sz dst_row = (sz)rect.y + row;
		if (dst_row >= ch) break;
		for (sz col = 0; col < (sz)rect.w; col++) {
			sz dst_col = (sz)rect.x + col;
			if (dst_col >= cw) break;
			v.cells[dst_row * cw + dst_col] = tmp.cells[row * (sz)rect.w + col];
		}
	}

	return v;
}
