// spotlight — a field of dots that swells toward the mouse.
//
// Every dot measures its distance to a soft light that chases the cursor.
// Near the light a dot grows (· ∙ • ●) and warms in colour; far away it rests
// as a dim speck. Two kinds of easing shape the motion:
//
//   in space — the falloff from the light's centre to its edge runs through
//              an ease curve, so the pool has a bright core and a soft rim;
//   in time  — the light rides a critically damped spring after the cursor,
//              and holding a button blooms its radius outward for as long as
//              the button stays down.
//
// The frame timer only runs while something is still moving, so a resting
// spotlight costs nothing.
module spotlight;

import milktea;
import xray;
import dye;
import glaze;
import std::io;
import std::math;

// ── Tuning ───────────────────────────────────────────────────────────────────

const sz DOT_SPACING_X = 4; // columns between dots
const sz DOT_SPACING_Y = 2; // rows between dots — half of X, since cells are tall

const double CELL_ASPECT = 2.0; // a cell is about twice as tall as it is wide

const double RADIUS      = 34.0;  // light radius at rest, in columns
const double BLOOM_SPEED = 30.0;  // columns per second the radius grows while held
const double BLOOM_RAMP  = 0.6;   // seconds for the bloom to reach full speed
const double FOLLOW_TIME = 0.16;  // how long the light lags the cursor, in seconds
const double RADIUS_TIME = 0.22;  // how softly the radius chases its target

// Dots from smallest to largest; the light picks one by intensity.
const String[*] DOTS = { "·", "∙", "•", "●" };

// The colour ramp a dot walks as it lights up: night → tide → glow.
const String COLOR_REST = "#2a2f3a";
const String COLOR_MID  = "#4f7cac";
const String COLOR_HOT  = "#ffe6a7";

// ── Spring ───────────────────────────────────────────────────────────────────

// A value that eases toward a target on a critically damped spring: it closes
// in as fast as it can without overshooting. Unlike restarting a tween on every
// mouse event, a spring carries its velocity across retargets, so a stream of
// new targets blends into one smooth curve instead of a series of jolts.
struct Spring {
	double value;
	double velocity;
	double target;
	double smooth_time; // roughly the seconds it takes to settle
}

fn Spring spring(double at, double smooth_time) {
	return { .value = at, .target = at, .smooth_time = smooth_time };
}

// Advance by `dt` seconds using the spring's exact solution, so the motion
// looks the same at any frame rate and never blows up on a long frame.
fn void Spring.step(&self, double dt) {
	double omega  = 2.0 / self.smooth_time;
	double offset = self.value - self.target;
	double drift  = self.velocity + omega * offset;
	double decay  = math::exp(-omega * dt);
	self.value    = self.target + (offset + drift * dt) * decay;
	self.velocity = (self.velocity - omega * drift * dt) * decay;
	if (self.at_rest()) {
		self.value    = self.target;
		self.velocity = 0.0;
	}
}

fn bool Spring.at_rest(&self) {
	return math::abs(self.value - self.target) < 0.01 && math::abs(self.velocity) < 0.01;
}

// ── Model ────────────────────────────────────────────────────────────────────

struct Model {
	xray::ScreenBuffer* canvas;
	sz width;
	sz height;

	Spring light_x;
	Spring light_y;
	Spring radius;

	bool holding;     // a mouse button is down, so the bloom keeps growing
	double held_for;  // seconds the button has been down
	sz last_frame_ms; // when the previous frame was stepped; 0 while at rest

	bool animating;  // a frame timer is armed
	bool seen_mouse; // the light has been aimed by the cursor at least once
}

fn milktea::Cmd Model.init(&self) @dynamic {
	self.canvas = xray::new_screen_buffer(1, 1);
	self.radius = spring(RADIUS, RADIUS_TIME);
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case WINDOW_SIZE:
			self.resize(msg.window_size.width, msg.window_size.height);
		case MOUSE:
			self.follow(msg.mouse);
		case TICK:
			self.animating = false; // this frame's timer has fired
			self.step();
		case KEY:
			if (is_quit(msg.key)) return milktea::quit();
		default:
	}
	return self.keep_animating();
}

fn void Model.resize(&self, sz w, sz h) {
	self.width  = w;
	self.height = h;
	self.canvas.resize(w, h);
	// Until the cursor shows up, rest the light in the middle of the screen.
	if (!self.seen_mouse) {
		self.light_x = spring((double)w / 2.0, FOLLOW_TIME);
		self.light_y = spring((double)h / 2.0, FOLLOW_TIME);
	}
}

fn void Model.follow(&self, milktea::MouseMsg m) {
	self.seen_mouse = true;
	self.light_x.target = (double)m.col;
	self.light_y.target = (double)m.row;

	if (is_wheel(m.button)) return;
	switch (m.action) {
		case MOUSE_PRESS:
			self.holding  = true;
			self.held_for = 0.0;
		case MOUSE_RELEASE:
			self.holding = false;
			self.radius.target = RADIUS;
		default:
	}
}

// Advance everything by the real time since the last frame, so a late tick
// moves the light further rather than slowing it down.
fn void Model.step(&self) {
	sz now = milktea::time_ms();
	// Waking from rest there is no previous frame, so assume a nominal one.
	sz elapsed = self.last_frame_ms == 0 ? milktea::FRAME_MS : now - self.last_frame_ms;
	double dt = math::min((double)elapsed / 1000.0, 0.1); // never leap on a stall
	self.last_frame_ms = now;

	if (self.holding) {
		self.held_for += dt;
		self.radius.target = RADIUS + bloom(self.held_for);
	}
	self.light_x.step(dt);
	self.light_y.step(dt);
	self.radius.step(dt);
}

// How far the bloom has spread after `held` seconds. The growth eases in over
// BLOOM_RAMP and then carries on at BLOOM_SPEED — there is no ceiling. A cubic
// ease-in covering a third of the full-speed distance meets the straight line
// at exactly that speed, so the hand-off has no kink.
fn double bloom(double held) {
	double ramp = BLOOM_SPEED * BLOOM_RAMP / 3.0;
	if (held < BLOOM_RAMP) return ramp * milktea::ease(EASE_IN_CUBIC, held / BLOOM_RAMP);
	return ramp + BLOOM_SPEED * (held - BLOOM_RAMP);
}

fn bool Model.settled(&self) {
	if (self.holding) return false;
	return self.light_x.at_rest() && self.light_y.at_rest() && self.radius.at_rest();
}

// Arm the frame timer when there is motion to show and none is armed yet.
fn milktea::Cmd Model.keep_animating(&self) {
	if (self.animating) return null;
	if (self.settled()) {
		self.last_frame_ms = 0;
		return null;
	}
	self.animating = true;
	return milktea::tick(milktea::FRAME_MS);
}

fn bool is_wheel(milktea::MouseButton b) => b == MOUSE_WHEEL_UP || b == MOUSE_WHEEL_DOWN;

fn bool is_quit(milktea::KeyMsg k) {
	if (k.code == CTRL_C || k.code == ESC) return true;
	return k.code == RUNE && k.rune == 'q';
}

// ── View ─────────────────────────────────────────────────────────────────────

fn milktea::View Model.view(&self) @dynamic {
	xray::ScreenBuffer* canvas = self.canvas;
	canvas.clear();

	// The dot field takes the screen; a status row underneath holds the hint.
	xray::Rect[2] zones;
	xray::layout_v(xray::new_rect(0, 0, self.width, self.height), { xray::fill(1), xray::cells(1) }, zones[..]);

	self.draw_field(canvas, zones[0]);
	draw_hint(canvas, zones[1]);
	return canvas.view();
}

fn void Model.draw_field(&self, xray::ScreenBuffer* canvas, xray::Rect area) {
	double lx = self.light_x.value;
	double ly = self.light_y.value;
	double radius = self.radius.value;

	// Centre the lattice so the margins match on every side.
	sz x0 = area.x + (area.w - 1) % DOT_SPACING_X / 2;
	sz y0 = area.y + (area.h - 1) % DOT_SPACING_Y / 2;

	for (sz row = y0; row < area.bottom(); row += DOT_SPACING_Y) {
		for (sz col = x0; col < area.right(); col += DOT_SPACING_X) {
			double dx = (double)col - lx;
			double dy = ((double)row - ly) * CELL_ASPECT;
			double glow = intensity(math::sqrt(dx * dx + dy * dy), radius);
			draw_dot(canvas, col, row, glow);
		}
	}
}

// How brightly a dot `dist` columns from the light shines: 1 at the centre,
// 0 at the rim and beyond. The ease turns a linear ramp into a pool with a
// broad bright core and a soft shoulder.
fn double intensity(double dist, double radius) {
	if (radius <= 0.0) return 0.0;
	double t = 1.0 - dist / radius;
	return milktea::ease(EASE_IN_OUT_CUBIC, t);
}

fn void draw_dot(xray::ScreenBuffer* canvas, sz col, sz row, double glow) {
	sz size = (sz)(glow * (double)(DOTS.len - 1) + 0.5);
	xray::Style style = xray::default_style().set_fg(dot_color(glow));
	canvas.set_string(col, row, DOTS[size], style);
}

// Walk the three-stop ramp: the lower half of the glow cools from rest into
// the tide colour, the upper half heats it up to the glow.
fn dye::Color dot_color(double glow) {
	dye::Color rest = dye::color_hex(COLOR_REST);
	dye::Color mid  = dye::color_hex(COLOR_MID);
	dye::Color hot  = dye::color_hex(COLOR_HOT);
	if (glow < 0.5) return dye::blend_luv(rest, mid, glow * 2.0);
	return dye::blend_luv(mid, hot, glow * 2.0 - 1.0);
}

// Centre the hint in its row: a column sized to the text, with equal fills
// either side taking up the slack.
fn void draw_hint(xray::ScreenBuffer* canvas, xray::Rect row) {
	const String HINT = "move the mouse · hold to bloom · q to quit";
	xray::Rect[3] cols;
	xray::layout_h(row, { xray::fill(1), xray::cells(glaze::string_width(HINT)), xray::fill(1) }, cols[..]);
	xray::Style style = xray::default_style().set_fg(dye::color_hex("#5c6370"));
	canvas.draw_string_in_rect(cols[1], HINT, style);
}

// ── Main ─────────────────────────────────────────────────────────────────────

fn int main() {
	Model model;
	milktea::enable_mouse(all_motion: true);
	defer milktea::disable_mouse(all_motion: true);

	if (catch err = milktea::@run_program(&model, { .alt_screen = true })) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
