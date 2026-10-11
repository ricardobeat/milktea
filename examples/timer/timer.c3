module timer;

import milktea;
import glaze;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

struct TimerModel {
	boba::Timer timer;
}

fn milktea::Cmd TimerModel.init(TimerModel* self) @dynamic {
	self.timer = boba::new_timer(60);
	return self.timer.init_cmd();
}

fn milktea::Cmd TimerModel.update(TimerModel* self, milktea::Msg msg) @dynamic {
	self.timer.update(msg);

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == ' ') self.timer.toggle();
			if (k.rune == 'r') {
				self.timer.reset();
				return self.timer.init_cmd();
			}
		default:
	}
	return null;
}

fn milktea::Node* TimerModel.view(TimerModel* self) @dynamic {
	glaze::Style box_style = glaze::style().foreground(glaze::color_hex("#ff00ff")).with_bold(true)
		.padding(2, 4, 2, 4)
		.with_border(glaze::ROUNDED);

	glaze::Style subtle = glaze::style().foreground(glaze::color_hex("#666666"));

	sz minutes = self.timer.remaining() / 60;
	sz secs = self.timer.remaining() % 60;
	String time_str = string::tformat("%02d:%02d", minutes, secs);
	String status = "SPACE to pause";
	glaze::Style status_style = subtle;
	if (self.timer.done) {
		status = "Time's up!";
		status_style = glaze::style().foreground(glaze::color_hex("#00ff00")).with_bold(true);
	} else if (!self.timer.running) {
		status = "PAUSED · SPACE to resume";
		status_style = glaze::style().foreground(glaze::color_hex("#ffff00"));
	}

	milktea::Node* content = milktea::vstack()
		.with_align(milktea::ALIGN_CENTER)
		.with_gap(1)
		.add(milktea::text(time_str, box_style).fit())
		.add(milktea::text(status, status_style).fit())
		.add(milktea::text("r to reset  |  q to quit", subtle).fit());
	return milktea::root().add(content.center());
}

fn int main() {
	TimerModel m = { };
	milktea::@run(&m, { .alt_screen = true });
	return 0;
}