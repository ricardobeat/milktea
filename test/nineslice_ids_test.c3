module nineslice_ids_test;
import nineslice;

// Every tile of every radius must map to a distinct frame inside the glyph's
// reserved range. A collision here is what made later boxes render an earlier
// box's gradient, and it is silent at runtime.
fn void test_ring_frames_unique_and_in_range() @test {
	int cap = nineslice::RADII * nineslice::FRAMES_PER_RADIUS;
	bool[1024] seen;
	for (int rad = 0; rad < nineslice::RADII; rad++) {
		int k = nineslice::radius_cells(nineslice::radius_px(rad));
		assert(k <= nineslice::MAX_K, "radius %d needs k=%d > MAX_K", rad, k);
		int body = nineslice::body_rows(k);
		int n = nineslice::tile_count_rows(k, body);
		assert(n <= nineslice::FRAMES_PER_RADIUS, "%d tiles > FRAMES_PER_RADIUS", n);

		// Corner blocks and the two horizontal runs.
		int[4] corners = { nineslice::SLOT_TL, nineslice::SLOT_TR,
		                   nineslice::SLOT_BL, nineslice::SLOT_BR };
		for (int c = 0; c < 4; c++) {
			for (int oy = 0; oy < k; oy++) {
				for (int ox = 0; ox < k; ox++) {
					int f = rad * nineslice::FRAMES_PER_RADIUS
						+ nineslice::tile_index(k, corners[c], ox, oy);
					assert(f >= 0 && f < cap, "frame %d out of range", f);
					assert(!seen[f], "duplicate corner frame %d", f);
					seen[f] = true;
				}
			}
		}
		// Horizontal runs: one tile per corner row, top and bottom.
		for (int oy = 0; oy < k; oy++) {
			for (int w = 0; w < 2; w++) {
				int f = rad * nineslice::FRAMES_PER_RADIUS
					+ nineslice::hrun_tile_index(k, oy, w == 1);
				assert(f >= 0 && f < cap, "hrun frame %d out of range", f);
				assert(!seen[f], "duplicate hrun frame %d", f);
				seen[f] = true;
			}
		}
		// Per-body-row left / centre / right.
		for (int row = 0; row < body; row++) {
			for (int which = 0; which < 3; which++) {
				int f = rad * nineslice::FRAMES_PER_RADIUS
					+ nineslice::row_tile_index(k, row, which);
				assert(f >= 0 && f < cap, "row frame %d out of range", f);
				assert(!seen[f], "duplicate row frame %d", f);
				seen[f] = true;
			}
		}
	}
}
