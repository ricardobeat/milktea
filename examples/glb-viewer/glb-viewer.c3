module glb_viewer;

import milktea;
import xray;
import glaze;
import glb;
import std::io;
import std::math;
import std::os;
import std::core::dstring;
import std::core::string;

// ── Tea model callbacks ──────────────────────────────────────────────────────

fn milktea::Cmd glb::GlbModel.init(glb::GlbModel* self) @dynamic {
	milktea::Cmd[] cmds = { milktea::tick() };
	return milktea::batch(cmds);
}

fn milktea::Cmd glb::GlbModel.update(glb::GlbModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		self.resize(self.width, self.height);
		return null;
	}
	return null;
}

fn milktea::View glb::GlbModel.view(glb::GlbModel* self) @dynamic {
	self.render();

	int w  = self.width;
	int h  = self.height;
	int ph = h * 2;

	// Combine pixel buffer into half-block cells
	xray::Cell[] cells = mem::new_array(xray::Cell, (sz)(w * h));
	defer mem::free(cells.ptr);

	for (sz i = 0; i < (sz)(w * h); i++) cells[i] = xray::empty_cell();
	for (int ty = 0; ty < h; ty++) {
		for (int tx = 0; tx < w; tx++) {
			sz top_idx = (sz)((ty * 2) * w + tx);
			sz bot_idx = (sz)((ty * 2 + 1) * w + tx);
			bool top_filled = self.depth[top_idx] < 999.0f;
			bool bot_filled = self.depth[bot_idx] < 999.0f;
			if (!top_filled && !bot_filled) continue;
			glb::Pixel top = self.pixels[top_idx];
			glb::Pixel bot = self.pixels[bot_idx];
			sz cidx = (sz)(ty * w + tx);
			xray::Color fg_col = top_filled ? xray::color_rgb(top.r, top.g, top.b) : xray::color_rgb(0, 0, 0);
			xray::Color bg_col = bot_filled ? xray::color_rgb(bot.r, bot.g, bot.b) : xray::color_rgb(0, 0, 0);
			xray::Style style = xray::default_style().set_fg(fg_col).set_bg(bg_col);
			cells[cidx] = xray::new_cell("\xe2\x96\x80", 1, style);
		}
	}

	return milktea::new_alt_cell_view(cells, (sz)w, (sz)h);
}

// ── File picker ───────────────────────────────────────────────────────────────

const int MAX_FILES = 256;

enum AppMode {
	PICKING,
	VIEWING
}

struct App {
	AppMode mode;
	// picker state
	String[MAX_FILES] files;
	int file_count;
	int cursor;
	int scroll;
	int width;
	int height;
	String error_msg;
	// viewer
	glb::GlbModel* model;
	// free-fly camera
	float cam_px;
	float cam_py;
	float cam_pz;
	float cam_yaw;
	float cam_pitch;
	float model_yaw;
	float model_pitch;
	float vel_fwd;
	float vel_up;
	float vel_yaw;
	float vel_pitch;
	float vel_pan;
	bool auto_rotate;
	// mouse state
	bool dragging;
	int drag_start_x;
	int drag_start_y;
	float drag_start_yaw;
	float drag_start_pitch;
	// last frame each key was seen (key repeat simulates held state)
	int key_w;
	int key_s;
	int key_a;
	int key_d;
	int key_q;
	int key_e;
	int key_left;
	int key_right;
	int key_up;
	int key_down;
	int tick_count;
}

fn void App.free_model(App* self) {
	if (self.model == null) return;
	self.model.free();
	mem::free(self.model);
	self.model = null;
}

fn void App.load_file(App* self, String path) {
	self.free_model();
	self.error_msg = "";
	glb::GlbModel*? result = glb::load_glb(path);
	if (catch err = result) {
		self.error_msg = string::tformat("Error loading '%s': %s", path, err);
		return;
	}
	self.model = result;
	self.model.width = self.width;
	self.model.height = self.height;
	self.model.resize(self.width, self.height);
	self.model.frame = 0;
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -20.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.model_yaw = 0.0f;
	self.model_pitch = 0.0f;
	self.vel_fwd = 0.0f;
	self.vel_up = 0.0f;
	self.vel_yaw = 0.0f;
	self.vel_pan = 0.0f;
	self.auto_rotate = true;
	self.mode = VIEWING;
}

fn void scan_glb_files(App* self, String dir) {
	self.file_count = 0;
	Path? dp = path::new(tmem, dir);
	if (catch dp) return;
	Path d          = (Path)dp;
	PathList? files = path::ls(tmem, d, no_dirs: true, mask: "*.glb");
	if (catch files) return;
	foreach (p : (PathList)files) {
		if (self.file_count >= MAX_FILES) break;
		String name = (String)p;
		if (!name.ends_with(".glb")) continue;
		self.files[self.file_count++] = name.copy(mem);
	}
}

fn milktea::Cmd App.init(App* self) @dynamic {
	self.width = 80;
	self.height = 24;
	self.mode = PICKING;
	self.cursor = 0;
	self.scroll = 0;
	self.model = null;
	self.error_msg = "";
	self.cam_px = 0.0f;
	self.cam_py = 0.0f;
	self.cam_pz = -20.0f;
	self.cam_yaw = 0.0f;
	self.cam_pitch = 0.0f;
	self.model_yaw = 0.0f;
	self.model_pitch = 0.0f;
	self.vel_fwd = 0.0f;
	self.vel_up = 0.0f;
	self.vel_yaw = 0.0f;
	self.vel_pan = 0.0f;
	self.auto_rotate = true;
	self.dragging = false;
	scan_glb_files(self, ".");
	return null;
}

fn milktea::Cmd App.update(App* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		if (self.model != null) {
			milktea::Msg resize = msg;
			self.model.update(resize);
		}
		return null;
	}

	if (self.mode == VIEWING) {
		if (msg.kind == milktea::MsgKind.MOUSE) {
			if (msg.mouse.action == milktea::MouseAction.MOUSE_PRESS) {
				if (msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
					self.dragging = true;
					self.drag_start_x = msg.mouse.col;
					self.drag_start_y = msg.mouse.row;
					self.drag_start_yaw = self.model_yaw;
					self.drag_start_pitch = self.model_pitch;
					self.auto_rotate = false;
				} else if (msg.mouse.button == milktea::MouseButton.MOUSE_WHEEL_UP) {
					float fwd_x =  (float)math::sin(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					float fwd_y = -(float)math::sin(self.cam_pitch);
					float fwd_z =  (float)math::cos(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					self.cam_px += fwd_x * 0.2f;
					self.cam_py += fwd_y * 0.2f;
					self.cam_pz += fwd_z * 0.2f;
				} else if (msg.mouse.button == milktea::MouseButton.MOUSE_WHEEL_DOWN) {
					float fwd_x =  (float)math::sin(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					float fwd_y = -(float)math::sin(self.cam_pitch);
					float fwd_z =  (float)math::cos(self.cam_yaw) * (float)math::cos(self.cam_pitch);
					self.cam_px -= fwd_x * 0.2f;
					self.cam_py -= fwd_y * 0.2f;
					self.cam_pz -= fwd_z * 0.2f;
				}
			} else if (msg.mouse.action == milktea::MouseAction.MOUSE_RELEASE) {
				if (msg.mouse.button == milktea::MouseButton.MOUSE_LEFT) {
					self.dragging = false;
				}
			} else if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION && self.dragging) {
				int total_dx = msg.mouse.col - self.drag_start_x;
				int total_dy = msg.mouse.row - self.drag_start_y;
				self.model_yaw   = self.drag_start_yaw   + (float)total_dx / (float)self.width * 2.0f;
				self.model_pitch = self.drag_start_pitch - (float)total_dy / (float)self.height * 2.0f;
				if (self.model_pitch > 1.4f) self.model_pitch = 1.4f;
				if (self.model_pitch < -1.4f) self.model_pitch = -1.4f;
			}
		}
		if (msg.kind == milktea::MsgKind.KEY) {
			milktea::KeyMsg k = msg.key;
			if (k.code == milktea::KeyCode.ESC || (k.code == milktea::KeyCode.RUNE && k.rune == 'b')) {
				self.mode = PICKING;
				return null;
			}
			if (k.code == milktea::KeyCode.CTRL_C || (k.code == milktea::KeyCode.RUNE && k.rune == 'q')) {
				return milktea::quit();
			}
			if (k.code == milktea::KeyCode.RUNE) {
				switch (k.rune) {
					case 'w': self.key_w = self.tick_count; self.auto_rotate = false;
					case 's': self.key_s = self.tick_count; self.auto_rotate = false;
					case 'a': self.key_a = self.tick_count; self.auto_rotate = false;
					case 'd': self.key_d = self.tick_count; self.auto_rotate = false;
					default:
				}
			}
			if (k.code == milktea::KeyCode.UP)   { self.key_up = self.tick_count;    self.auto_rotate = false; }
			if (k.code == milktea::KeyCode.DOWN)  { self.key_down = self.tick_count;  self.auto_rotate = false; }
			if (k.code == milktea::KeyCode.LEFT)  { self.key_left = self.tick_count;  self.auto_rotate = false; }
			if (k.code == milktea::KeyCode.RIGHT) { self.key_right = self.tick_count; self.auto_rotate = false; }
		}
		if (msg.kind == milktea::MsgKind.TICK) {
			self.tick_count++;
			int held_thresh = self.tick_count - 2;
			bool held_w     = self.key_w >= held_thresh;
			bool held_s     = self.key_s >= held_thresh;
			bool held_a     = self.key_a >= held_thresh;
			bool held_d     = self.key_d >= held_thresh;
			bool held_q     = self.key_q >= held_thresh;
			bool held_e     = self.key_e >= held_thresh;
			bool held_left  = self.key_left >= held_thresh;
			bool held_right = self.key_right >= held_thresh;
			bool held_up    = self.key_up >= held_thresh;
			bool held_down  = self.key_down >= held_thresh;

			if (self.model != null) {
				self.model.frame++;
				if (self.auto_rotate) {
					self.model_yaw   = (float)self.model.frame * 0.01f;
					self.model_pitch = (float)math::sin((float)self.model.frame * 0.003) * 0.15f;
				}

				float accel_fwd   = 0.04f;
				float accel_yaw   = 0.008f;
				float accel_pitch = 0.008f;
				float accel_up    = 0.04f;
				float accel_pan   = 0.04f;
				float max_fwd     = 0.4f;
				float max_yaw     = 0.08f;
				float max_pitch   = 0.06f;
				float max_up      = 0.4f;
				float max_pan     = 0.4f;
				float friction    = 0.80f;

				if (held_w) { self.vel_fwd += accel_fwd; if (self.vel_fwd > max_fwd) self.vel_fwd = max_fwd; }
				if (held_s) { self.vel_fwd -= accel_fwd; if (self.vel_fwd < -max_fwd) self.vel_fwd = -max_fwd; }
				if (held_a) { self.vel_yaw -= accel_yaw; if (self.vel_yaw < -max_yaw) self.vel_yaw = -max_yaw; }
				if (held_d) { self.vel_yaw += accel_yaw; if (self.vel_yaw > max_yaw) self.vel_yaw = max_yaw; }
				if (held_q) { self.vel_pitch -= accel_pitch; if (self.vel_pitch < -max_pitch) self.vel_pitch = -max_pitch; }
				if (held_e) { self.vel_pitch += accel_pitch; if (self.vel_pitch > max_pitch) self.vel_pitch = max_pitch; }
				if (held_left)  { self.vel_pan -= accel_pan; if (self.vel_pan < -max_pan) self.vel_pan = -max_pan; }
				if (held_right) { self.vel_pan += accel_pan; if (self.vel_pan > max_pan) self.vel_pan = max_pan; }
				if (held_up)    { self.vel_up += accel_up; if (self.vel_up > max_up) self.vel_up = max_up; }
				if (held_down)  { self.vel_up -= accel_up; if (self.vel_up < -max_up) self.vel_up = -max_up; }

				if (!held_w && !held_s) self.vel_fwd *= friction;
				if (!held_a && !held_d) self.vel_yaw *= friction;
				if (!held_q && !held_e) self.vel_pitch *= friction;
				if (!held_left && !held_right) self.vel_pan *= friction;
				if (!held_up && !held_down) self.vel_up *= friction;

				float cos_yaw   = (float)math::cos(self.cam_yaw);
				float sin_yaw   = (float)math::sin(self.cam_yaw);
				float cos_pitch = (float)math::cos(self.cam_pitch);
				self.cam_px += sin_yaw * cos_pitch * self.vel_fwd + cos_yaw * self.vel_pan;
				self.cam_py += -self.vel_fwd * (float)math::sin(self.cam_pitch) + self.vel_up;
				self.cam_pz += cos_yaw * cos_pitch * self.vel_fwd - sin_yaw * self.vel_pan;
				self.cam_yaw += self.vel_yaw;
				self.cam_pitch += self.vel_pitch;
				if (self.cam_pitch > 1.4f) self.cam_pitch = 1.4f;
				if (self.cam_pitch < -1.4f) self.cam_pitch = -1.4f;
			}
			return milktea::tick();
		}
		return null;
	}

	// PICKING mode
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;
	int visible = self.height - 3;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == 'j') {
				if (self.cursor < self.file_count - 1) {
					self.cursor++;
					if (self.cursor >= self.scroll + visible) self.scroll++;
				}
			}
			if (k.rune == 'k') {
				if (self.cursor > 0) {
					self.cursor--;
					if (self.cursor < self.scroll) self.scroll--;
				}
			}
		case milktea::KeyCode.DOWN:
			if (self.cursor < self.file_count - 1) {
				self.cursor++;
				if (self.cursor >= self.scroll + visible) self.scroll++;
			}
		case milktea::KeyCode.UP:
			if (self.cursor > 0) {
				self.cursor--;
				if (self.cursor < self.scroll) self.scroll--;
			}
		case milktea::KeyCode.ENTER:
			if (self.file_count > 0) {
				self.load_file(self.files[self.cursor]);
				if (self.mode == VIEWING) return milktea::tick();
			}
		default:
	}
	return null;
}

fn milktea::View App.view(App* self) @dynamic {
	if (self.mode == VIEWING && self.model != null) {
		self.model.cam_px = self.cam_px;
		self.model.cam_py = self.cam_py;
		self.model.cam_pz = self.cam_pz;
		self.model.cam_yaw = self.cam_yaw;
		self.model.cam_pitch = self.cam_pitch;
		self.model.model_yaw = self.model_yaw;
		self.model.model_pitch = self.model_pitch;
		return self.model.view();
	}

	DString out = dstring::temp();
	glaze::Style title_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	glaze::Style cursor_style = glaze::new_style().foreground(glaze::color_hex("#ffffff")).set_bold(true)
		.background(glaze::color_hex("#444444"));
	glaze::Style normal_style = glaze::new_style().foreground(glaze::color_hex("#aaaaaa"));
	glaze::Style error_style  = glaze::new_style().foreground(glaze::color_hex("#ff5555"));
	glaze::Style hint_style   = glaze::new_style().foreground(glaze::color_hex("#555555"));

	out.append_string(title_style.render("GLB Viewer — select a file"));
	out.append_char('\n');

	if (self.file_count == 0) {
		out.append_string(normal_style.render("  No .glb files found in current directory."));
		out.append_char('\n');
	} else {
		int visible = self.height - 3;
		int end     = self.scroll + visible;
		if (end > self.file_count) end = self.file_count;
		for (int i = self.scroll; i < end; i++) {
			String name    = path::new(tmem, self.files[i])!!.basename();
			bool is_cursor = (i == self.cursor);
			String line = is_cursor ? cursor_style.render(string::tformat(" \u25b6 %s", name))
				: normal_style.render(string::tformat("   %s", name));
			out.append_string(line);
			out.append_char('\n');
		}
	}

	if (self.error_msg.len > 0) {
		out.append_string(error_style.render(self.error_msg));
		out.append_char('\n');
	}

	out.append_string(hint_style.render("\u2191/\u2193 or j/k to navigate \u00b7 enter to open \u00b7 q to quit"));
	return milktea::new_alt_screen_view(out.str_view());
}

fn int main(String[] args) {
	App* app = mem::new(App);

	if (args.len > 1) {
		app.width = 80;
		app.height = 24;
		app.load_file(args[1]);
		if (app.mode != VIEWING) {
			io::printfn("%s", app.error_msg);
			return 1;
		}
	}

	milktea::enable_mouse();

	if (catch err = milktea::@run_program(app)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
