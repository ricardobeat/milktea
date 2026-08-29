module milktea;

import dye;

// Animation helpers: an easing curve plus a Tween that maps elapsed time onto
// a value. Animation in milktea is driven by the ordinary timer/message loop —
// a model arms `tick(FRAME_MS, &on_frame)`, advances its Tween on each frame
// message, and derives position/alpha/colour from it in `view()`. Nothing here
// touches the renderer or holds a clock of its own; a Tween is plain data the
// model owns, so it stays testable and costs nothing when no timer is armed.

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

// alpha maps the tween onto the 1..255 range an Overlay wants for a fade.
// Overlay treats alpha 0 as "opaque" rather than "invisible", so a fade-in
// must never emit 0 on its first frame; this clamps into 1..255 for you.
fn char Tween.alpha(&self) {
	double v = self.value();
	if (v < 0.0) v = 0.0;
	if (v > 1.0) v = 1.0;
	int a = 1 + (int)(254.0 * v + 0.5);
	if (a > 255) a = 255;
	return (char)a;
}