module nineslice_ids_test;
import nineslice;

// Every tile of a radius must map to a distinct frame inside the glyph's
// reserved range. A collision or overflow here is silent at runtime.
fn void test_ring_frames_unique_and_in_range() @test {
	for (int rad = 0; rad < nineslice::RADII; rad++) {
		int ky = nineslice::radius_cells_y(nineslice::radius_px(rad));
		int kx = nineslice::radius_cells_x(nineslice::radius_px(rad));
		assert(ky <= nineslice::MAX_KY, "radius %d needs ky=%d > MAX_KY", rad, ky);
		int body = nineslice::body_rows(ky);
		int n = nineslice::tile_count_rows(kx, ky, body);
		bool[64] seen;

		int[4] corners = { nineslice::SLOT_TL, nineslice::SLOT_TR,
		                   nineslice::SLOT_BL, nineslice::SLOT_BR };
		for (int c = 0; c < 4; c++) {
			for (int oy = 0; oy < ky; oy++) {
				for (int ox = 0; ox < kx; ox++) {
					int f = nineslice::tile_index(kx, ky, corners[c], ox, oy);
					assert(f >= 0 && f < n, "corner frame %d outside %d", f, n);
					assert(!seen[f], "duplicate corner frame %d", f);
					seen[f] = true;
				}
			}
		}
		for (int oy = 0; oy < ky; oy++) {
			for (int w = 0; w < 2; w++) {
				int f = nineslice::hrun_tile_index(kx, ky, oy, w == 1);
				assert(f >= 0 && f < n, "hrun frame %d outside %d", f, n);
				assert(!seen[f], "duplicate hrun frame %d", f);
				seen[f] = true;
			}
		}
		for (int row = 0; row < body; row++) {
			for (int which = 0; which < 3; which++) {
				int f = nineslice::row_tile_index(kx, ky, row, which);
				assert(f >= 0 && f < n, "row frame %d outside %d", f, n);
				assert(!seen[f], "duplicate row frame %d", f);
				seen[f] = true;
			}
		}
	}
}

// The glyph a box registers must hold the layout the view indexes it with.
// The builder and the view each derive the corner size independently; if they
// disagree the view asks a kx=1 layout for indices holding kx=2 tiles, the ids
// resolve to no image, and the terminal draws the placeholder codepoint and
// its diacritics as literal combining marks over every cell.
fn void test_glyph_layout_matches_view() @test {
	int box_h = nineslice::BOX_H;
	for (int raw = 0; raw < nineslice::RADII; raw++) {
		int rad = nineslice::effective_radius(raw, box_h);
		int kx = nineslice::radius_cells_x(nineslice::radius_px(rad));
		int ky = nineslice::radius_cells_y(nineslice::radius_px(rad));
		int body = nineslice::body_rows(ky);
		int n = nineslice::tile_count_rows(kx, ky, body);

		// Corners must not overlap vertically...
		assert(2 * ky <= box_h,
			"radius %d: ky=%d does not fit box height %d", raw, ky, box_h);
		// ...and the box keeps its full text area: a cell is twice as tall as
		// it is wide, so a radius wide enough to need two cells across still
		// needs only one down. That is the whole point -- a bigger radius
		// must not cost the box a row.
		assert(body == box_h - 2 * ky, "radius %d: body %d unexpected", raw, body);

		// Every index the view can request must exist in the glyph.
		int hi = nineslice::row_tile_index(kx, ky, body - 1, 2);
		assert(hi < n, "radius %d: view wants index %d, glyph holds %d", raw, hi, n);
	}
}

// The full declared radius range must actually be reachable: a radius the
// clamp silently walks down is a radius the demo cannot show.
fn void test_full_radius_range_reachable() @test {
	int box_h = nineslice::BOX_H;
	for (int raw = 0; raw < nineslice::RADII; raw++) {
		assert(nineslice::effective_radius(raw, box_h) == raw,
			"radius index %d (%dpx) is clamped away", raw, nineslice::radius_px(raw));
	}
}

// A selected box's ring is rebuilt with the selection border, so the glyph
// cache must key on selection as well as radius -- otherwise selecting a box
// reuses the unselected ring and the border never appears.
fn void test_selection_changes_style() @test {
	nineslice::BoxStyle plain = nineslice::style_of(0, false);
	nineslice::BoxStyle sel = nineslice::style_of(0, true);
	assert(plain.line != sel.line || plain.line_w != sel.line_w,
		"selection does not change the border style");
	assert(sel.stroke == nineslice::STROKE_INSET, "selection border must be inset");
	// The fill is untouched: selection changes the border, not the box.
	assert(plain.bg == sel.bg && plain.bg2 == sel.bg2 && plain.grad == sel.grad,
		"selection must not change the fill");
}
