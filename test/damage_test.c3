module damage_test;

import xray;
import std::core::mem;

fn void test_changed_cells_reuses_native_diff_and_tracks_wide_glyphs() @test {
	xray::ScreenBuffer* screen = xray::new_screen_buffer(8, 2);
	defer { screen.destroy(); mem::free(screen); }
	sz[16] indices;
	assert(screen.changed_cells(indices[..]) == 16);
	screen.swap();
	assert(screen.changed_cells(indices[..]) == 0);

	screen.set_string(2, 0, "A", xray::default_style());
	assert(screen.changed_cells(indices[..]) == 1);
	assert(indices[0] == 2);
	screen.swap();
	screen.set_string(2, 0, "A", xray::default_style());
	assert(screen.changed_cells(indices[..]) == 0);

	screen.set_string(2, 0, "界", xray::default_style());
	assert(screen.changed_cells(indices[..]) == 2);
	assert(indices[0] == 2 && indices[1] == 3);
	screen.swap();
	screen.clear();
	assert(screen.changed_cells(indices[..]) == 2);
	assert(indices[0] == 2 && indices[1] == 3);
	screen.swap();

	screen.resize(4, 4);
	assert(screen.full_redraw);
	assert(screen.changed_cells(indices[..]) == 16);
}
