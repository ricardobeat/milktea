// spotlight — a field of dots that swells toward the mouse.
//
// Every dot measures its distance to a soft light that chases the cursor.
// Near the light a dot grows (· ∙ • ●) and warms in colour; far away it rests
// as a dim speck. Two kinds of easing shape the motion:
//
//   in space — the falloff from the light's centre to its edge runs through
//              an ease curve, so the pool has a bright core and a soft rim;
//   in time  — the light rides a spring after the cursor, and holding a
//              button blooms its radius outward for as long as it stays down.
//
// update() says where things should go and view() only reads where they are.
// The springs keep frames coming until they settle, and a held button keeps
// its own timer, since a bloom has no end. A resting spotlight costs nothing.
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

const double RADIUS      = 34.0; // light radius at rest, in columns
const double BLOOM_SPEED = 30.0; // columns per second the radius grows while held
const double BLOOM_RAMP  = 0.6;  // seconds for the bloom to reach full speed

// The light trails the cursor without overshooting it; the radius springs
// back from a bloom with a little bounce, dipping just under its resting size.
fn milktea::SpringParams follow_feel() => milktea::spring_feel(500);
fn milktea::SpringParams radius_feel() => milktea::spring_feel(650, 0.2);

// Dots from smallest to largest; the light picks one by intensity.
const String[*] DOTS = { "·", "∙", "•", "●" };

// The colour ramp a dot walks as it lights up: night → tide → glow.
const String COLOR_REST = "#2a2f3a";
const String COLOR_MID  = "#4f7cac";
const String COLOR_HOT  = "#ffe6a7";

// ── Model ────────────────────────────────────────────────────────────────────

struct Model {
	xray::ScreenBuffer* canvas;
	sz width;
	sz height;

	milktea::Spring light_x;
	milktea::Spring light_y;
	milktea::Spring radius; // the resting radius; a bloom adds on top of it

	bool holding;  // a mouse button is down, so the bloom keeps growing
	sz pressed_at; // when it went down

	bool seen_mouse; // the light has been aimed by the cursor at least once
}

fn milktea::Cmd Model.init(&self) @dynamic {
	self.canvas = xray::new_screen_buffer(1, 1);
	self.radius = milktea::spring(RADIUS, radius_feel());
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case WINDOW_SIZE:
			self.resize(msg.window_size.width, msg.window_size.height);
		case MOUSE:
			return self.follow(msg.mouse);
		case TICK:
			// The bloom's frame: the only timer this program runs.
			if (self.holding) return milktea::tick(milktea::FRAME_MS);
		case KEY:
			if (is_quit(msg.key)) return milktea::quit();
		default:
	}
	return null;
}

fn void Model.resize(&self, sz w, sz h) {
	self.width  = w;
	self.height = h;
	self.canvas.resize(w, h);
	// Until the cursor shows up, rest the light in the middle of the screen.
	if (!self.seen_mouse) {
		self.light_x = milktea::spring(w / 2.0, follow_feel());
		self.light_y = milktea::spring(h / 2.0, follow_feel());
	}
}

fn milktea::Cmd Model.follow(&self, milktea::MouseMsg m) {
	self.seen_mouse = true;
	self.light_x.update(m.col);
	self.light_y.update(m.row);

	if (is_wheel(m.button)) return null;
	switch (m.action) {
		case MOUSE_PRESS:
			if (self.holding) return null;
			self.holding    = true;
			self.pressed_at = milktea::frame_ms();
			// A bloom grows for as long as the button stays down, with nothing
			// to say when it ends, so it runs a frame timer until the release.
			return milktea::tick(milktea::FRAME_MS);
		case MOUSE_RELEASE:
			if (!self.holding) return null;
			// Hand the bloom back to the spring as it stands — its size and the
			// speed it was growing at — so the light carries on outward for a
			// moment before it is reeled back in.
			double held = self.held();
			self.radius.set(self.radius.value() + bloom(held), self.radius.velocity() + bloom_speed(held));
			self.holding = false;
		default:
	}
	return null;
}

// Seconds the button has been down.
fn double Model.held(&self) => (double)(milktea::frame_ms() - self.pressed_at) / 1000.0;

fn double Model.light_radius(&self) {
	double r = self.radius.value();
	return self.holding ? r + bloom(self.held()) : r;
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

// How fast the bloom is spreading after `held` seconds: bloom's slope.
fn double bloom_speed(double held) {
	if (held >= BLOOM_RAMP) return BLOOM_SPEED;
	double u = held / BLOOM_RAMP;
	return BLOOM_SPEED * u * u;
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
	double lx = self.light_x.value();
	double ly = self.light_y.value();
	double radius = self.light_radius();

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
	if (catch err = milktea::@run_program(&model, {
		.alt_screen = true,
		.mouse_mode = milktea::MouseMode.MOUSE_MODE_ALL_MOTION,
	})) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
