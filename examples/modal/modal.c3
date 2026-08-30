module modal;

import milktea;
import glaze;
import xray;
import xray::layout;
import std::core::string;
import std::core::dstring;

// A modal that fades in and slides down into place, and reverses back out on
// dismiss. The animation is driven entirely by the ordinary timer loop: a
// milktea::Tween holds the progress, `update` advances it on each frame
// message, and `view` derives the overlay's y position and alpha from it.
// 
// The frame timer only re-arms while the tween is still running, so an idle
// modal costs nothing — the event loop goes back to blocking on input.

const int MSG_FRAME = 1;

const sz OPEN_MS  = 260;
const sz CLOSE_MS = 180; // dismissing reads better slightly faster than opening

const int MODAL_W    = 40;
const int MODAL_H    = 7;
const int SLIDE_ROWS = 6; // how far above its resting row the modal starts

enum Phase : int {
	HIDDEN,
	OPENING,
	OPEN,
	CLOSING,
}

struct Model {
	Phase phase;
	milktea::Tween anim;
}

fn milktea::Msg on_frame() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_FRAME };
}

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.phase = Phase.HIDDEN;
	return null;
}

fn milktea::Cmd Model.open(Model* self) {
	self.phase = Phase.OPENING;
	// EASE_OUT_CUBIC decelerates into the target and settles on it directly,
	// with no overshoot.
	self.anim = milktea::tween(OPEN_MS, milktea::Easing.EASE_OUT_CUBIC);
	return milktea::tick(milktea::FRAME_MS, &on_frame);
}

fn milktea::Cmd Model.close(Model* self) {
	self.phase = Phase.CLOSING;
	self.anim = milktea::tween_reversed(CLOSE_MS, milktea::Easing.EASE_IN_CUBIC);
	return milktea::tick(milktea::FRAME_MS, &on_frame);
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_FRAME) {
		// step() reports whether the animation is still running; when it
		// settles we stop re-arming the timer and let the loop go idle.
		if (self.anim.step(milktea::FRAME_MS)) {
			return milktea::tick(milktea::FRAME_MS, &on_frame);
		}
		self.phase = self.phase == Phase.OPENING ? Phase.OPEN : Phase.HIDDEN;
		return null;
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return milktea::quit();
		case milktea::KeyCode.ESC:
			if (self.phase == Phase.OPEN) return self.close();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return milktea::quit();
			if (k.rune == ' ') {
				// Space toggles, and is allowed to interrupt an animation in
				// flight so the modal always answers the key.
				if (self.phase == Phase.OPEN || self.phase == Phase.OPENING) {
					return self.close();
				}
				return self.open();
			}
		default:
	}
	return null;
}

fn milktea::View Model.view(Model* self) @dynamic {
	// The running program tracks the terminal size, so the model does not
	// have to store it or handle WINDOW_SIZE just to read it back.
	xray::Rect screen = layout::screen(milktea::screen_width(), milktea::screen_height());

	// Split the screen into the backdrop and a one-line hint at the bottom.
	xray::Rect body_r;
	xray::Rect hint_r;
	layout::vstack(screen, { layout::slot(layout::fill(1), &body_r), layout::slot(layout::cells(1), &hint_r), });

	// A patterned backdrop, so the fade has something to blend against.
	glaze::Style dim = glaze::style().foreground(glaze::color_hex("#2a2a3a"));
	DString bg       = dstring::temp();
	for (int y = 0; y < body_r.h; y++) {
		if (y > 0) bg.append_char('\n');
		DString row = dstring::temp();
		for (int x = 0; x < body_r.w; x++) row.append_string("·");
		bg.append_string(dim.render(row.str_view()));
	}
	bg.append_char('\n');

	glaze::Style hint = glaze::style().foreground(glaze::color_hex("#666666"));
	bg.append_string(hint.render("space toggles the modal · esc dismisses · q quits"));

	milktea::View v = milktea::new_alt_screen_view(bg.str_view());
	if (self.phase == Phase.HIDDEN) return v;

	// Centre the modal by letting the solver divide the leftover space:
	// fill(1) on either side of a fixed-size middle slot. The vertical solve
	// gives the modal's resting row, which the tween slides it down onto.
	xray::Rect row_r;
	layout::vstack(
		screen,
		{
			layout::slot(layout::fill(1), null),
			layout::slot(layout::cells(MODAL_H), &row_r),
			layout::slot(layout::fill(1), null),
		}
	);

	xray::Rect modal_r;
	layout::hstack(
		row_r,
		{
			layout::slot(layout::fill(1), null),
			layout::slot(layout::cells(MODAL_W), &modal_r),
			layout::slot(layout::fill(1), null),
		}
	);

	int y = self.anim.lerp(modal_r.y - SLIDE_ROWS, modal_r.y);

	String body = glaze::style().with_width(MODAL_W - 4).align_horizontal(glaze::Position.CENTER).padding(1, 1, 1, 1)
		.background(glaze::color_hex("#1e1e2e"))
		.foreground(glaze::color_hex("#e8e8f0"))
		.border_fg(glaze::color_hex("#7aa2f7"))
		.with_border(glaze::ROUNDED)
		.render("Animated Modal\n\nfade + slide, driven by a Tween");

	return v.add_overlay(modal_r.x, y, modal_r.w, modal_r.h, body, self.anim.alpha());
}

fn int main() {
	Model m = { };
	milktea::@run(&m);
	return 0;
}