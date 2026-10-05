module spinners;

import milktea;
import glaze;
import tgp;
import std::io;
import std::core::mem;
import std::core::string;
import std::core::dstring;

const int MSG_SPIN = 1;

struct SpinnersModel {
	tgp::Session gfx;
	tgp::Glyph ring;
	tgp::Glyph ball;
	tgp::Glyph orbit;
	tgp::Glyph cube;
	int frame;
}

fn milktea::Cmd SpinnersModel.init(SpinnersModel* self) @dynamic {
	self.gfx = tgp::new_session();
	// Registration is lazy: frames are transmitted on the first tick after
	// the alt screen is active, so ordering against 1049h is handled for us.
	self.ring = self.gfx.register({
		.draw = &gen_ring,
		.count = RING_FRAMES, .width = GFX_W, .height = GFX_H,
		.fps = 12, .fallback = "◍",
	})!!;
	self.ball = self.gfx.register({
		.draw = &gen_ball,
		.count = GFX_FRAMES, .width = GFX_W, .height = GFX_H,
		.fps = 12, .fallback = "●",
	})!!;
	self.orbit = self.gfx.register({
		.draw = &gen_orbit,
		.count = GFX_FRAMES, .width = GFX_W, .height = GFX_H,
		.fps = 12, .fallback = "◎",
	})!!;
	self.cube = self.gfx.register({
		.draw = &gen_cube,
		.count = CUBE_FRAMES, .width = GFX_W, .height = GFX_H,
		.fps = 12, .fallback = "◆",
	})!!;
	return milktea::tick(80, &on_spin);
}

fn milktea::Msg on_spin() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_SPIN };
}

fn milktea::Cmd SpinnersModel.update(SpinnersModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_SPIN) {
		self.frame++;
		// Advances the animation clock, transmits pending glyphs once the
		// alt screen is up, and reconciles placements.
		self.gfx.tick();
		return milktea::tick(80, &on_spin);
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

fn milktea::Cmd SpinnersModel.quit(SpinnersModel* self) {
	self.gfx.destroy();
	return milktea::quit();
}

fn void SpinnersModel.on_destroy(SpinnersModel* self) @dynamic {
	self.gfx.destroy();
}

struct SpinnerDef {
	String name;
	String[8] frames;
	int count;
}

fn milktea::View SpinnersModel.view(SpinnersModel* self) @dynamic {
	SpinnerDef[6] spinners;
	spinners[0] = { .name = "Dots", .frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }, .count = 8 };
	spinners[1] = { .name = "Lines", .frames = { "-", "\\", "|", "/", "-", "\\", "|", "/" }, .count = 4 };
	spinners[2] = { .name = "Arrow", .frames = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" }, .count = 8 };
	spinners[3] = {
		.name = "Blocks",
		.frames = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" },
		.count = 8
	};
	spinners[4] = {
		.name = "Moon",
		.frames = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
		.count = 8
	};
	spinners[5] = {
		.name = "Pulse",
		.frames = {
			"∙∙∙",
			"●∙∙",
			"∙●∙",
			"∙∙●",
			"∙∙∙",
			"∙∙∙",
			"∙∙∙",
			"∙∙∙"
		},
		.count = 5
	};

	glaze::Style title = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true)
		.padding(0, 0, 1, 0);

	glaze::Style label = glaze::style().foreground(glaze::color_hex("#888888"));

	glaze::Style active = glaze::style().foreground(glaze::color_hex("#ff00ff")).with_bold(true);

	glaze::Style box_style = glaze::style().with_border(glaze::ROUNDED).padding(1, 2, 1, 2);

	DString content = dstring::temp();
	content.append_string(title.render("Spinner Gallery"));
	content.append_char('\n');

	String[6] spin_views;
	for (int i = 0; i < 6; i++) {
		int idx     = self.frame % spinners[i].count;
		String spin = spinners[i].frames[idx];
		String name = spinners[i].name;
		spin_views[i] = string::tformat(
			"%s%s",
			active.render(string::tformat("  %s", spin)),
			label.render(string::tformat("  %s", name))
		);
	}
	content.append_string(glaze::join_horizontal_arr(glaze::Position.TOP, spin_views[..], 3));

	content.append_char('\n');
	if (milktea::kitty_graphics_supported()) {
		content.append_string(label.render("kitty graphics protocol:"));
		content.append_char('\n');
		String[4] gfx_views = {
			string::tformat("  %s%s", self.ring.render(), label.render("  Ring")),
			string::tformat("  %s%s", self.ball.render(), label.render("  Goop Ball")),
			string::tformat("  %s%s", self.orbit.render(), label.render("  Orbit")),
			string::tformat("  %s%s", self.cube.render(), label.render("  Cube"))
		};
		content.append_string(glaze::join_horizontal_arr(glaze::Position.TOP, gfx_views[..], 3));
	} else {
		content.append_string(label.render("(graphics spinners fall back to text: ◍ ● ◎ ◆)"));
	}

	content.append_char('\n');
	content.append_string(label.render("Press q or ESC to quit"));

	return milktea::view(box_style.render(content.str_view()));
}

fn int main() {
	SpinnersModel m = { };
	return milktea::@run(&m, { .alt_screen = true });
}
