module tween_test;

import milktea;
import dye;
import std::math;

fn void assert_near(double got, double want, double tol = 0.0001, String what = "value") {
	assert(math::abs(got - want) <= tol, "%s: got %f, want %f", what, got, want);
}

fn void test_ease_endpoints_are_exact() @test {
	// Every curve must start at 0 and land exactly on 1, or an animation
	// settles slightly off its target.
	Easing[*] curves = {
		Easing.LINEAR,
		Easing.EASE_IN_QUAD,
		Easing.EASE_OUT_QUAD,
		Easing.EASE_IN_OUT_QUAD,
		Easing.EASE_IN_CUBIC,
		Easing.EASE_OUT_CUBIC,
		Easing.EASE_IN_OUT_CUBIC,
		Easing.EASE_OUT_BACK,
	};
	foreach (c : curves) {
		assert_near(milktea::ease(c, 0.0), 0.0, 0.0001, "start");
		assert_near(milktea::ease(c, 1.0), 1.0, 0.0001, "end");
	}
}

fn void test_ease_clamps_out_of_range_input() @test {
	assert_near(milktea::ease(Easing.EASE_OUT_CUBIC, -5.0), 0.0);
	assert_near(milktea::ease(Easing.EASE_OUT_CUBIC, 7.0), 1.0);
}

fn void test_linear_is_identity() @test {
	assert_near(milktea::ease(Easing.LINEAR, 0.25), 0.25);
	assert_near(milktea::ease(Easing.LINEAR, 0.5), 0.5);
}

fn void test_ease_out_decelerates() @test {
	// An out-curve covers more ground early than late: that is what makes it
	// read as decelerating. First quarter must beat the last quarter.
	double first = milktea::ease(Easing.EASE_OUT_CUBIC, 0.25);
	double last  = 1.0 - milktea::ease(Easing.EASE_OUT_CUBIC, 0.75);
	assert(first > last, "out-cubic should decelerate: %f vs %f", first, last);
	// And it must sit above the linear ramp throughout.
	assert(milktea::ease(Easing.EASE_OUT_CUBIC, 0.5) > 0.5, "out-cubic above linear at midpoint");
}

fn void test_ease_in_accelerates() @test {
	assert(milktea::ease(Easing.EASE_IN_CUBIC, 0.5) < 0.5, "in-cubic below linear at midpoint");
}

fn void test_ease_in_out_is_symmetric() @test {
	// f(t) + f(1-t) == 1 for a symmetric curve.
	double a = milktea::ease(Easing.EASE_IN_OUT_CUBIC, 0.3);
	double b = milktea::ease(Easing.EASE_IN_OUT_CUBIC, 0.7);
	assert_near(a + b, 1.0, 0.0001, "in-out symmetry");
	assert_near(milktea::ease(Easing.EASE_IN_OUT_CUBIC, 0.5), 0.5, 0.0001, "in-out midpoint");
}

fn void test_ease_out_back_overshoots() @test {
	// The "pop" is the point of this curve: it must exceed 1 somewhere.
	bool overshot = false;
	for (double t = 0.05; t < 1.0; t += 0.05) {
		if (milktea::ease(Easing.EASE_OUT_BACK, t) > 1.0) overshot = true;
	}
	assert(overshot, "ease-out-back should overshoot past 1.0");
}

// ── Tween ───────────────────────────────────────────────────────────────────

fn void test_tween_rests_where_it_is_built() @test {
	Tween tw = milktea::tween(3, 100, Easing.LINEAR);
	assert_near(tw.value_at(1000), 3.0, 0.0001, "at rest");
	assert(!tw.moving_at(1000), "not moving");
}

fn void test_zero_value_tween_rests_at_zero() @test {
	Tween tw;
	assert_near(tw.value_at(1000), 0.0, 0.0001, "at rest");
	assert(!tw.moving_at(1000), "not moving");
}

fn void test_update_runs_to_the_target_over_the_duration() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 1000);
	assert_near(tw.value_at(1000), 0.0, 0.0001, "not started");
	assert(tw.moving_at(1050), "still running halfway");
	assert_near(tw.value_at(1050), 0.5, 0.0001, "halfway by the clock");
	assert(!tw.moving_at(1100), "arrived at the duration");
	assert(tw.settles_at() == 1100, "settles at the end of the run");
	assert_near(tw.value_at(1100), 1.0, 0.0001, "at the target");
}

fn void test_update_spans_any_range() @test {
	Tween tw = milktea::tween(10, 100, Easing.LINEAR);
	tw.update_at(-10, 1000);
	assert_near(tw.value_at(1025), 5.0, 0.0001, "a quarter of the way down");
}

fn void test_reads_never_change_it() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 1000);
	tw.value_at(1090);
	assert_near(tw.value_at(1050), 0.5, 0.0001, "a later read does not move an earlier one");
}

fn void test_a_late_frame_reads_the_target() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 1000);
	assert_near(tw.value_at(9999), 1.0, 0.0001, "settled, not overrun");
}

fn void test_a_backwards_clock_reads_the_start() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 5000);
	assert_near(tw.value_at(4000), 0.0, 0.0001, "still at the start");
}

fn void test_zero_duration_arrives_at_once() @test {
	Tween tw = milktea::tween(0, 0, Easing.EASE_OUT_CUBIC);
	tw.update_at(1, 1000);
	assert(!tw.moving_at(1000), "nothing to wait for");
	assert_near(tw.value_at(1000), 1.0, 0.0001, "already there");
}

fn void test_updating_to_the_same_target_keeps_the_run() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 1000);
	tw.update_at(1, 1050);
	assert(tw.settles_at() == 1100, "the run is not restarted");
}

fn void test_turning_back_takes_as_long_as_it_ran() @test {
	Tween tw = milktea::tween(0, 100, Easing.EASE_OUT_CUBIC);
	tw.update_at(1, 1000);
	double at_turn = tw.value_at(1030);
	tw.update_at(0, 1030);
	assert_near(tw.value_at(1030), at_turn, 0.0001, "no jump at the turn");
	assert(tw.moving_at(1059), "the way back takes as long as the way out did");
	assert(!tw.moving_at(1060), "and no longer");
	assert_near(tw.value_at(1060), 0.0, 0.0001, "back at the start");
}

fn void test_a_new_target_mid_flight_carries_on_from_there() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(10, 1000);
	tw.update_at(20, 1050);
	assert_near(tw.value_at(1050), 5.0, 0.0001, "no jump at the change");
	assert(tw.settles_at() == 1150, "a fresh run toward the new target");
	assert_near(tw.value_at(1100), 12.5, 0.0001, "halfway from 5 to 20");
}

fn void test_showing_lasts_until_it_comes_to_rest_at_zero() @test {
	// Outside a program showing() reads the live clock, so each run is placed
	// well clear of it: one long enough to still be going, one long finished.
	sz now = milktea::frame_ms();
	Tween tw = milktea::tween(0, 100_000, Easing.LINEAR);
	assert(!tw.showing(), "resting at 0 is hidden");
	tw.update_at(1, now);
	assert(tw.showing(), "on its way in");
	tw.set_at(1, now);
	assert(tw.showing(), "in");
	tw.update_at(0, now);
	assert(tw.showing(), "still on its way out");
	tw = milktea::tween(1, 100, Easing.LINEAR);
	tw.update_at(0, now - 10_000);
	assert(!tw.showing(), "gone once it lands");
}

fn void test_set_jumps() @test {
	Tween tw = milktea::tween(0, 100, Easing.LINEAR);
	tw.update_at(1, 1000);
	tw.set_at(0.25, 1050);
	assert(!tw.moving_at(1050), "not moving");
	assert_near(tw.value_at(1050), 0.25, 0.0001, "where it was put");
	assert_near(tw.target, 0.25, 0.0001, "and that is its target");
}

fn void test_lerp_rounds_by_value() @test {
	Tween tw = milktea::tween(0.5, 100, Easing.LINEAR);
	assert(tw.lerp(0, 10) == 5, "got %d", tw.lerp(0, 10));
	assert(tw.lerp(-5, 0) == -3, "rounds away from zero, got %d", tw.lerp(-5, 0));
	assert_near(tw.lerpf(2.0, 4.0), 3.0);
}

fn void test_alpha_clamps_overshoot() @test {
	// EASE_OUT_BACK exceeds 1.0 mid-flight; alpha must clamp to 255 rather
	// than wrapping. The sweep starts past the first frame: at 0 the value is
	// exactly 0, the invisible end state of a fade.
	Tween tw = milktea::tween(0, 100, Easing.EASE_OUT_BACK);
	tw.update_at(1, 0);
	for (sz i = 5; i <= 100; i += 5) {
		char a = milktea::tween(tw.value_at(i), 0).alpha();
		assert(a >= 1 && a <= 255, "alpha stays in 1..255, got %d at %d", (sz)a, i);
	}
	assert(milktea::tween(0, 0).alpha() == 0, "value 0 is invisible");
	assert(milktea::tween(1, 0).alpha() == 255, "value 1 is opaque");
}

fn void test_lerp_color_interpolates() @test {
	dye::Color red  = dye::color_rgb(255, 0, 0);
	dye::Color blue = dye::color_rgb(0, 0, 255);

	dye::Color at_start = milktea::tween(0, 100).lerp_color(red, blue);
	assert(at_start.r == 255 && at_start.b == 0, "starts at from");

	dye::Color at_end = milktea::tween(1, 100).lerp_color(red, blue);
	assert(at_end.b == 255 && at_end.r == 0, "ends at to");
}
