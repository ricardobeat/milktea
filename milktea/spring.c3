module milktea;

import std::math;

// Springs: a value that eases toward a target the way a weight on a spring
// would. Where a Tween runs a fixed course over a fixed time, a spring chases
// a target that can move at any moment — a cursor, a scroll position, a
// selection — and carries its momentum through every change of target, so a
// stream of new targets blends into one smooth path instead of a series of
// restarts.
//
// A Spring is plain data the model owns, and reading it never writes it. It
// does not store where it *is*; it stores where it was and how fast it was
// moving when last told where to go, and every read solves the spring's
// motion from there. So update() is the only call that changes it, view()
// only reads, and how often frames happen to land has no effect on the path.
// Each change also works out when the spring will settle and asks the runtime
// for frames until then (see frames_until), so the model runs no timer:
//
//     // update()
//     if (msg.kind == MOUSE) self.x.update(msg.mouse.col);
//
//     // view()
//     double x = self.x.value();
//
// The plain calls read the frame clock, frame_ms(). Each has an _at twin taking the
// time explicitly, for tests and for code running outside a program.

// ── Parameters ───────────────────────────────────────────────────────────────

// SpringParams is the physics of a spring with a unit mass: how hard it pulls
// toward the target, and how much drag holds it back. Their balance decides
// the character — light damping overshoots and wobbles, heavy damping creeps
// in slowly, and the point between (critical damping) is the fastest path in
// that never overshoots.
//
// Few callers want to tune these directly: spring_feel and spring_overshoot
// derive them from a duration and a bounce, and the presets cover most uses.
struct SpringParams {
	double stiffness; // pull toward the target, per unit of distance
	double damping;   // drag, per unit of velocity
}

// spring_physics builds parameters from raw stiffness and damping.
fn SpringParams spring_physics(double stiffness, double damping) {
	return { .stiffness = stiffness, .damping = damping };
}

// spring_feel builds parameters from how long a move should take, roughly,
// and how much it should bounce. bounce 0 settles without overshooting;
// between 0 and 1 it overshoots and wobbles, more as it nears 1; below 0 it
// is overdamped and eases in more lazily still.
//
// The duration sets the spring's natural period, which is what a move feels
// like it takes: a critically damped spring has covered about 98% of the way
// by then. These are the conventions of SwiftUI's Spring(duration:bounce:).
fn SpringParams spring_feel(sz duration_ms, double bounce = 0.0) {
	double period = math::max((double)duration_ms, 1.0) / 1000.0;
	double omega  = 2.0 * math::PI / period;
	double ratio  = bounce >= 0.0 ? 1.0 - bounce : 1.0 / (1.0 + bounce);
	return { .stiffness = omega * omega, .damping = 2.0 * ratio * omega };
}

// spring_overshoot builds parameters that swing past the target by
// `overshoot` of the distance travelled — 0.1 is 10% — before settling.
// 0 overshoots not at all, the same as spring_feel with no bounce.
fn SpringParams spring_overshoot(sz duration_ms, double overshoot) {
	if (overshoot <= 0.0) return spring_feel(duration_ms);
	// The peak of an underdamped spring is exp(-ζπ / √(1-ζ²)) past the target;
	// solving that for the damping ratio ζ gives the bounce that reaches it.
	double ln_os = math::ln(math::min(overshoot, 0.999));
	double ratio = -ln_os / math::sqrt(math::PI * math::PI + ln_os * ln_os);
	return spring_feel(duration_ms, 1.0 - ratio);
}

// The presets follow SwiftUI's: smooth never overshoots, snappy barely does,
// bouncy visibly does.
fn SpringParams spring_smooth() => spring_feel(500);
fn SpringParams spring_snappy() => spring_feel(500, 0.15);
fn SpringParams spring_bouncy() => spring_feel(500, 0.3);

// ── Spring ───────────────────────────────────────────────────────────────────

// How close to the target, and how slow, a spring must be to count as at rest
// — in the units of the value itself. Fine enough for cell positions and
// radii; a spring over 0..1 wants a smaller one, set through Spring.rest.
const double SPRING_REST = 0.01;

struct Spring {
	SpringParams params;
	double target;
	// The start every read solves from: the value and velocity (units per
	// second) at start_ms, when the spring was last updated or set.
	double start_value;
	double start_velocity;
	sz start_ms;
	double rest; // see SPRING_REST
}

// spring builds a spring resting at `at`, already on its target.
fn Spring spring(double at, SpringParams params) {
	return { .params = params, .target = at, .start_value = at, .rest = SPRING_REST };
}

// update points the spring at a new target from wherever it is now, keeping
// its velocity, so a change of mind mid-flight bends the path rather than
// breaking it.
fn void Spring.update(&self, double target) => self.update_at(target, frame_ms());

fn void Spring.update_at(&self, double target, sz now_ms) {
	SpringState s = self.state_at(now_ms);
	self.start_value    = s.value;
	self.start_velocity = s.velocity;
	self.start_ms       = now_ms;
	self.target         = target;
	frames_until(self.settles_at());
}

// set places the spring at `value`, moving at `velocity` units per second,
// keeping its target: a jump with no animation when the velocity is 0, or a
// fling that the spring then reels back in.
fn void Spring.set(&self, double value, double velocity = 0.0) => self.set_at(value, velocity, frame_ms());

fn void Spring.set_at(&self, double value, double velocity, sz now_ms) {
	self.start_value    = value;
	self.start_velocity = velocity;
	self.start_ms       = now_ms;
	frames_until(self.settles_at());
}

// value is where the spring is now.
fn double Spring.value(self) => self.state_at(frame_ms()).value;

fn double Spring.value_at(self, sz now_ms) => self.state_at(now_ms).value;

// velocity is how fast the spring is moving now, in units per second.
fn double Spring.velocity(self) => self.state_at(frame_ms()).velocity;

fn double Spring.velocity_at(self, sz now_ms) => self.state_at(now_ms).velocity;

// moving reports whether the spring has yet to settle — the test a view uses
// to decide whether it needs another frame.
fn bool Spring.moving(self) => self.moving_at(frame_ms());

fn bool Spring.moving_at(self, sz now_ms) {
	SpringState s = self.state_at(now_ms);
	return math::abs(s.value - self.target) > self.rest || math::abs(s.velocity) > self.rest;
}

// The longest a spring is followed when working out where it settles. Past
// this a spring is too slow to be animating anything; it simply lands on
// whatever frame comes next.
const sz SPRING_SETTLE_LIMIT_MS @private = 30_000;

// settles_at is when the spring comes to rest, on the frame_ms() clock: the first
// frame at which it no longer counts as moving. A spring already at rest
// settles at its start.
fn sz Spring.settles_at(self) {
	// Walk the solved path a frame at a time. A few dozen closed-form reads per
	// change is cheap, and it asks exactly the question moving() answers, so
	// the frames stop when the view would stop seeing any change.
	for (sz t = self.start_ms; t < self.start_ms + SPRING_SETTLE_LIMIT_MS; t += FRAME_MS) {
		if (!self.moving_at(t)) return t;
	}
	return self.start_ms + SPRING_SETTLE_LIMIT_MS;
}

// ── Solving ──────────────────────────────────────────────────────────────────

struct SpringState @private {
	double value;
	double velocity;
}

// state_at solves the spring exactly rather than stepping it, so the path is
// the same at any frame rate and a long stall cannot make it blow up. Each of
// the three damping regimes has its own closed form.
fn SpringState Spring.state_at(self, sz now_ms) {
	double k = self.params.stiffness;
	double c = self.params.damping;
	// No pull at all: nothing will ever move it toward the target.
	if (k <= 0.0) return { self.start_value, 0.0 };

	// A read from before the start (a clock that stepped back) sees the start.
	double t      = now_ms > self.start_ms ? (double)(now_ms - self.start_ms) / 1000.0 : 0.0;
	double offset = self.start_value - self.target;
	double v0     = self.start_velocity;
	double omega  = math::sqrt(k);
	double ratio  = c / (2.0 * omega);

	if (math::abs(ratio - 1.0) < 1e-6) {
		// Critically damped: the fastest approach that never crosses the target.
		double decay = math::exp(-omega * t);
		double drift = v0 + omega * offset;
		return {
			self.target + (offset + drift * t) * decay,
			(v0 - omega * drift * t) * decay,
		};
	}

	if (ratio < 1.0) {
		// Underdamped: a decaying oscillation about the target.
		double wd    = omega * math::sqrt(1.0 - ratio * ratio);
		double zw    = ratio * omega;
		double decay = math::exp(-zw * t);
		double b     = (v0 + zw * offset) / wd;
		double cos   = math::cos(wd * t);
		double sin   = math::sin(wd * t);
		return {
			self.target + decay * (offset * cos + b * sin),
			decay * ((b * wd - zw * offset) * cos - (offset * wd + zw * b) * sin),
		};
	}

	// Overdamped: two decaying exponentials, one slow and one fast.
	double spread = omega * math::sqrt(ratio * ratio - 1.0);
	double slow   = -ratio * omega + spread;
	double fast   = -ratio * omega - spread;
	double c_fast = (v0 - slow * offset) / (fast - slow);
	double c_slow = offset - c_fast;
	double e_slow = math::exp(slow * t);
	double e_fast = math::exp(fast * t);
	return {
		self.target + c_slow * e_slow + c_fast * e_fast,
		c_slow * slow * e_slow + c_fast * fast * e_fast,
	};
}
