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
	sz frame;
}

fn milktea::Cmd SpinnersModel.init(SpinnersModel* self) @dynamic {
	$if !$feat(MILKTEA_WEB):
		self.gfx = tgp::new_session();
		// Registration is lazy: frames are transmitted on the first tick after
		// the alt screen is active, so ordering against 1049h is handled for us.
		self.ring = self.gfx.register(
			{
				.draw = &gen_ring,
				.count = RING_FRAMES,
				.width = GFX_W,
				.height = GFX_H,
				.fps = 12,
				.fallback = "◍",
			}
		)!!;
		self.ball = self.gfx.register(
			{
				.draw = &gen_ball,
				.count = GFX_FRAMES,
				.width = GFX_W,
				.height = GFX_H,
				.fps = 12,
				.fallback = "●",
			}
		)!!;
		self.orbit = self.gfx.register(
			{
				.draw = &gen_orbit,
				.count = GFX_FRAMES,
				.width = GFX_W,
				.height = GFX_H,
				.fps = 12,
				.fallback = "◎",
			}
		)!!;
		self.cube = self.gfx.register(
			{
				.draw = &gen_cube,
				.count = CUBE_FRAMES,
				.width = GFX_W,
				.height = GFX_H,
				.fps = 12,
				.fallback = "◆",
			}
		)!!;
	$endif
	return milktea::tick(80, &on_spin);
}

fn milktea::Msg on_spin() {
	return { .kind = USER, .tag = MSG_SPIN };
}

fn milktea::Cmd SpinnersModel.update(SpinnersModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == USER && msg.tag == MSG_SPIN) {
		self.frame++;
		// Advances the animation clock, transmits pending glyphs once the
		// alt screen is up, and reconciles placements.
		$if !$feat(MILKTEA_WEB):
			self.gfx.tick();
		$endif
		return milktea::tick(80, &on_spin);
	}

	if (msg.kind != KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case CTRL_C:
			return self.quit();
		case RUNE:
			if (k.rune == 'q') return self.quit();
		case ESC:
			return self.quit();
		default:
	}
	return null;
}

fn milktea::Cmd SpinnersModel.quit(SpinnersModel* self) {
	$if !$feat(MILKTEA_WEB):
		self.gfx.destroy();
	$endif
	return milktea::quit();
}

fn void SpinnersModel.on_destroy(SpinnersModel* self) @dynamic {
	$if !$feat(MILKTEA_WEB):
		self.gfx.destroy();
	$endif
}

struct SpinnerDef {
	String name;
	String[8] frames;
	sz count;
}

fn milktea::Node* SpinnersModel.view(SpinnersModel* self) @dynamic {
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

	glaze::Style title = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	glaze::Style label = glaze::style().foreground(glaze::color_hex("#888888"));
	glaze::Style active = glaze::style().foreground(glaze::color_hex("#ff00ff")).with_bold(true);
	glaze::Style border = glaze::style().with_border(glaze::ROUNDED);

	// Every slot has the same width, and each glyph gets four cells.
	// Animated frames and differently sized labels cannot shift the columns.
	sz columns = min(3, max(1, (milktea::screen_width() - 4) / 14));
	sz rows = (6 + columns - 1) / columns;
	milktea::Node* gallery = milktea::vstack().with_gap(1).with_padding(2, 2, 1, 2)
		.add(milktea::text("Spinner Gallery", title).height(milktea::cells(1)));
	for (sz start = 0; start < 6; start += columns) {
		milktea::Node* row = milktea::hstack().height(milktea::cells(1));
		for (sz i = start; i < min(start + columns, 6); i++) {
			String spin = spinners[i].frames[self.frame % spinners[i].count];
			row.add(milktea::hstack().width(milktea::cells(14))
				.add(milktea::text(spin, active).width(milktea::cells(4)))
				.add(milktea::text(spinners[i].name, label).fill(1)));
		}
		gallery.add(row);
	}
	sz extra_rows = 0;
	$if !$feat(MILKTEA_WEB):
		if (milktea::kitty_graphics_supported()) {
			String[4] gfx_views = {
				string::tformat("%s Ring", self.ring.render()),
				string::tformat("%s Goop Ball", self.ball.render()),
				string::tformat("%s Orbit", self.orbit.render()),
				string::tformat("%s Cube", self.cube.render())
			};
			gallery.add(milktea::text("kitty graphics protocol:", label).height(milktea::cells(1)));
			gallery.add(milktea::text(glaze::join_horizontal_arr(TOP, gfx_views[..], 3)));
			extra_rows = 4;
		}
	$endif

	milktea::Node* panel = milktea::zstack()
		.width(milktea::cells(columns * 14 + 4))
		.height(milktea::cells(rows * 2 + 5 + extra_rows))
		.add(milktea::text("", border))
		.add(gallery);
	return milktea::vstack().with_padding(0, 0, 1, 0)
		.add(milktea::root().add(panel.center()).fill(1))
		.add(milktea::hstack().with_justify(milktea::CENTER).height(milktea::cells(1))
			.add(milktea::text("Press q or ESC to quit", label).fit()));
}

fn int main() {
	SpinnersModel m = { };
	return milktea::@run(&m, { .alt_screen = true });
}