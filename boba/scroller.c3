// Scroller is the scrolling of a view of rows, without the rows: where the
// view is, in layout units, and how it answers the wheel, a trackpad and code
// that moves it. A component keeps one and draws its rows from top_row(),
// with apply() on its node so a window draws the part-row too.
//
// In a window a trackpad moves it by the pixel, the platform's momentum keeps
// it going, and with rubber_band on a gesture can pull it past either end,
// with growing resistance, to spring back when the fingers lift. A wheel moves
// it by rows, or by points for a smooth one, and stays within the content. In a terminal a row is one layout
// unit, so everything still works, by whole rows.
//
// top_row() can be negative or past the last full screen while it is pulled
// past an end: the view draws blank rows there.
//
// Sideways it is simpler: columns instead of rows, no rubber band, and
// apply() gives the node the part-column too (see xray's scroll_shift_x),
// for a view of lines that do not wrap. scrollbar() draws where the view is,
// by the pixel, for a window.
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
	// Sideways: where the view is, in layout units, and how many columns
	// there are and fit (see set_columns).
	float pos_x_px;
	sz cols;
	sz visible_cols;
}

// ScrollbarStyle is how scrollbar() draws: a track down the whole height
// and a thumb, both rounded and width layout units wide. An unset track
// colour leaves the track out. The thumb is never shorter than min_thumb.
//
// hit_width, when wider than width, widens the bar for the pointer: it is
// that wide, with the visible track and thumb in its middle.
//
// on_thumb and on_track, when set, make the thumb and the rest of the track
// click targets, with ref as their context: a press on the thumb starts a
// drag (see drag_thumb), one on the track pages towards it.
struct ScrollbarStyle {
	xray::Color track;
	xray::Color thumb;
	sz width;
	sz min_thumb;
	sz hit_width;
	void* ref;
	xray::ClickFn on_thumb;
	xray::ClickFn on_track;
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

// ── Sideways ────────────────────────────────────────────────────────────────

// set_columns tells it how many columns the content is across and how many
// fit, and keeps it within them.
fn void Scroller.set_columns(&self, sz cols, sz visible) {
	self.cols = cols;
	self.visible_cols = visible;
	self.pos_x_px = clampf(self.pos_x_px, 0, self.max_x_px());
}

fn float Scroller.col_px(&self) => (float)milktea::layout_metrics().unit_w();

fn float Scroller.max_x_px(&self) {
	sz over = self.cols - self.visible_cols;
	return over > 0 ? (float)over * self.col_px() : 0.0f;
}

// left_col is the first column on screen, whole or in part.
fn sz Scroller.left_col(&self) => (sz)math::floor(self.pos_x_px / self.col_px());

// shift_x is how far into left_col the view is, in layout units.
fn sz Scroller.shift_x(&self) {
	float col = self.col_px();
	float f = self.pos_x_px - (float)self.left_col() * col;
	return f > 0 ? (sz)math::round(f) % (sz)col : 0;
}

// sync_col puts it at col when the view was moved across by columns some
// other way (keys, keeping a caret in sight) since it last moved it.
fn void Scroller.sync_col(&self, sz col) {
	if (self.left_col() == col) return;
	self.pos_x_px = clampf((float)col * self.col_px(), 0, self.max_x_px());
}

// scroll_x_pixels moves it across by dx layout units (positive towards the
// start of the line), within the content.
fn void Scroller.scroll_x_pixels(&self, float dx) {
	self.pos_x_px = clampf(self.pos_x_px - dx, 0, self.max_x_px());
}

// ── Scrollbar ───────────────────────────────────────────────────────────────

// scrollbar is a vertical scrollbar for a window, height layout units tall:
// the track with the thumb on it, sized to the share of the rows in view and
// placed by the pixel, the way the view itself scrolls. The caller places it
// (at the right edge of the view, say, with at(..., PX)). It is null in a
// terminal, which has no pixels to draw it with, and when every row fits.
fn xray::Node* Scroller.scrollbar(&self, sz height, ScrollbarStyle style) {
	if (!milktea::layout_metrics().pixels || height <= 0) return null;
	if (self.rows <= self.visible || self.rows <= 0) return null;
	float track = (float)height;
	float thumb = self.thumb_len(height, style);
	// Pulled past an end, the thumb shrinks against that end rather than
	// leaving the track.
	float max = self.max_px();
	float pos = self.pos_px;
	if (pos < 0) {
		thumb = math::max(thumb + pos * track / ((float)self.rows * self.row_px()), (float)style.width);
		pos = 0;
	} else if (pos > max) {
		thumb = math::max(thumb - (pos - max) * track / ((float)self.rows * self.row_px()), (float)style.width);
		pos = max;
	}
	float y = max > 0 ? (track - thumb) * pos / max : 0;
	float radius = (float)style.width / 2.0f;

	sz w = math::max(style.width, style.hit_width);
	sz inset = (w - style.width) / 2;
	sz len = (sz)math::round(thumb);
	xray::Node* bar = xray::zstack().width(xray::pixels(w)).height(xray::pixels(height))
		.id("scrollbar").role(SCROLLBAR);
	if (style.on_track) bar.ref(style.ref).on_click(style.on_track);
	if (!style.track.is_none()) {
		bar.add(xray::vstack().width(xray::pixels(style.width)).height(xray::pixels(height))
			.at(inset, 0, xray::Unit.PX).decorate(xray::solid(style.track).round(radius)));
	}
	xray::Node* t = xray::zstack().width(xray::pixels(w)).height(xray::pixels(len))
		.at(0, (sz)math::round(y), xray::Unit.PX);
	t.add(xray::vstack().width(xray::pixels(style.width)).height(xray::pixels(len))
		.at(inset, 0, xray::Unit.PX).decorate(xray::solid(style.thumb).round(radius)));
	if (style.on_thumb) t.id("scrollbar-thumb").ref(style.ref).on_click(style.on_thumb);
	bar.add(t);
	return bar;
}

// thumb_len is the thumb's length on a track height long, within the content.
fn float Scroller.thumb_len(&self, sz height, ScrollbarStyle style) {
	float track = (float)height;
	if (self.rows <= 0) return track;
	float thumb = track * (float)self.visible / (float)self.rows;
	if (thumb < (float)style.min_thumb) thumb = (float)style.min_thumb;
	return thumb > track ? track : thumb;
}

// drag_thumb puts the view where dragging the thumb dy layout units from
// where it was at from_px leaves it, within the content.
fn void Scroller.drag_thumb(&self, float from_px, float dy, sz height, ScrollbarStyle style) {
	float room = (float)height - self.thumb_len(height, style);
	float max = self.max_px();
	self.springing = false;
	self.pos_px = room > 0 ? clampf(clampf(from_px, 0, max) + dy * max / room, 0, max) : 0;
}

// thumb_mid is the middle of the thumb, from the top of a track height long.
fn float Scroller.thumb_mid(&self, sz height, ScrollbarStyle style) {
	float len = self.thumb_len(height, style);
	float max = self.max_px();
	float pos = clampf(self.pos_px, 0, max);
	return (max > 0 ? ((float)height - len) * pos / max : 0) + len / 2;
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
	// Only a gesture can pull past an end: nothing would end it otherwise.
	// A wheel, even a smooth one sending points, has no phase and stays in.
	if (!precise || !self.rubber_band || phase == milktea::ScrollPhase.NONE) {
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
	n.scroll_shift_x(self.shift_x());
	if (self.springing) n.animate(60);
}
