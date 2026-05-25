module space_example;

import milktea;
import xray;
import glaze;
import std::io;
import std::core::string;

extern fn int rand();
extern fn void srand(uint seed);
extern fn long c3_time_ms_long();


struct SpaceModel {
	int frame;
	int width;
	int height;
	char* color_r;
	char* color_g;
	char* color_b;
	bool matrix_init;
	// Cell grid for direct rendering
	xray::Cell[] view_cells;
}

fn milktea::Cmd SpaceModel.init(SpaceModel* self) @dynamic {
	ulong seed = (ulong)c3_time_ms_long();
	srand((uint)seed);
	return milktea::tick(16);
}


// Pre-compute color matrix: grayscale gradient, brighter near top.
// Matches Go version: baseValue = ((height-y)/height)^2 with random offset.
fn void SpaceModel.compute_colors(SpaceModel* self) {
	sz total = (sz)self.width * (sz)self.height * 2;
	if (self.color_r == null) {
		self.color_r = mem::new_array(char, total);
		self.color_g = mem::new_array(char, total);
		self.color_b = mem::new_array(char, total);
	}
	int pixel_rows = self.height * 2;
	for (int y = 0; y < pixel_rows; y++) {
		for (int x = 0; x < self.width; x++) {
			// Squared gradient: top is brightest (1.0), bottom is darkest (0.0)
			double randomness_factor = (double)(pixel_rows - y) / (double)pixel_rows;
			double base_value        = randomness_factor * randomness_factor;

			// Random per-pixel offset (-0.1 to +0.1)
			double random_offset = ((double)rand() / 2147483647.0) * 0.2 - 0.1;
			double val           = base_value + random_offset;
			if (val < 0.0) val = 0.0;
			if (val > 1.0) val = 1.0;
			char v = (char)(val * 255.0);
			sz idx = (sz)y * (sz)self.width + (sz)x;
			self.color_r[idx] = v;
			self.color_g[idx] = v;
			self.color_b[idx] = v;
		}
	}
	self.matrix_init = true;

	// Allocate cell grid
	mem::free(self.view_cells.ptr);
	sz cells_total = (sz)self.width * (sz)self.height;
	self.view_cells = mem::new_array(xray::Cell, cells_total);
}

fn milktea::Cmd SpaceModel.update(SpaceModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		self.compute_colors();
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.frame++;
		return milktea::tick(16);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View SpaceModel.view(SpaceModel* self) @dynamic {
	if (self.width == 0 || self.height == 0) return milktea::new_view("");
	if (!self.matrix_init) self.compute_colors();

	int w      = self.width;
	int h      = self.height;
	int frame  = self.frame;
	int view_h = h;

	xray::Style base_style = xray::default_style();

	for (int vy = 0; vy < view_h; vy++) {
		int fire_y     = vy * 2;
		int next_y     = fire_y + 1;
		int pixel_rows = h * 2;
		int row_offset = vy * w;
		for (int vx = 0; vx < w; vx++) {
			int xi = ((vx + frame) % w + w) % w;
			sz idx = (sz)fire_y * (sz)w + (sz)xi;

			char tr = self.color_r[idx];
			char tg = self.color_g[idx];
			char tb = self.color_b[idx];

			char br, bg, bb;
			if (next_y < pixel_rows) {
				sz bidx = (sz)next_y * (sz)w + (sz)xi;
				br = self.color_r[bidx];
				bg = self.color_g[bidx];
				bb = self.color_b[bidx];
			} else {
				br = tr;
				bg = tg;
				bb = tb;
			}

			xray::Cell c;
			c.content[0] = 0xe2;
			c.content[1] = 0x96;
			c.content[2] = 0x80;
			c.content_len = 3;
			c.width = 1;
			c.style = base_style.set_fg(xray::color_rgb(tr, tg, tb)).set_bg(xray::color_rgb(br, bg, bb));
			self.view_cells[row_offset + vx] = c;
		}
	}

	return milktea::new_alt_cell_view(self.view_cells, (sz)w, (sz)view_h);
}

fn int main() {
	SpaceModel* m = mem::new(SpaceModel);
	if (catch err = milktea::@run_program(m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	io::printn("Bye!");
	return 0;
}