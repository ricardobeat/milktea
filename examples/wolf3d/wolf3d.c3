module wolf3d;

import milktea;
import xray;
import glaze;
import std::io;
import std::math;
import std::os;

// ── Types ──────────────────────────────────────────────────────────────────

struct Pixel {
	char r, g, b;
}

const sz MAP_WIDTH  = 16;
const sz MAP_HEIGHT = 16;

const char[MAP_WIDTH * MAP_HEIGHT] MAP = {
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 2, 2, 2, 2, 0, 0, 0, 3, 3, 3, 0, 0, 1,
	1, 0, 0, 2, 0, 0, 2, 0, 0, 0, 3, 0, 3, 0, 0, 1,
	1, 0, 0, 2, 0, 0, 2, 0, 0, 0, 3, 0, 3, 0, 0, 1,
	1, 0, 0, 2, 2, 0, 2, 0, 0, 0, 3, 3, 3, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 4, 0, 0, 4, 0, 0, 0, 5, 5, 5, 0, 0, 1,
	1, 0, 0, 4, 0, 0, 4, 0, 0, 0, 5, 0, 5, 0, 0, 1,
	1, 0, 0, 4, 4, 4, 4, 0, 0, 0, 5, 5, 5, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
	};

struct Wolf3D {
	// Camera
	float pos_x, pos_y;
	float dir_x, dir_y;
	float plane_x, plane_y;

	// Viewport
	sz width, height;
	sz tick_count;

	// Rendering buffers
	xray::Cell[] cells;
	Pixel[] pixels;
	float[] depth;

	// Input state
	sz key_w, key_s, key_a, key_d, key_left, key_right;
}

// ── Tea Methods ──────────────────────────────────────────────────────────────

fn milktea::Cmd Wolf3D.init(Wolf3D* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.pos_x = 3.0f;
	self.pos_y = 3.0f;
	self.dir_x = 1.0f;
	self.dir_y = 0.0f;
	self.plane_x = 0.0f;
	self.plane_y = 0.66f;
	self.allocate_buffers();
	return milktea::tick();
}

fn void Wolf3D.allocate_buffers(Wolf3D* self) {
	sz ptotal = (sz)(self.width * self.height * 2);
	self.cells = mem::new_array(xray::Cell, (sz)(self.width * self.height));
	self.pixels = mem::new_array(Pixel, ptotal);
	self.depth = mem::new_array(float, (sz)self.width);
}

fn milktea::Cmd Wolf3D.update(Wolf3D* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		if (self.width == msg.window_size.width && self.height == msg.window_size.height) return null;
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		mem::free(self.cells.ptr);
		mem::free(self.pixels.ptr);
		mem::free(self.depth.ptr);
		self.allocate_buffers();
		return null;
	}

	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg k = msg.key;
		if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'q')) return milktea::quit();

		if (k.code == milktea::KeyCode.RUNE) {
			switch (k.rune) {
				case 'w': self.key_w = self.tick_count;
				case 's': self.key_s = self.tick_count;
				case 'a': self.key_left = self.tick_count;
				case 'd': self.key_right = self.tick_count;
			}
		}
		if (k.code == milktea::KeyCode.LEFT) self.key_left = self.tick_count;
		if (k.code == milktea::KeyCode.RIGHT) self.key_right = self.tick_count;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.tick_count++;

		float move_speed = 0.25f;
		float rot_speed  = 0.12f;
		sz thresh       = self.tick_count - 5;

		if (self.key_w >= thresh) {
			if (MAP[(sz)(self.pos_x + self.dir_x * move_speed) + (sz)(self.pos_y) * MAP_WIDTH]
				== 0) self.pos_x += self.dir_x * move_speed;
			if (MAP[(sz)(self.pos_x) + (sz)(self.pos_y + self.dir_y * move_speed) * MAP_WIDTH]
				== 0) self.pos_y += self.dir_y * move_speed;
			self.key_w = 0;
		}
		if (self.key_s >= thresh) {
			if (MAP[(sz)(self.pos_x - self.dir_x * move_speed) + (sz)(self.pos_y) * MAP_WIDTH]
				== 0) self.pos_x -= self.dir_x * move_speed;
			if (MAP[(sz)(self.pos_x) + (sz)(self.pos_y - self.dir_y * move_speed) * MAP_WIDTH]
				== 0) self.pos_y -= self.dir_y * move_speed;
			self.key_s = 0;
		}
		if (self.key_right >= thresh) {
			float old_dir_x = self.dir_x;
			self.dir_x = self.dir_x * (float)math::cos(rot_speed) - self.dir_y * (float)math::sin(rot_speed);
			self.dir_y = old_dir_x * (float)math::sin(rot_speed) + self.dir_y * (float)math::cos(rot_speed);
			float old_plane_x = self.plane_x;
			self.plane_x = self.plane_x * (float)math::cos(rot_speed) - self.plane_y * (float)math::sin(rot_speed);
			self.plane_y = old_plane_x * (float)math::sin(rot_speed) + self.plane_y * (float)math::cos(rot_speed);
			self.key_right = 0;
		}
		if (self.key_left >= thresh) {
			float old_dir_x = self.dir_x;
			self.dir_x = self.dir_x * (float)math::cos(-rot_speed) - self.dir_y * (float)math::sin(-rot_speed);
			self.dir_y = old_dir_x * (float)math::sin(-rot_speed) + self.dir_y * (float)math::cos(-rot_speed);
			float old_plane_x = self.plane_x;
			self.plane_x = self.plane_x * (float)math::cos(-rot_speed) - self.plane_y * (float)math::sin(-rot_speed);
			self.plane_y = old_plane_x * (float)math::sin(-rot_speed) + self.plane_y * (float)math::cos(-rot_speed);
			self.key_left = 0;
		}

		return milktea::tick();
	}
	return null;
}

fn milktea::Node* Wolf3D.view(Wolf3D* self) @dynamic {
	sz w  = self.width;
	sz h  = self.height;
	sz ph = h * 2;

	// Viewport
	sz width, height;
	sz tick_count;

	// Rendering buffers
	xray::Cell[] cells;
	Pixel[] pixels;
	for (sz x = 0; x < w; x++) {
		for (sz sub = 0; sub < 2; sub++) {
			// 2x horizontal super-sampling
			float camera_x  = 2.0f * ((float)x + (sub == 0 ? 0.25f : 0.75f)) / (float)w - 1.0f;
			float ray_dir_x = self.dir_x + self.plane_x * camera_x;
			float ray_dir_y = self.dir_y + self.plane_y * camera_x;

			sz map_x = (sz)self.pos_x;
			sz map_y = (sz)self.pos_y;

			float side_dist_x, side_dist_y;

			float delta_dist_x = (float)math::abs(1.0f / ray_dir_x);
			float delta_dist_y = (float)math::abs(1.0f / ray_dir_y);
			float perp_wall_dist;

			sz step_x, step_y;
			sz hit = 0;
			sz side;

			if (ray_dir_x < 0) {
				step_x = -1;
				side_dist_x = (self.pos_x - (float)map_x) * delta_dist_x;
			} else {
				step_x = 1;
				side_dist_x = ((float)map_x + 1.0f - self.pos_x) * delta_dist_x;
			}
			if (ray_dir_y < 0) {
				step_y = -1;
				side_dist_y = (self.pos_y - (float)map_y) * delta_dist_y;
			} else {
				step_y = 1;
				side_dist_y = ((float)map_y + 1.0f - self.pos_y) * delta_dist_y;
			}

			while (hit == 0) {
				if (side_dist_x < side_dist_y) {
					side_dist_x += delta_dist_x;
					map_x += step_x;
					side = 0;
				} else {
					side_dist_y += delta_dist_y;
					map_y += step_y;
					side = 1;
				}
				if (MAP[map_x + map_y * MAP_WIDTH] > 0) hit = 1;
			}

			if (side == 0) {
				perp_wall_dist = (side_dist_x - delta_dist_x);
			} else {
				perp_wall_dist = (side_dist_y - delta_dist_y);
			}

			sz line_height = (sz)((float)ph / perp_wall_dist);

			sz draw_start = -line_height / 2 + ph / 2;
			if (draw_start < 0) draw_start = 0;
			sz draw_end = line_height / 2 + ph / 2;
			if (draw_end >= ph) draw_end = ph - 1;

			Pixel color;
			switch (MAP[map_x + map_y * MAP_WIDTH]) {
				case 1: color = (Pixel) { 255, 0, 0 };
				case 2: color = (Pixel) { 0, 255, 0 };
				case 3: color = (Pixel) { 0, 0, 255 };
				case 4: color = (Pixel) { 255, 255, 0 };
				default: color = (Pixel) { 255, 255, 255 };
			}

			if (side == 1) {
				color.r /= 2;
				color.g /= 2;
				color.b /= 2;
			}

			for (sz y = 0; y < ph; y++) {
				sz idx = (sz)(y * w + x);
				Pixel sample_col;
				if (y < draw_start) {
					sample_col = (Pixel) { 40, 40, 40 }; // Ceiling
				} else if (y < draw_end) {
					sample_col = color;
				} else {
					sample_col = (Pixel) { 80, 80, 80 }; // Floor
				}

				if (sub == 0) {
					self.pixels[idx] = sample_col;
				} else {
					self.pixels[idx].r = (char)(((sz)self.pixels[idx].r + (sz)sample_col.r) / 2);
					self.pixels[idx].g = (char)(((sz)self.pixels[idx].g + (sz)sample_col.g) / 2);
					self.pixels[idx].b = (char)(((sz)self.pixels[idx].b + (sz)sample_col.b) / 2);
				}
			}
		}
	}

	for (sz ty = 0; ty < h; ty++) {
		for (sz tx = 0; tx < w; tx++) {
			sz top_idx = (sz)((ty * 2) * w + tx);
			sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
			Pixel top  = self.pixels[top_idx];
			Pixel bot  = self.pixels[bot_idx];
			xray::Style style = xray::default_style().set_fg(xray::color_rgb(top.r, top.g, top.b))
				.set_bg(xray::color_rgb(bot.r, bot.g, bot.b));
			self.cells[ty * w + tx] = xray::new_cell("\xe2\x96\x80", 1, style);
		}
	}

	return milktea::grid(self.cells, w, h);
}

fn int main(String[] args) {
	Wolf3D* app = mem::new(Wolf3D);
	if (catch err = milktea::@run_program(app, { .alt_screen = true })) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}