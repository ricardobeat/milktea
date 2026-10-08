module milktea;

import std::core::dstring;
import glaze;

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

// ── Tree repaints ────────────────────────────────────────────────────────────

// A drawn tree whose root animates at fps (0 = not at all).
struct RepaintModel {
	sz fps;
}

fn milktea::Cmd RepaintModel.init(RepaintModel* self) @dynamic => null;

fn milktea::Cmd RepaintModel.update(RepaintModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == KEY && msg.key.rune == 'q') return quit();
	return null;
}

fn milktea::View RepaintModel.view(RepaintModel* self) @dynamic {
	return draw(root().add(text(glaze::style(), "tick")).animate(self.fps));
}

fn sz repaint_timers(Program* p) {
	sz n = 0;
	foreach (t : p.timers) {
		if (t.active && t.owner == p) n++;
	}
	return n;
}

fn void test_tree_repaint_arms_one_timer() @test {
	RepaintModel m = { .fps = 60 };
	DString out = dstring::temp();
	// Several keys render several frames; each re-arms rather than stacks.
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 1, "got %d repaint timers", repaint_timers(&p));
}

fn void test_tree_without_repaint_arms_nothing() @test {
	RepaintModel m = { .fps = 0 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 0, "got %d repaint timers", repaint_timers(&p));
}
