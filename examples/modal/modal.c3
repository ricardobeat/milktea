module modal;

import milktea;
import glaze;
import xray;

struct Model {
	bool open;
	milktea::Tween anim;
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	return null;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.ESC:
			if (self.open) self.dismiss();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == ' ') {
				if (self.open) {
					self.dismiss();
				} else {
					self.open = true;
					self.anim = milktea::tween_at(milktea::time_ms(), 180, milktea::Easing.EASE_OUT_CUBIC);
				}
			}
		default:
	}
	return null;
}

fn void Model.dismiss(Model* self) {
	self.open = false;
	self.anim = milktea::tween_at(milktea::time_ms(), 150, milktea::Easing.EASE_IN_CUBIC, true);
}

fn milktea::View Model.view(Model* self) @dynamic {
	glaze::Style backdrop = { .bg = glaze::color_hex("#1b2a4a"), .bg_gradient = glaze::color_hex("#4a2b52"), };
	glaze::Style hint     = { .fg = glaze::color_hex("#8a8aa0"), .bg = glaze::color_hex("#4a2b52") };
	glaze::Style panel = {
		.bg = glaze::color_hex("#1e1e2e"),
		.fg = glaze::color_hex("#e8e8f0"),
		.border = glaze::ROUNDED,
		.border_color = glaze::color_hex("#7aa2f7"),
		.pad_top = 1,
		.pad_right = 3,
		.pad_bottom = 1,
		.pad_left = 3,
	};

	xray::Node* dialog = null;
	if (self.open || !self.anim.done()) {
		dialog = milktea::animate(milktea::text(panel, "Animated Modal\n\nfade + slide, driven by a Tween").center()
			.shadow(milktea::shadow(1, 1, 160, blur: 2, half_blocks: true)
				.with_color(glaze::color_hex("#05050c"))), milktea::slide_down(5).fade(), &self.anim);
	}

	return milktea::draw(milktea::root()
		.add(milktea::vstack().add(milktea::text(backdrop, "").fill(1))
			.add(milktea::text(hint, "space toggles the modal · esc dismisses · q quits").height(xray::cells(1))))
		.add(dialog));
}

fn int main() {
	Model m = { };
	milktea::@run(&m);
	return 0;
}
