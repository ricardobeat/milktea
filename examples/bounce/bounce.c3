module bounce;

import milktea;
import glaze;
import std::io;
import std::core::string;
import std::core::dstring;

struct BounceModel {
	int ball_x;
	int ball_y;
	int dx;
	int dy;
	int width;
	int height;
	int ticks;
}

fn milktea::Cmd BounceModel.init(BounceModel* self) @dynamic {
	self.ball_x = 5;
	self.ball_y = 3;
	self.dx = 1;
	self.dy = 1;
	return milktea::tick(33);
}


fn milktea::Cmd BounceModel.update(BounceModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.TICK) {
		self.ticks++;

		// Bounce area is smaller than the terminal
		int arena_w = self.width - 4;
		int arena_h = self.height - 6;
		if (arena_w < 5) arena_w = 5;
		if (arena_h < 3) arena_h = 3;

		self.ball_x += self.dx;
		self.ball_y += self.dy;

		if (self.ball_x <= 0 || self.ball_x >= arena_w) {
			self.dx = -self.dx;
			if (self.ball_x < 0) self.ball_x = 0;
			if (self.ball_x > arena_w) self.ball_x = arena_w;
		}
		if (self.ball_y <= 0 || self.ball_y >= arena_h) {
			self.dy = -self.dy;
			if (self.ball_y < 0) self.ball_y = 0;
			if (self.ball_y > arena_h) self.ball_y = arena_h;
		}

		return milktea::tick(33);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
		default:
	}
	return null;
}

fn milktea::View BounceModel.view(BounceModel* self) @dynamic {
	int arena_w = self.width - 4;
	int arena_h = self.height - 6;
	if (arena_w < 5) arena_w = 5;
	if (arena_h < 3) arena_h = 3;

	String[4] ball_frames = { "🔴", "🟠", "🟡", "🟢" };
	String ball           = ball_frames[self.ticks % 4];

	// Build arena content (ball row + empty rows)
	DString content = dstring::temp();
	for (int y = 0; y < arena_h; y++) {
		if (y == self.ball_y) {
			for (int x = 0; x < arena_w; x++) {
				if (x == self.ball_x) {
					content.append_string(ball);
				} else {
					content.append_char(' ');
				}
			}
		} else {
			for (int x = 0; x < arena_w; x++) {
				content.append_char(' ');
			}
		}
		if (y < arena_h - 1) content.append_char('\n');
	}

	glaze::Style border = glaze::new_style()
		.set_border(
			{
				.top = "═",
				.bottom = "═",
				.left = "║",
				.right = "║",
				.top_left = "╔",
				.top_right = "╗",
				.bottom_left = "╚",
				.bottom_right = "╝"
			}
		);

	DString out = dstring::temp();
	out.append_string(border.render(content.str_view()));
	out.append_char('\n');

	glaze::Style hint = glaze::new_style().foreground(glaze::color_hex("#666666"));
	out.append_string(hint.render("Bouncing ball  |  q/ESC quit"));

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	BounceModel m = { };
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}

	io::printn("Bye!");
	return 0;
}