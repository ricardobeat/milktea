module dos_app;

import milktea;
import glaze;
import xray;

// A raised DOS-style button: a colored face with a hard shadow down its right
// edge and along its bottom.
//
// The shadow is a border made of half-block characters, so it is half a cell
// thick rather than a full one — ▌ down the right, ▀ along the bottom, ▘ at
// the corner where they meet. Drawing it as a border means glaze sizes and
// colors it, and the button itself is just a styled string.
const glaze::Border BUTTON_SHADOW = {
	.right = "▌",
	.bottom = "▀",
	.bottom_right = "▘",
};

// Two spaces of padding on each side of the label.
const int BUTTON_PAD = 2;

struct Button (xray::Content) {
	String label;
	bool focused;
	// The face changes with focus; the shadow never does.
	glaze::Color face;
	glaze::Color focused_face;
	glaze::Color text;
	glaze::Color shadow;
	// What the button sits on. The shadow is drawn with half-block characters,
	// so the half of each cell it does not cover shows this through — which is
	// what keeps the shadow from carrying the button's own face color.
	glaze::Color surface;
}

fn Button new_button(String label) {
	return {
		.label = label,
		.face = glaze::color_hex(C_GRAY),
		.focused_face = glaze::color_hex(C_YELLOW),
		.text = glaze::color_hex(C_BLACK),
		.shadow = glaze::color_hex(C_SHADOW),
		.surface = glaze::color_hex(C_DARK),
	};
}

fn Button Button.with_focus(self, bool on) {
	Button b = self;
	b.focused = on;
	return b;
}

fn glaze::Style Button.style(&self) {
	return {
		.fg = self.text,
		.bg = self.focused ? self.focused_face : self.face,
		.border = BUTTON_SHADOW,
		.border_color = self.shadow,
		.border_bg = self.surface,
		.pad_left = BUTTON_PAD,
		.pad_right = BUTTON_PAD,
	};
}

fn String Button.view(&self) => self.style().render(self.label);

// The face is one row; the shadow along the bottom adds another.
fn int Button.measure(&self, int width) @dynamic => 2;

// The label, its padding, and the shadow down the right edge.
fn int Button.measure_width(&self, int height) @dynamic {
	return glaze::string_width(self.label) + BUTTON_PAD * 2 + 1;
}

fn String Button.render(&self, xray::Rect r) @dynamic => self.view();

fn xray::Node* Button.node(&self) => xray::content_node(self);
