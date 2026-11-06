// Scroller is the scrolling of a view of rows, without the rows: where the
// view is, in layout units, and how it answers the wheel, a trackpad and code
// that moves it. A component keeps one and draws its rows from top_row(),
// with apply() on its node so a window draws the part-row too.
//
// In a window a trackpad moves it by the pixel, the platform's momentum keeps
// it going, and with rubber_band on a gesture can pull it past either end,
// with growing resistance, to spring back when the fingers lift. A wheel moves
// it by rows and stays within the content. In a terminal a row is one layout
// unit, so everything still works, by whole rows.
//
// top_row() can be negative or past the last full screen while it is pulled
// past an end: the view draws blank rows there.
module boba;

import milktea;
import xray;
import std::math;

// How far a gesture can pull past an end, as a share of the visible height,
// and how quickly it springs back (ms per 1/e).
const float SCROLL_OVERSHOOT_SHARE @private = 0.25f;
const float SCROLL_SPRING_MS @private = 70.0f;

struct Scroller {
	float pos_px;
	sz rows;
	sz visible;
	bool rubber_band;
	bool springing;
	float spring_from;
	long spring_start_ms;
	// Momentum from a gesture that ran past an end: it is spent on the
	// bounce, not the position, until the fingers touch again.
	bool drop_momentum;
}

fn Scroller scroller(bool rubber_band = true) => { .rubber_band = rubber_band };

// set_content tells it how many rows there are and how many fit.
fn void Scroller.set_content(&self, sz rows, sz visible) {
	self.rows = rows;
	self.visible = visible;
}

fn float Scroller.row_px(&self) => (float)milktea::layout_metrics().unit_h();

fn float Scroller.max_px(&self) {
	sz over = self.rows - self.visible;
	return over > 0 ? (float)over * self.row_px() : 0.0f;
}

// top_row is the first row on screen, whole or in part.
fn sz Scroller.top_row(&self) => (sz)math::floor(self.pos_px / self.row_px());

// shift is how far into top_row the view is, in layout units.
fn sz Scroller.shift(&self) {
	float row = self.row_px();
	float f = self.pos_px - (float)self.top_row() * row;
	return f > 0 ? (sz)math::round(f) % (sz)row : 0;
}

// sync_row puts it at row when the view was moved by rows some other way
// (keys, keeping a caret in sight) since it last moved it.
fn void Scroller.sync_row(&self, sz row) {
	if (self.top_row() == row) return;
	self.pos_px = (float)row * self.row_px();
	self.springing = false;
}

// scroll_to_row moves it to row, within the content.
fn void Scroller.scroll_to_row(&self, sz row) {
	self.springing = false;
	self.pos_px = clampf((float)row * self.row_px(), 0, self.max_px());
}

fn float clampf(float v, float lo, float hi) @private => v < lo ? lo : v > hi ? hi : v;

// scroll_pixels moves it by dy layout units (positive towards the start).
fn void Scroller.scroll_pixels(&self, float dy, bool precise, milktea::ScrollPhase phase) {
	bool momentum = phase == milktea::ScrollPhase.MOMENTUM || phase == milktea::ScrollPhase.MOMENTUM_ENDED;
	// The platform keeps sending momentum after the fingers lift; once the
	// view is springing back from an end, that momentum must not undo it.
	if (momentum && self.drop_momentum) {
		if (phase == milktea::ScrollPhase.MOMENTUM_ENDED) self.drop_momentum = false;
		return;
	}
	if (!momentum) self.drop_momentum = false;
	float pos = self.pos_px;
	float max = self.max_px();
	float delta = -dy;
	self.springing = false;
	if (!precise || !self.rubber_band) {
		self.pos_px = clampf(pos + delta, 0, max);
		return;
	}
	float limit = (float)self.visible * self.row_px() * SCROLL_OVERSHOOT_SHARE;
	if (limit < 1) limit = 1;
	float over = pos < 0 ? -pos : pos > max ? pos - max : 0;
	bool outward = (pos <= 0 && delta < 0) || (pos >= max && delta > 0);
	if (outward) {
		// The further out, the less the content follows the fingers.
		float give = 1.0f - over / limit;
		delta *= give > 0 ? give * 0.5f : 0;
	}
	pos += delta;
	self.pos_px = pos;
	bool out = pos < 0 || pos > max;
	bool settling = phase == milktea::ScrollPhase.ENDED || phase == milktea::ScrollPhase.MOMENTUM_ENDED
		|| (phase == milktea::ScrollPhase.MOMENTUM && out);
	if (out && settling) {
		self.springing = true;
		self.spring_from = pos;
		self.spring_start_ms = milktea::frame_ms();
		self.drop_momentum = phase != milktea::ScrollPhase.MOMENTUM_ENDED;
	}
}

// handle takes a mouse message's scroll as a window reports it (pixels and
// a gesture phase) and reports whether it did; a wheel message without that
// (a terminal) is left to the caller to scroll by rows.
fn bool Scroller.handle(&self, milktea::MouseMsg msg) {
	if (!milktea::layout_metrics().pixels) return false;
	if (msg.scroll_dy == 0 && msg.action != milktea::MouseAction.MOUSE_SCROLL_PHASE) return false;
	self.scroll_pixels(msg.scroll_dy, msg.scroll_precise, msg.scroll_phase);
	return true;
}

// settle moves a springing scroller towards the end it ran past.
fn void Scroller.settle(&self) {
	if (!self.springing) return;
	float target = clampf(self.pos_px, 0, self.max_px());
	float t = (float)(milktea::frame_ms() - self.spring_start_ms);
	float pos = target + (self.spring_from - target) * math::exp(-t / SCROLL_SPRING_MS);
	if (math::abs(pos - target) < 0.5f) {
		pos = target;
		self.springing = false;
	}
	self.pos_px = pos;
}

// apply settles it and gives the view's node the part-row shift, asking for
// frames while it springs.
fn void Scroller.apply(&self, xray::Node* n) {
	self.settle();
	if (!milktea::layout_metrics().pixels) return;
	n.scroll_shift(self.shift());
	if (self.springing) n.animate(60);
}
