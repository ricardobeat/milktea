module boba;

import milktea;
import glaze;
import xray;

const sz TOAST_ANIM_MS = 12;
const sz TOAST_DISPLAY_MS = 2500;
const sz TOAST_ANIM_STEPS = 5;

enum ToastState {
	HIDDEN,
	SLIDING_IN,
	VISIBLE,
	SLIDING_OUT,
}

struct Toast {
	String message;
	ToastState state;
	sz anim_step;
	sz visible_ticks;
	glaze::Style style;
}

fn Toast new_toast() {
	Toast t = { };
	t.style = glaze::style()
		.foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#874bfc"))
		.padding(1, 2, 1, 2);
	return t;
}

fn void Toast.show(&self, String message) {
	self.message = message;
	self.state = ToastState.SLIDING_IN;
	self.anim_step = 0;
	self.visible_ticks = 0;
	milktea::cancel(self);
	milktea::tick(TOAST_ANIM_MS, owner: self);
}

fn void Toast.dismiss(&self) {
	if (self.state == ToastState.HIDDEN) return;
	self.state = ToastState.SLIDING_OUT;
	self.anim_step = TOAST_ANIM_STEPS;
	milktea::cancel(self);
	milktea::tick(TOAST_ANIM_MS, owner: self);
}

fn milktea::Cmd Toast.update(&self, milktea::Msg msg) {
	if (msg.kind != milktea::MsgKind.TICK || msg.owner != self) return null;

	switch (self.state) {
		case SLIDING_IN:
			self.anim_step++;
			if (self.anim_step >= TOAST_ANIM_STEPS) {
				self.state = ToastState.VISIBLE;
				self.anim_step = TOAST_ANIM_STEPS;
				milktea::tick(TOAST_DISPLAY_MS, owner: self);
			} else {
				milktea::tick(TOAST_ANIM_MS, owner: self);
			}
		case VISIBLE:
			self.state = ToastState.SLIDING_OUT;
			self.anim_step = TOAST_ANIM_STEPS;
			milktea::tick(TOAST_ANIM_MS, owner: self);
		case SLIDING_OUT:
			self.anim_step--;
			if (self.anim_step <= 0) {
				self.state = ToastState.HIDDEN;
				self.anim_step = 0;
			} else {
				milktea::tick(TOAST_ANIM_MS, owner: self);
			}
		default:
	}
	return null;
}

fn bool Toast.visible(&self) {
	return self.state != ToastState.HIDDEN;
}

fn sz Toast.toast_width(&self) {
	return glaze::string_width(self.message) + 4; // padding left(2) + right(2)
}

const sz TOAST_H = 3; // padding top(1) + content(1) + padding bottom(1)

// node puts the toast in a stack, centred above the bottom edge of whatever
// it is layered over, or returns null while it is hidden. Sliding in, it shows
// more of itself row by row from the top, its bottom edge held in place.
fn xray::Node* Toast.node(&self) {
	if (!self.visible()) return null;

	sz visible_rows = (self.anim_step * TOAST_H + TOAST_ANIM_STEPS - 1) / TOAST_ANIM_STEPS;
	if (visible_rows > TOAST_H) visible_rows = TOAST_H;
	if (visible_rows < 1) visible_rows = 1;

	return milktea::text(self.message, self.style)
		.width(xray::cells(self.toast_width()))
		.height(xray::cells(visible_rows))
		.place(xray::JustifyContent.JUSTIFY_CENTER, xray::AlignItems.ALIGN_END)
		.offset(0, -3)
		.shadow(xray::shadow(offset_x: 1, offset_y: 1, opacity: 128, blur: 2));
}
