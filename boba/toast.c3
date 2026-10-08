module boba;

import milktea;
import glaze;
import xray;
import std::core::dstring;

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
	sz screen_width;
	sz screen_height;
	glaze::Style style;
	glaze::Style shadow_style;
}

fn Toast new_toast() {
	Toast t = { };
	t.style = glaze::style()
		.foreground(glaze::color_hex("#ffffff"))
		.background(glaze::color_hex("#874bfc"))
		.padding(1, 2, 1, 2);
	t.shadow_style = glaze::style()
		.background(glaze::color_hex("#000000"));
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
const sz SHADOW_OFFSET = 1;

// overlay_count returns how many overlays to add (0 if hidden, 2 if visible: shadow + toast).
fn sz Toast.overlay_count(&self) {
	return self.visible() ? 2 : 0;
}

// add_overlays adds the toast overlay with declarative shadow via LayerStyle.
fn milktea::View Toast.add_overlays(&self, milktea::View v) {
	if (!self.visible()) return v;

	sz toast_w = self.toast_width();

	sz visible_rows = (self.anim_step * TOAST_H + TOAST_ANIM_STEPS - 1) / TOAST_ANIM_STEPS;
	if (visible_rows > TOAST_H) visible_rows = TOAST_H;
	if (visible_rows < 1) visible_rows = 1;

	sz base_y = self.screen_height - visible_rows - 3;
	sz base_x = (self.screen_width - toast_w) / 2;
	if (base_x < 0) base_x = 0;

	String rendered = self.style.render(self.message);

	milktea::Overlay o = {
		.content = rendered,
		.x = base_x,
		.y = base_y,
		.w = toast_w,
		.h = visible_rows,
		.layer_style = {
			.shadow = xray::shadow(offset_x: 1, offset_y: 1, opacity: 128, blur: 2),
		},
	};
	if (v.overlay_count < milktea::MAX_OVERLAYS) {
		v.overlays[v.overlay_count] = o;
		v.overlay_count++;
	}

	return v;
}

// add_overlays_manual is the old manual two-overlay approach (kept as fallback).
fn milktea::View Toast.add_overlays_manual(&self, milktea::View v) {
	if (!self.visible()) return v;

	sz toast_w = self.toast_width();
	sz total_h = TOAST_H + SHADOW_OFFSET;

	sz visible_rows = (self.anim_step * total_h + TOAST_ANIM_STEPS - 1) / TOAST_ANIM_STEPS;
	if (visible_rows > total_h) visible_rows = total_h;
	if (visible_rows < 1) visible_rows = 1;

	sz base_y = self.screen_height - visible_rows - 3;
	sz base_x = (self.screen_width - toast_w) / 2;
	if (base_x < 0) base_x = 0;

	sz shadow_y = base_y + SHADOW_OFFSET;
	sz shadow_x = base_x + SHADOW_OFFSET;
	sz shadow_visible_h = visible_rows - SHADOW_OFFSET;
	if (shadow_visible_h > TOAST_H) shadow_visible_h = TOAST_H;
	if (shadow_visible_h > 0) {
		DString shadow_buf = dstring::temp();
		for (sz row = 0; row < shadow_visible_h; row++) {
			if (row > 0) shadow_buf.append_char('\n');
			DString line = dstring::temp();
			for (sz col = 0; col < toast_w; col++) line.append_char(' ');
			shadow_buf.append_string(self.shadow_style.render(line.str_view()));
		}
		v = v.add_overlay(shadow_x, shadow_y, toast_w, shadow_visible_h, shadow_buf.str_view(), alpha: 128);
	}

	sz toast_visible_h = visible_rows;
	if (toast_visible_h > TOAST_H) toast_visible_h = TOAST_H;
	String rendered = self.style.render(self.message);
	v = v.add_overlay(base_x, base_y, toast_w, toast_visible_h, rendered);

	return v;
}
