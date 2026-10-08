module milktea;

import dye;

// Animation helpers: an easing curve plus a Tween that maps elapsed time onto
// a value. A Tween is plain data the model owns, and it runs in one of two
// modes.
//
// Clock-driven is the usual one, and needs no frame messages at all: start it
// in update() with `tween_at(frame_ms(), ms)`. It records when it started, and
// every read solves its progress from frame_ms(), so view() only reads it. Starting
// it also asks the runtime for frames until it ends (see frames_until), so
// the model runs no timer either.
//
// Step-driven is for a model that wants the frames itself: build it with
// `tween()`, advance it with `step()` on each frame message, and re-arm
// `tick()` while step() reports the animation is still running.
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
	sz elapsed_ms; // a step-driven tween's progress
	sz duration_ms;
	Easing easing;
	bool reverse; // play from the target back to the start
	// A clock-driven tween reads its progress from frame_ms() against started_ms,
	// on the same clock; see tween_at.
	bool clocked;
	sz started_ms;
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
// `now`. Pass milktea::frame_ms() from update() when the animation begins:
// 
//     self.anim = tween_at(milktea::frame_ms(), 260);
// 
// The tween then needs no frame messages and no timer: the runtime paints
// every frame until it ends, and each read solves where it is from frame_ms().
// A clock-driven tween ignores step().
fn Tween tween_at(sz now, sz duration_ms, Easing easing = Easing.EASE_OUT_CUBIC, bool reverse = false) {
	frames_until(now + duration_ms);
	return { .duration_ms = duration_ms, .easing = easing, .reverse = reverse, .clocked = true, .started_ms = now };
}

// reversed turns the tween around from wherever it is, keeping its duration
// and easing: a modal half-way open closes from half-way rather than jumping.
// The result is clock-driven from frame_ms(), whichever mode this one ran in, and
// a tween that never started reverses into one already at its start — so
// `tween(180).reversed()` is a closed panel waiting to be opened.
fn Tween Tween.reversed(self) => self.reversed_at(frame_ms());

fn Tween Tween.reversed_at(self, sz now) {
	// The way back covers what is left of the way out, so the tween resumes
	// from the same point: elapsed and remaining swap.
	sz left = self.duration_ms - self.elapsed_at(now);
	return tween_at(now - left, self.duration_ms, self.easing, !self.reverse);
}

// elapsed_at is how far into its duration the tween is at `now`: the clock
// for a clock-driven tween, the steps taken for a step-driven one.
fn sz Tween.elapsed_at(self, sz now) {
	if (!self.clocked) return self.elapsed_ms;
	sz delta = now - self.started_ms;
	// A time before the start reads as "not begun", a late one as finished.
	if (delta < 0) return 0;
	return delta > self.duration_ms ? self.duration_ms : delta;
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
fn bool Tween.done(self) => self.done_at(frame_ms());
fn bool Tween.done_at(self, sz now) => self.elapsed_at(now) >= self.duration_ms;

// showing reports whether whatever this tween presents is on screen: on its
// way in, in, or still on its way out.
fn bool Tween.showing(self) => self.showing_at(frame_ms());
fn bool Tween.showing_at(self, sz now) => !self.reverse || !self.done_at(now);

// restart rewinds the tween to its first frame, keeping duration and easing.
// A clock-driven tween starts over from frame_ms().
fn void Tween.restart(&self) {
	self.elapsed_ms = 0;
	if (self.clocked) *self = tween_at(frame_ms(), self.duration_ms, self.easing, self.reverse);
}

// value returns the eased progress in [0,1] (EASE_OUT_BACK may exceed it
// mid-flight; see `ease`). A zero duration yields its end — an instant
// animation is one that is already finished, never a divide by zero.
fn double Tween.value(self) => self.value_at(frame_ms());

fn double Tween.value_at(self, sz now) {
	double t = self.duration_ms == 0 ? 1.0 : (double)self.elapsed_at(now) / (double)self.duration_ms;
	if (self.reverse) t = 1.0 - t;
	return ease(self.easing, t);
}

// lerp interpolates between two ints by this tween's current value, rounding
// to nearest. Handy for a slide: `t.lerp(start_y, target_y)`.
fn sz Tween.lerp(self, sz from, sz to) {
	double v   = self.value();
	double out = (double)from + ((double)to - (double)from) * v;
	return (sz)(out < 0.0 ? out - 0.5 : out + 0.5);
}

// lerpf interpolates between two doubles by this tween's current value.
fn double Tween.lerpf(self, double from, double to) {
	return from + (to - from) * self.value();
}

// lerp_color interpolates between two colours in LUV space, which keeps the
// midpoint of a fade perceptually even rather than letting it darken the way a
// straight RGB blend does.
fn dye::Color Tween.lerp_color(self, dye::Color from, dye::Color to) {
	return dye::blend_luv(from, to, self.value());
}

// alpha maps the tween onto 0..255, where 0 is fully invisible and 255 fully
// opaque. A fade's end state lands on exactly 0 — paint skips a node at alpha
// 0, so a fade-out's final frame leaves no trace behind rather than a
// near-invisible 1/255 remnant. Values in between round to nearest, and
// EASE_OUT_BACK's overshoot past 1 is clamped to 255 so it cannot wrap.
fn char Tween.alpha(self) {
	double v = self.value();
	if (v <= 0.0) return 0;
	if (v >= 1.0) return 255;
	sz a = 1 + (sz)(254.0 * v + 0.5);
	return (char)a;
}