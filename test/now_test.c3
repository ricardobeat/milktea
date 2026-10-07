module milktea;

import std::core::dstring;

// A clock that moves 10ms every time the runtime reads it, so each stamp is
// distinguishable from the last.
sz g_fake_clock_ms;

fn sz fake_clock() {
	g_fake_clock_ms += 10;
	return g_fake_clock_ms;
}

struct NowModel {
	sz init_now;
	sz[8] update_now;
	sz updates;
	sz view_now;
	bool steady; // now() never moved within a single call
}

fn milktea::Cmd NowModel.init(NowModel* self) @dynamic {
	self.steady = true;
	self.init_now = now();
	return null;
}

fn milktea::Cmd NowModel.update(NowModel* self, milktea::Msg msg) @dynamic {
	sz t = now();
	if (now() != t) self.steady = false;
	if (self.updates < self.update_now.len) self.update_now[self.updates++] = t;
	if (msg.kind == KEY && msg.key.rune == 'q') return quit();
	return null;
}

fn milktea::View NowModel.view(NowModel* self) @dynamic {
	self.view_now = now();
	if (now() != self.view_now) self.steady = false;
	return view("");
}

fn void test_now_is_stamped_per_callback() @test {
	g_fake_clock_ms = 1000;
	NowModel m;
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abq");
	with_clock(&p, &fake_clock);
	p.run()!!;

	assert(m.steady, "now() moved during a single callback");
	assert(m.init_now > 1000, "init() reads the injected clock");
	assert(m.updates >= 3, "expected a, b and q to reach update()");
	for (sz i = 1; i < m.updates; i++) {
		assert(m.update_now[i] > m.update_now[i - 1], "each update() gets a fresh stamp");
	}
	assert(m.view_now > m.init_now, "view() is stamped after init()");
}

fn void test_now_outside_a_program_reads_the_live_clock() @test {
	sz before = time_ms();
	sz t = now();
	assert(t >= before && t <= time_ms());
}

// ── View.repaint_after ───────────────────────────────────────────────────────

struct RepaintModel {
	sz repaint_ms;
}

fn milktea::Cmd RepaintModel.init(RepaintModel* self) @dynamic => null;

fn milktea::Cmd RepaintModel.update(RepaintModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == KEY && msg.key.rune == 'q') return quit();
	return null;
}

fn milktea::View RepaintModel.view(RepaintModel* self) @dynamic {
	return view("").repaint_after(self.repaint_ms);
}

fn sz repaint_timers(Program* p) {
	sz n = 0;
	foreach (t : p.timers) {
		if (t.active && t.owner == p) n++;
	}
	return n;
}

fn void test_repaint_after_arms_one_timer() @test {
	RepaintModel m = { .repaint_ms = 16 };
	DString out = dstring::temp();
	// Several keys render several frames; each re-arms rather than stacks.
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 1, "got %d repaint timers", repaint_timers(&p));
}

fn void test_no_repaint_request_arms_nothing() @test {
	RepaintModel m = { .repaint_ms = 0 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 0, "got %d repaint timers", repaint_timers(&p));
}

fn void test_repaint_lands_on_the_monotonic_grid() @test {
	// A view animating at now() / 80 must be repainted on multiples of 80 on
	// the same clock, or frames repeat and skip where the grids disagree.
	RepaintModel m = { .repaint_ms = 80 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "q");
	p.run()!!;
	foreach (t : p.timers) {
		if (t.active && t.owner == &p) assert(t.deadline_ms % 80 == 0, "deadline %d is off the grid", t.deadline_ms);
	}
	assert(repaint_timers(&p) == 1);
}
