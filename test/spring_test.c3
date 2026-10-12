module spring_test;

import milktea;
import std::math;

fn void assert_near(double got, double want, double tol, String what) {
	assert(math::abs(got - want) <= tol, "%s: got %f, want %f", what, got, want);
}

// Highest value a spring reaches on its way from 0 to 100, sampled every ms.
fn double peak(Spring s, sz until_ms = 3000) {
	double top = s.value_at(0);
	for (sz t = 0; t <= until_ms; t++) top = math::max(top, s.value_at(t));
	return top;
}

fn Spring launched(SpringParams p) {
	Spring s = milktea::spring(0, p);
	s.update_at(100, 0);
	return s;
}

fn void test_starts_where_it_was_at_rest() @test {
	Spring s = launched(milktea::spring_smooth());
	assert_near(s.value_at(0), 0, 1e-9, "value");
	assert_near(s.velocity_at(0), 0, 1e-9, "velocity");
	assert(s.moving_at(0));
}

fn void test_smooth_never_overshoots() @test {
	Spring s = launched(milktea::spring_smooth());
	double last = 0;
	for (sz t = 0; t <= 3000; t++) {
		double v = s.value_at(t);
		assert(v <= 100.0 + 1e-9, "overshot to %f at %dms", v, t);
		assert(v >= last - 1e-9, "turned back at %dms", t);
		last = v;
	}
}

fn void test_overdamped_never_overshoots() @test {
	Spring s = launched(milktea::spring_feel(400, -0.5));
	assert(peak(s) <= 100.0 + 1e-9);
	assert_near(s.value_at(5000), 100, 0.01, "settles");
}

fn void test_overshoot_reaches_what_it_asks_for() @test {
	foreach (os : (double[]) { 0.05, 0.1, 0.3 }) {
		Spring s = launched(milktea::spring_overshoot(500, os));
		assert_near(peak(s), 100.0 * (1.0 + os), 0.05, "peak");
	}
}

fn void test_bounce_overshoots_by_its_damping_ratio() @test {
	// bounce b is a damping ratio of 1 - b, which peaks exp(-ζπ/√(1-ζ²)) past.
	foreach (b : (double[]) { 0.15, 0.3, 0.6 }) {
		double ratio = 1.0 - b;
		double want = math::exp(-ratio * math::PI / math::sqrt(1.0 - ratio * ratio));
		assert_near(peak(launched(milktea::spring_feel(500, b))), 100.0 * (1.0 + want), 0.05, "peak");
	}
}

fn void test_feel_duration_covers_most_of_the_way() @test {
	Spring s = launched(milktea::spring_feel(500));
	assert(s.value_at(500) > 98.0, "only %f by the duration", s.value_at(500));
}

fn void test_settles_and_stops_moving() @test {
	foreach (p : (SpringParams[]) { milktea::spring_smooth(), milktea::spring_bouncy(), milktea::spring_feel(300, -0.4) }) {
		Spring s = milktea::spring(0, p);
		s.update_at(100, 0);
		assert(!s.moving_at(10_000));
		assert_near(s.value_at(10_000), 100, 0.01, "rests on target");
	}
}

fn void test_retarget_keeps_value_and_velocity() @test {
	Spring s = launched(milktea::spring_snappy());
	double v = s.value_at(120);
	double dv = s.velocity_at(120);
	s.update_at(-50, 120);
	assert_near(s.value_at(120), v, 1e-9, "value");
	assert_near(s.velocity_at(120), dv, 1e-9, "velocity");
	assert_near(s.value_at(10_000), -50, 0.01, "new target");
}

fn void test_same_target_update_does_not_change_the_path() @test {
	// Re-anchoring on an unchanged target — every mouse event that lands on
	// the same cell — must leave the trajectory exactly where it was.
	Spring once = launched(milktea::spring_bouncy());
	Spring often = launched(milktea::spring_bouncy());
	for (sz t = 16; t < 400; t += 16) often.update_at(100, t);
	for (sz t = 400; t < 1500; t += 7) {
		assert_near(often.value_at(t), once.value_at(t), 1e-6, "value");
	}
}

fn void test_velocity_matches_the_slope() @test {
	foreach (p : (SpringParams[]) { milktea::spring_smooth(), milktea::spring_bouncy(), milktea::spring_feel(300, -0.4) }) {
		Spring s = milktea::spring(0, p);
		s.update_at(100, 0);
		for (sz t = 10; t < 600; t += 50) {
			double slope = (s.value_at(t + 1) - s.value_at(t - 1)) / 0.002;
			assert_near(s.velocity_at(t), slope, math::abs(slope) * 0.02 + 1, "velocity");
		}
	}
}

fn void test_set_flings_and_reels_back() @test {
	Spring s = milktea::spring(10, milktea::spring_smooth());
	s.set_at(40, 200, 0);
	assert_near(s.value_at(0), 40, 1e-9, "placed");
	assert_near(s.velocity_at(0), 200, 1e-9, "flung");
	assert(s.value_at(50) > 40, "keeps its momentum at first");
	assert_near(s.value_at(10_000), 10, 0.01, "reels back to the target");
}

fn void test_reads_before_the_start_see_the_start() @test {
	Spring s = milktea::spring(0, milktea::spring_smooth());
	s.update_at(100, 1000);
	assert_near(s.value_at(500), 0, 1e-9, "value");
}

fn void test_no_stiffness_holds_still() @test {
	Spring s = milktea::spring(5, milktea::spring_physics(0, 1));
	s.update_at(100, 0);
	assert_near(s.value_at(1000), 5, 1e-9, "value");
}

fn void test_settles_at_is_when_it_stops_moving() @test {
	Spring s = milktea::spring(0, milktea::spring_snappy());
	s.update_at(10, 1000);
	sz t = s.settles_at();
	assert(t > 1000, "takes time to get there");
	assert(!s.moving_at(t), "at rest when it says");
	assert(s.moving_at(t - milktea::FRAME_MS), "and not a frame sooner");
}

fn void test_a_resting_spring_settles_at_once() @test {
	Spring s = milktea::spring(5, milktea::spring_smooth());
	s.update_at(5, 2000);
	assert(s.settles_at() == 2000, "already there, got %d", s.settles_at());
}
