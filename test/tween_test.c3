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

fn void test_tween_steps_to_completion() @test {
	Tween tw = milktea::tween(100, Easing.LINEAR);
	assert(!tw.done(), "fresh tween is not done");
	assert_near(tw.value(), 0.0, 0.0001, "starts at 0");

	assert(tw.step(50), "still running at halfway");
	assert_near(tw.value(), 0.5, 0.0001, "halfway");

	// The final step returns false — that is the signal to stop re-arming.
	assert(!tw.step(50), "step returns false on the frame it completes");
	assert(tw.done(), "done after full duration");
	assert_near(tw.value(), 1.0, 0.0001, "ends at 1");
}

fn void test_tween_clamps_overshooting_step() @test {
	// A late frame must not push elapsed past duration and wrap the value.
	Tween tw = milktea::tween(100, Easing.LINEAR);
	tw.step(500);
	assert(tw.elapsed_ms == 100, "elapsed clamped to duration, got %d", tw.elapsed_ms);
	assert_near(tw.value(), 1.0, 0.0001, "clamped value");
}

fn void test_zero_duration_is_already_finished() @test {
	// Guards the divide-by-zero in value().
	Tween tw = milktea::tween(0, Easing.EASE_OUT_CUBIC);
	assert(tw.done(), "zero-duration tween is done");
	assert_near(tw.value(), 1.0, 0.0001, "zero duration reads as complete");
}

fn void test_zero_value_tween_is_finished() @test {
	// An un-initialized struct field should render at its target, not its
	// start, so a forgotten init doesn't leave a widget stuck invisible.
	Tween tw;
	assert(tw.done(), "zero-value tween is done");
	assert_near(tw.value(), 1.0, 0.0001, "zero-value reads as complete");
}

fn void test_reverse_runs_backwards() @test {
	Tween tw = milktea::tween_reversed(100, Easing.LINEAR);
	assert_near(tw.value(), 1.0, 0.0001, "reversed starts at the target");
	tw.step(100);
	assert_near(tw.value(), 0.0, 0.0001, "reversed ends at the start");
}

fn void test_restart_rewinds() @test {
	Tween tw = milktea::tween(100, Easing.LINEAR);
	tw.step(100);
	assert(tw.done(), "completed");
	tw.restart();
	assert(!tw.done(), "restart makes it run again");
	assert_near(tw.value(), 0.0, 0.0001, "restart returns to 0");
}

fn void test_lerp_hits_both_endpoints() @test {
	Tween tw = milktea::tween(100, Easing.LINEAR);
	assert(tw.lerp(3, 9) == 3, "lerp starts at from");
	tw.step(100);
	assert(tw.lerp(3, 9) == 9, "lerp ends at to");
}

fn void test_lerp_rounds_to_nearest() @test {
	Tween tw = milktea::tween(100, Easing.LINEAR);
	tw.step(50); // exactly 0.5
	// 0 -> 3 at t=0.5 is 1.5, which must round to 2, not truncate to 1.
	assert(tw.lerp(0, 3) == 2, "rounds half up, got %d", tw.lerp(0, 3));
}

fn void test_lerp_handles_descending_range() @test {
	// A slide-up animation runs to a smaller y; rounding must not bias.
	Tween tw = milktea::tween(100, Easing.LINEAR);
	assert(tw.lerp(9, 3) == 9, "descending starts high");
	tw.step(100);
	assert(tw.lerp(9, 3) == 3, "descending ends low");
}

fn void test_alpha_bounds_a_fade() @test {
	// A fade's end states are exact: value 0 is fully invisible, value 1
	// fully opaque. Paint skips alpha-0 nodes, so a fade-out's final frame
	// clears the screen instead of leaving a 1/255 ghost.
	Tween tw = milktea::tween(100, Easing.LINEAR);
	assert(tw.alpha() == 0, "first frame alpha is 0, got %d", (sz)tw.alpha());
	tw.step(100);
	assert(tw.alpha() == 255, "final alpha is 255, got %d", (sz)tw.alpha());

	Tween rev = milktea::tween_reversed(100, Easing.LINEAR);
	assert(rev.alpha() == 255, "reverse starts opaque, got %d", (sz)rev.alpha());
	rev.step(100);
	assert(rev.alpha() == 0, "reverse ends invisible, got %d", (sz)rev.alpha());
}

fn void test_alpha_clamps_overshoot() @test {
	// EASE_OUT_BACK exceeds 1.0 mid-flight; alpha must clamp to 255 rather
	// than wrapping. The sweep starts past the first frame: at 0 the value is
	// exactly 0, the invisible end state of a fade.
	Tween tw = milktea::tween(100, Easing.EASE_OUT_BACK);
	for (sz i = 5; i <= 100; i += 5) {
		tw.elapsed_ms = i;
		char a = tw.alpha();
		assert(a >= 1 && a <= 255, "alpha stays in 1..255, got %d at %d", (sz)a, i);
	}
	tw.elapsed_ms = 0;
	assert(tw.alpha() == 0, "value 0 is invisible, got %d", (sz)tw.alpha());
}

fn void test_lerp_color_interpolates() @test {
	Tween tw        = milktea::tween(100, Easing.LINEAR);
	dye::Color red  = dye::color_rgb(255, 0, 0);
	dye::Color blue = dye::color_rgb(0, 0, 255);

	dye::Color at_start = tw.lerp_color(red, blue);
	assert(at_start.r == 255 && at_start.b == 0, "starts at from");

	tw.step(100);
	dye::Color at_end = tw.lerp_color(red, blue);
	assert(at_end.b == 255 && at_end.r == 0, "ends at to");
}
// ── clock-driven tweens ─────────────────────────────────────────────────────

fn void test_tween_at_reads_progress_from_the_clock() @test {
	Tween tw = milktea::tween_at(1000, 100, Easing.LINEAR);
	assert_near(tw.value_at(1000), 0.0, 0.0001, "not started");
	assert(!tw.done_at(1050), "still running halfway");
	assert_near(tw.value_at(1050), 0.5, 0.0001, "halfway by the clock");
	assert(tw.done_at(1100), "finished at the duration");
	assert_near(tw.value_at(1100), 1.0, 0.0001, "ends at 1");
}

fn void test_tween_at_reads_never_change_it() @test {
	Tween tw = milktea::tween_at(1000, 100, Easing.LINEAR);
	tw.value_at(1090);
	assert_near(tw.value_at(1050), 0.5, 0.0001, "a later read does not move an earlier one");
}

fn void test_tween_at_clamps_a_late_frame() @test {
	// A frame that arrives long after the end must not overrun.
	Tween tw = milktea::tween_at(1000, 100, Easing.LINEAR);
	assert(tw.elapsed_at(9999) == 100, "clamped, got %d", tw.elapsed_at(9999));
	assert_near(tw.value_at(9999), 1.0, 0.0001, "settled");
}

fn void test_tween_at_survives_a_backwards_clock() @test {
	// Reading a time before the start reads as not begun.
	Tween tw = milktea::tween_at(5000, 100, Easing.LINEAR);
	assert(tw.elapsed_at(4000) == 0, "reads as not begun, got %d", tw.elapsed_at(4000));
	assert_near(tw.value_at(4000), 0.0, 0.0001, "still at the start");
}

fn void test_tween_at_zero_clock_is_still_clock_driven() @test {
	// A caller whose clock genuinely reads 0 must not be mistaken for a
	// step-driven tween.
	Tween tw = milktea::tween_at(0, 100, Easing.LINEAR);
	assert(tw.elapsed_at(51) == 51, "advances rather than sitting at zero");
}

fn void test_clock_reads_leave_a_step_driven_tween_alone() @test {
	// A tween built with tween() has no clock; reading it at a time must not
	// lose the progress step() has accumulated.
	Tween tw = milktea::tween(100, Easing.LINEAR);
	tw.step(50);
	assert(tw.elapsed_at(999999) == 50, "step progress preserved, got %d", tw.elapsed_at(999999));
}

fn void test_tween_at_reverse_runs_backwards() @test {
	Tween tw = milktea::tween_at(1000, 100, Easing.LINEAR, true);
	assert_near(tw.value_at(1000), 1.0, 0.0001, "starts at the target");
	assert_near(tw.value_at(1100), 0.0, 0.0001, "ends at the start");
}

// ── reversing ───────────────────────────────────────────────────────────────

fn void test_reversed_turns_around_where_it_is() @test {
	Tween tw = milktea::tween_at(1000, 100, Easing.EASE_OUT_CUBIC);
	Tween back = tw.reversed_at(1030);
	assert_near(back.value_at(1030), tw.value_at(1030), 0.0001, "no jump at the turn");
	assert(back.reverse, "heading back");
	assert(!back.done_at(1059), "the way back takes as long as the way out did");
	assert(back.done_at(1060), "and no longer");
	assert_near(back.value_at(1060), 0.0, 0.0001, "back at the start");
}

fn void test_reversed_twice_resumes_the_way_out() @test {
	Tween tw = milktea::tween_at(1000, 100, Easing.LINEAR);
	Tween again = tw.reversed_at(1040).reversed_at(1060);
	assert_near(again.value_at(1060), 0.2, 0.0001, "40 out, 20 back");
	assert(!again.reverse, "heading out again");
	assert(again.done_at(1140), "the remaining 80 to the end");
}

fn void test_an_unstarted_tween_reverses_to_its_start() @test {
	Tween closed = milktea::tween(180, Easing.EASE_OUT_CUBIC).reversed_at(5000);
	assert(closed.done_at(5000), "already settled");
	assert_near(closed.value_at(5000), 0.0, 0.0001, "at the start");
	assert(!closed.showing_at(5000), "nothing on screen");
	assert(closed.reversed_at(5000).showing_at(5000), "opening shows it");
}

fn void test_showing_lasts_until_a_reverse_run_ends() @test {
	Tween out = milktea::tween_at(1000, 100, Easing.LINEAR, true);
	assert(out.showing_at(1099), "still on its way out");
	assert(!out.showing_at(1100), "gone once it lands");
	assert(milktea::tween_at(1000, 100, Easing.LINEAR).showing_at(1000), "on its way in");
}