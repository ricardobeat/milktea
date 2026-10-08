module xray;

import std::math;

// Decoration is a node-level background a GUI backend paints with real vector
// graphics: rounded corners, a solid or gradient fill, a border and a drop
// shadow, all measured in points rather than cells.
//
// A terminal build ignores it entirely — the node's cells still paint their own
// background and text — so one view keeps running in both hosts; only the GUI
// has the pixels to show it. It replaces the node's own cell backgrounds, before its glyphs
// and children. Child backgrounds and later siblings paint over it.
//
// Gradient geometry is normalised to the node's rect (0..1 on each axis), so
// one Decoration survives the node being laid out at a different size.
enum DecorationKind : char {
	NONE,   // nothing to draw
	SOLID,  // color fills the whole shape
	LINEAR, // color -> color2 along (x1, y1)-(x2, y2)
	RADIAL, // color at the focal point -> color2 at the outer circle
}

struct Decoration {
	// The rect the decoration applies to. Ignored on a node (the solver owns
	// the geometry); filled in by the paint traversal from the solved rect.
	Rect rect;
	bool pixel_rect;
	sz pad_top, pad_right, pad_bottom, pad_left;

	DecorationKind kind;
	Color color;
	Color color2;

	// Corner radius in points. 0 gives square corners.
	float radius;

	// Linear gradient endpoints, normalised to the rect.
	float x1;
	float y1;
	float x2;
	float y2;

	// Radial gradient: centre and focal point normalised to the rect, and the
	// outer radius as a fraction of the rect's shorter side (0 = half of it,
	// so the gradient reaches the nearest edge; >0 stretches past it).
	float cx;
	float cy;
	float fx;
	float fy;
	float r;

	// Border drawn inside the rect, in points.
	float border;
	Color border_color;

	// Drop shadow: offset in points, blur radius in points, colour with the
	// alpha it should composite at.
	bool shadow;
	float shadow_dx;
	float shadow_dy;
	float shadow_blur;
	Color shadow_color;
}

// solid fills the shape with one colour.
fn Decoration solid(Color c) {
	Decoration d;
	d.kind = DecorationKind.SOLID;
	d.color = c;
	return d;
}

// linear runs colour to colour2 across the shape at the given angle in degrees
// (0 = left to right, 90 = top to bottom).
fn Decoration linear(Color a, Color b, float angle_deg = 90.0) {
	Decoration d;
	d.kind = DecorationKind.LINEAR;
	d.color = a;
	d.color2 = b;
	float rad = angle_deg * (float)math::PI / 180.0f;
	float dx = math::cos(rad);
	float dy = math::sin(rad);
	d.x1 = 0.5f - dx * 0.5f;
	d.y1 = 0.5f - dy * 0.5f;
	d.x2 = 0.5f + dx * 0.5f;
	d.y2 = 0.5f + dy * 0.5f;
	return d;
}

// radial runs colour (at the focal point) to colour2 at the outer circle. The
// focal point is normalised to the rect, so (0.3, 0.3) gives the soft highlight
// a lit button has.
fn Decoration radial(Color a, Color b, float focal_x = 0.5f, float focal_y = 0.5f) {
	Decoration d;
	d.kind = DecorationKind.RADIAL;
	d.color = a;
	d.color2 = b;
	d.cx = 0.5f;
	d.cy = 0.5f;
	d.fx = focal_x;
	d.fy = focal_y;
	return d;
}

fn Decoration Decoration.round(self, float radius) {
	Decoration d = self;
	d.radius = radius;
	return d;
}

fn Decoration Decoration.with_border(self, float width, Color c) {
	Decoration d = self;
	d.border = width;
	d.border_color = c;
	return d;
}

fn Decoration Decoration.with_shadow(self, float dx, float dy, float blur, Color c) {
	Decoration d = self;
	d.shadow = true;
	d.shadow_dx = dx;
	d.shadow_dy = dy;
	d.shadow_blur = blur;
	d.shadow_color = c;
	return d;
}

// Extra GUI inset in logical pixels; cell constraints size the box before it.
fn Decoration Decoration.padding(self, sz top, sz right, sz bottom, sz left) {
	self.pad_top = top > 0 ? top : 0;
	self.pad_right = right > 0 ? right : 0;
	self.pad_bottom = bottom > 0 ? bottom : 0;
	self.pad_left = left > 0 ? left : 0;
	return self;
}
