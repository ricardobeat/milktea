module milktea;

import dye;

// Animation helpers: an easing curve plus a Tween that carries a value to a
// target over a fixed time. Where a Spring's timing comes from its physics, a
// Tween's comes from its duration and easing — the right fit for a panel
// opening or a fade, where the length of the move is a design decision.
//
// A Tween is used the way a Spring is. It is plain data the model owns, and
// reading it never writes it: it stores where it set off from and when, and
// every read solves where it is from there. So update() is the only call that
// changes it and view() only reads. Each change also asks the runtime for
// frames until the run ends (see frames_until), so the model runs no timer:
//
//     // init()
//     self.open = tween(0, 180);
//
//     // update()
//     if (key == ' ') self.open.update(self.open.target == 0 ? 1 : 0);
//
//     // view()
//     if (self.open.value() > 0) ... .transition(slide_down(5), self.open)
//
// The plain calls read the frame clock, frame_ms(). Each has an _at twin
// taking the time explicitly, for tests and for code running outside a
// program.

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

// Tween is a value on its way to `target`. A zero-value Tween rests at 0.
struct Tween {
	sz duration_ms;
	Easing easing;
	double target;
	// The start every read solves from: the value at start_ms, when the tween
	// was last updated or set, and how long that run takes.
	double from;
	sz start_ms;
	sz run_ms;
}

// tween builds a tween resting at `at`, already on its target.
fn Tween tween(double at, sz duration_ms, Easing easing = Easing.EASE_OUT_CUBIC) {
	return { .duration_ms = duration_ms, .easing = easing, .target = at, .from = at };
}

// update sends the tween to a new target from wherever it is now, so a change
// of mind mid-flight carries on from the current value rather than jumping.
// A run takes duration_ms, except one that turns back toward where the
// current run began: that takes only as long as the tween has been running,
// so a half-open panel closes from half-way in half the time.
fn void Tween.update(&self, double target) => self.update_at(target, frame_ms());

fn void Tween.update_at(&self, double target, sz now_ms) {
	if (target == self.target) return;
	bool turning = self.moving_at(now_ms) && target == self.from;
	sz run = turning ? now_ms - self.start_ms : self.duration_ms;
	self.from     = self.value_at(now_ms);
	self.target   = target;
	self.start_ms = now_ms;
	self.run_ms   = run;
	frames_until(self.settles_at());
}

// set places the tween at `value` and keeps it there: a jump with no
// animation.
fn void Tween.set(&self, double value) => self.set_at(value, frame_ms());

fn void Tween.set_at(&self, double value, sz now_ms) {
	self.from     = value;
	self.target   = value;
	self.start_ms = now_ms;
	self.run_ms   = 0;
}

// value is where the tween is now. EASE_OUT_BACK carries it past the target
// mid-flight; see `ease`.
fn double Tween.value(self) => self.value_at(frame_ms());

fn double Tween.value_at(self, sz now_ms) {
	if (!self.moving_at(now_ms)) return self.target;
	// A read from before the start (a clock that stepped back) sees the start.
	double t = now_ms > self.start_ms ? (double)(now_ms - self.start_ms) / (double)self.run_ms : 0.0;
	return self.from + (self.target - self.from) * ease(self.easing, t);
}

// moving reports whether the tween has yet to reach its target.
fn bool Tween.moving(self) => self.moving_at(frame_ms());

fn bool Tween.moving_at(self, sz now_ms) => now_ms < self.settles_at();

// settles_at is when the current run ends, on the frame_ms() clock.
fn sz Tween.settles_at(self) => self.start_ms + self.run_ms;

// The helpers below map a tween running over 0..1 onto other ranges.

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