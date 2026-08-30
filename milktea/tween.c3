module milktea;

import dye;

// Animation helpers: an easing curve plus a Tween that maps elapsed time onto
// a value. A Tween is plain data the model owns — nothing here touches the
// renderer — and it runs in one of two modes.
//
// Clock-driven is the usual one, and needs no frame messages at all: build it
// with `tween_at(time_ms(), ms)` and hand it to `milktea::animate` in view()
// (see animate.c3), which reads it against the paint clock and lets the node
// tree ask for its own repaints.
//
// Step-driven is for a model that wants the frames itself: build it with
// `tween()`, advance it with `step()` on each frame message, and re-arm
// `tick()` while step() reports the animation is still running. The two modes
// do not mix — advance_to() leaves a step-driven tween alone.
//
// Either way a settled tween stops asking for frames, so an idle animation
// costs nothing.

// A frame budget of 16ms is ~60fps, matching the default of `tick()`.
const sz FRAME_MS = 16;

// Easing curves, applied to normalized progress. LINEAR is the identity;
// the OUT curves decelerate into the target and are the usual choice for UI
// that enters (menus, modals, toasts); IN curves accelerate away and suit
// things leaving; IN_OUT is symmetric and suits movement between two resting
// states.
enum Easing : int {
	LINEAR,
	EASE_IN_QUAD,
	EASE_OUT_QUAD,
	EASE_IN_OUT_QUAD,
	EASE_IN_CUBIC,
	EASE_OUT_CUBIC,
	EASE_IN_OUT_CUBIC,
	EASE_OUT_BACK,
}

// ease applies a curve to normalized progress `t` in [0,1] and returns the
// eased fraction. Input is clamped, so callers need not bounds-check.
// 
// Every curve satisfies ease(0) == 0 and ease(1) == 1. EASE_OUT_BACK
// deliberately overshoots past 1 in the middle of its range before settling,
// which is what gives it its slight "pop"; a caller interpolating a value that
// must stay within bounds (an alpha channel, say) should clamp the result.
fn double ease(Easing e, double t) {
	if (t <= 0.0) return 0.0;
	if (t >= 1.0) return 1.0;
	switch (e) {
		case LINEAR:
			return t;
		case EASE_IN_QUAD:
			return t * t;
		case EASE_OUT_QUAD:
			double inv = 1.0 - t;
			return 1.0 - inv * inv;
		case EASE_IN_OUT_QUAD:
			if (t < 0.5) return 2.0 * t * t;
			double inv = -2.0 * t + 2.0;
			return 1.0 - inv * inv / 2.0;
		case EASE_IN_CUBIC:
			return t * t * t;
		case EASE_OUT_CUBIC:
			double inv = 1.0 - t;
			return 1.0 - inv * inv * inv;
		case EASE_IN_OUT_CUBIC:
			if (t < 0.5) return 4.0 * t * t * t;
			double inv = -2.0 * t + 2.0;
			return 1.0 - inv * inv * inv / 2.0;
		case EASE_OUT_BACK:
			// Overshoot constants from the conventional CSS "back" curve.
			const double C1 = 1.70158;
			const double C3 = C1 + 1.0;
			double inv = t - 1.0;
			return 1.0 + C3 * inv * inv * inv + C1 * inv * inv;
	}
}

// Tween maps elapsed milliseconds onto a normalized, eased fraction. It holds
// no clock: the owner advances it with `step()` (or sets `elapsed_ms`
// directly) and reads `value()`. A zero-value Tween is a valid, already-
// finished animation, so an un-initialized field renders at its target rather
// than at its start.
struct Tween {
	sz elapsed_ms;
	sz duration_ms;
	Easing easing;
	bool reverse; // play from the target back to the start
	// Wall-clock start, for a tween driven by the paint clock rather than by
	// step(). Zero means "not clock-driven"; see tween_at.
	long started_ms;
}

// tween builds a Tween that runs forward over `duration_ms`.
fn Tween tween(sz duration_ms, Easing easing = Easing.EASE_OUT_CUBIC) {
	return { .elapsed_ms = 0, .duration_ms = duration_ms, .easing = easing, .reverse = false };
}

// tween_reversed builds a Tween that runs from the target back to the start,
// for dismissing whatever `tween()` presented.
fn Tween tween_reversed(sz duration_ms, Easing easing = Easing.EASE_OUT_CUBIC) {
	return { .elapsed_ms = 0, .duration_ms = duration_ms, .easing = easing, .reverse = true };
}

// tween_at builds a Tween that reads its progress from the clock, starting at
// `now`. Pass milktea::time_ms() from update() when the animation begins; the
// tween then needs no frame messages at all, because `animate` re-reads it
// against the paint clock on every frame:
// 
//     self.anim = tween_at(milktea::time_ms(), 260);
// 
// A clock-driven tween ignores step(). The two modes are deliberately
// separate: a model that wants to drive frames itself keeps step(), and one
// that wants the tree to drive them uses this.
fn Tween tween_at(long now, sz duration_ms, Easing easing = Easing.EASE_OUT_CUBIC, bool reverse = false) {
	// A start of 0 is the sentinel for "not clock-driven", so a caller whose
	// clock genuinely reads 0 is nudged to 1 rather than silently ignored.
	if (now == 0) now = 1;
	return { .elapsed_ms = 0, .duration_ms = duration_ms, .easing = easing, .reverse = reverse, .started_ms = now, };
}

// advance_to sets a clock-driven tween's progress from the current time, and
// reports whether it is still running. Called by `animate` on every paint; a
// tween that is not clock-driven is left alone.
fn bool Tween.advance_to(&self, long now) {
	if (self.started_ms == 0) return !self.done();
	long delta = now - self.started_ms;
	// A clock that goes backwards (or a tween started in the future) reads as
	// "not begun" rather than wrapping the unsigned elapsed.
	self.elapsed_ms = delta <= 0 ? 0 : (sz)delta;
	if (self.elapsed_ms > self.duration_ms) self.elapsed_ms = self.duration_ms;
	return !self.done();
}

// step advances the tween by `dt_ms` and reports whether it is still running.
// The return value is what a model uses to decide whether to re-arm its frame
// timer, so the timer stops arming itself once the animation settles:
// 
//     if (self.anim.step(FRAME_MS)) return tick(FRAME_MS, &on_frame);
//     return null;
fn bool Tween.step(&self, sz dt_ms = FRAME_MS) {
	self.elapsed_ms += dt_ms;
	if (self.elapsed_ms > self.duration_ms) self.elapsed_ms = self.duration_ms;
	return !self.done();
}

// done reports whether the tween has reached its end.
fn bool Tween.done(&self) => self.elapsed_ms >= self.duration_ms;

// restart rewinds the tween to its first frame, keeping duration and easing.
fn void Tween.restart(&self) {
	self.elapsed_ms = 0;
}

// value returns the eased progress in [0,1] (EASE_OUT_BACK may exceed it
// mid-flight; see `ease`). A zero duration yields 1.0 — an instant animation
// is one that is already finished, never a divide by zero.
fn double Tween.value(&self) {
	if (self.duration_ms == 0) return 1.0;
	double t = (double)self.elapsed_ms / (double)self.duration_ms;
	if (self.reverse) t = 1.0 - t;
	return ease(self.easing, t);
}

// lerp interpolates between two ints by this tween's current value, rounding
// to nearest. Handy for a slide: `t.lerp(start_y, target_y)`.
fn int Tween.lerp(&self, int from, int to) {
	double v   = self.value();
	double out = (double)from + ((double)to - (double)from) * v;
	return (int)(out < 0.0 ? out - 0.5 : out + 0.5);
}

// lerpf interpolates between two doubles by this tween's current value.
fn double Tween.lerpf(&self, double from, double to) {
	return from + (to - from) * self.value();
}

// lerp_color interpolates between two colours in LUV space, which keeps the
// midpoint of a fade perceptually even rather than letting it darken the way a
// straight RGB blend does.
fn dye::Color Tween.lerp_color(&self, dye::Color from, dye::Color to) {
	return dye::blend_luv(from, to, self.value());
}

// alpha maps the tween onto the 1..255 range a fade wants. Both an Overlay's
// alpha and xray::Node.alpha read 0 as "opaque" rather than "invisible", so a
// fade-in must never emit 0 on its first frame; this clamps into 1..255 for
// you, which also keeps EASE_OUT_BACK's overshoot from wrapping past 255.
fn char Tween.alpha(&self) {
	double v = self.value();
	if (v < 0.0) v = 0.0;
	if (v > 1.0) v = 1.0;
	int a = 1 + (int)(254.0 * v + 0.5);
	if (a > 255) a = 255;
	return (char)a;
}