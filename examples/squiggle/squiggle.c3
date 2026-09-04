module squiggle;

import milktea;
import glaze;
import tgp;
import std::io;
import std::core::mem;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;
const int TICK_MS = 110;

struct SquiggleModel {
	tgp::Session gfx;
	// One glyph holds every tile of every animation frame; the frame axis is
	// indexed as frame * FRAME_STRIDE + tile, so advancing the animation is
	// just a different base offset into the same glyph.
	tgp::Glyph tiles;
	int frame;
	bool kgp;
	int[GFX_FRAMES] tile_counts;
	int[GFX_FRAMES * BOX_H * BOX_W] cell_tile;
}

fn milktea::Cmd SquiggleModel.init(SquiggleModel* self) @dynamic {
	self.kgp = milktea::kitty_graphics_supported();
	if (self.kgp) {
		self.gfx = tgp::new_session();
		char[] frames = mem::new_array(char, (sz)(GFX_FRAMES * FRAME_STRIDE) * TILE_BYTES);
		build_tiles(frames, &self.cell_tile, &self.tile_counts);
		self.tiles = self.gfx.register({
			.frames = frames,
			.count = GFX_FRAMES * FRAME_STRIDE,
			.width = CELL_PX_W, .height = CELL_PX_H,
			.fps = 0, .fallback = " ",
		})!!;
	}
	return milktea::tick(TICK_MS, &on_spin);
}

fn milktea::Msg on_spin() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_SPIN };
}

fn milktea::Cmd SquiggleModel.update(SquiggleModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_SPIN) {
		// tick() transmits anything pending once the alt screen is up; images
		// are tied to the screen they were sent on, so it defers until then.
		if (self.kgp) self.gfx.tick();
		self.frame = (self.frame + 1) % GFX_FRAMES;
		return milktea::tick(TICK_MS, &on_spin);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return self.quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return self.quit();
		case milktea::KeyCode.ESC:
			return self.quit();
		default:
	}
	return null;
}

fn milktea::Cmd SquiggleModel.quit(SquiggleModel* self) {
	if (self.kgp) self.gfx.destroy();
	return milktea::quit();
}

fn void SquiggleModel.on_destroy(SquiggleModel* self) @dynamic {
	if (self.kgp) self.gfx.destroy();
}

// cell returns the placeholder for one border cell of the current frame.
fn String SquiggleModel.cell(SquiggleModel* self, int cx, int cy) {
	int tile = self.cell_tile[(self.frame * BOX_H + cy) * BOX_W + cx];
	return tgp::placeholder_string(
		self.tiles.base_id + (uint)(self.frame * FRAME_STRIDE + tile));
}

fn String pad_center(String s, int width) {
	DString out = dstring::temp();
	int left = (width - (int)s.len) / 2;
	int right = width - (int)s.len - left;
	if (left < 0) left = 0;
	if (right < 0) right = 0;
	for (int i = 0; i < left; i++) out.append_char(' ');
	out.append_string(s);
	for (int i = 0; i < right; i++) out.append_char(' ');
	return out.str_view();
}

fn milktea::View SquiggleModel.view(SquiggleModel* self) @dynamic {
	DString out = dstring::temp();
	int iw = BOX_W - 2;

	glaze::Style title_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	glaze::Style dim_style = glaze::style().foreground(glaze::color_hex("#888888"));

	for (int cx = 0; cx < BOX_W; cx++) out.append_string(self.cell(cx, 0));
	out.append_char('\n');

	for (int ry = 1; ry < BOX_H - 1; ry++) {
		out.append_string(self.cell(0, ry));

		String text = "";
		glaze::Style st = dim_style;
		switch (ry) {
			case 2: text = "S Q U I G G L E"; st = title_style;
			case 3: text = "drawn from kitty-graphics tiles";
			case 5: text = "q or esc to quit";
			default:
		}
		if (text.len > 0) {
			out.append_string(st.render(pad_center(text, iw)));
		} else {
			for (int i = 0; i < iw; i++) out.append_char(' ');
		}

		out.append_string(self.cell(BOX_W - 1, ry));
		out.append_char('\n');
	}

	for (int cx = 0; cx < BOX_W; cx++) out.append_string(self.cell(cx, BOX_H - 1));

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	SquiggleModel m = { };
	return milktea::@run(&m);
}
