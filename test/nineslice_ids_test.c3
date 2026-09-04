module nineslice_ids_test;
import nineslice;

// Every tile of a radius must map to a distinct frame inside the glyph's
// reserved range. A collision or overflow here is silent at runtime.
fn void test_ring_frames_unique_and_in_range() @test {
	for (int rad = 0; rad < nineslice::RADII; rad++) {
		int k = nineslice::radius_cells(nineslice::radius_px(rad));
		assert(k <= nineslice::MAX_K, "radius %d needs k=%d > MAX_K", rad, k);
		int body = nineslice::body_rows(k);
		int n = nineslice::tile_count_rows(k, body);
		bool[64] seen;

		int[4] corners = { nineslice::SLOT_TL, nineslice::SLOT_TR,
		                   nineslice::SLOT_BL, nineslice::SLOT_BR };
		for (int c = 0; c < 4; c++) {
			for (int oy = 0; oy < k; oy++) {
				for (int ox = 0; ox < k; ox++) {
					int f = nineslice::tile_index(k, corners[c], ox, oy);
					assert(f >= 0 && f < n, "corner frame %d outside %d", f, n);
					assert(!seen[f], "duplicate corner frame %d", f);
					seen[f] = true;
				}
			}
		}
		for (int oy = 0; oy < k; oy++) {
			for (int w = 0; w < 2; w++) {
				int f = nineslice::hrun_tile_index(k, oy, w == 1);
				assert(f >= 0 && f < n, "hrun frame %d outside %d", f, n);
				assert(!seen[f], "duplicate hrun frame %d", f);
				seen[f] = true;
			}
		}
		for (int row = 0; row < body; row++) {
			for (int which = 0; which < 3; which++) {
				int f = nineslice::row_tile_index(k, row, which);
				assert(f >= 0 && f < n, "row frame %d outside %d", f, n);
				assert(!seen[f], "duplicate row frame %d", f);
				seen[f] = true;
			}
		}
	}
}

// The glyph a box registers must hold the layout the view indexes it with.
// The builder and the view each derive k independently; if they disagree the
// view asks a k=1 layout for indices holding k=2 tiles, the ids resolve to no
// image, and the terminal draws the placeholder codepoint and its diacritics
// as literal combining marks over every cell.
//
// This drives the real Model through init and a radius sweep, so it fails if
// either side stops clamping -- not just if the clamp function is wrong.
fn void test_glyph_layout_matches_view() @test {
	int box_h = nineslice::BODY_ROWS + 2;
	for (int raw = 0; raw < nineslice::RADII; raw++) {
		// What the view will draw with.
		int view_rad = nineslice::effective_radius(raw, box_h);
		int view_k = nineslice::radius_cells(nineslice::radius_px(view_rad));

		// What sync_ring builds: it must clamp identically, and the tile
		// count it reserves must cover every index the view can ask for.
		int build_rad = nineslice::effective_radius(raw, box_h);
		int build_k = nineslice::radius_cells(nineslice::radius_px(build_rad));
		int n = nineslice::tile_count_rows(build_k, nineslice::body_rows(build_k));

		assert(view_k == build_k,
			"radius %d: view draws k=%d but glyph holds k=%d", raw, view_k, build_k);
		assert(2 * view_k < box_h,
			"radius %d: k=%d does not fit box height %d", raw, view_k, box_h);

		// Highest index the view can request for this layout.
		int body = nineslice::body_rows(view_k);
		int hi = nineslice::row_tile_index(view_k, body - 1, 2);
		assert(hi < n, "radius %d: view wants index %d, glyph holds %d", raw, hi, n);
	}
}
