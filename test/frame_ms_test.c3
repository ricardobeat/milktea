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
	sz init_ms;
	sz[8] update_ms;
	sz updates;
	sz view_ms;
	bool steady; // frame_ms() never moved within a single call
}

fn milktea::Cmd NowModel.init(NowModel* self) @dynamic {
	self.steady = true;
	self.init_ms = frame_ms();
	return null;
}

fn milktea::Cmd NowModel.update(NowModel* self, milktea::Msg msg) @dynamic {
	sz t = frame_ms();
	if (frame_ms() != t) self.steady = false;
	if (self.updates < self.update_ms.len) self.update_ms[self.updates++] = t;
	if (msg.kind == KEY && msg.key.rune == 'q') return quit();
	return null;
}

fn milktea::View NowModel.view(NowModel* self) @dynamic {
	self.view_ms = frame_ms();
	if (frame_ms() != self.view_ms) self.steady = false;
	return view("");
}

fn void test_frame_ms_is_stamped_per_callback() @test {
	g_fake_clock_ms = 1000;
	NowModel m;
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abq");
	with_clock(&p, &fake_clock);
	p.run()!!;

	assert(m.steady, "frame_ms() moved during a single callback");
	assert(m.init_ms > 1000, "init() reads the injected clock");
	assert(m.updates >= 3, "expected a, b and q to reach update()");
	for (sz i = 1; i < m.updates; i++) {
		assert(m.update_ms[i] > m.update_ms[i - 1], "each update() gets a fresh stamp");
	}
	assert(m.view_ms > m.init_ms, "view() is stamped after init()");
}

fn void test_frame_ms_outside_a_program_reads_the_live_clock() @test {
	sz before = time_ms();
	sz t = frame_ms();
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
	return draw(root().add(text("tick")).animate(self.fps));
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

// ── frames_until ─────────────────────────────────────────────────────────────

// Asks for frames `ahead` ms past now (negative = already over) on starting
// and on every key, and counts the update() calls it saw.
struct FramesModel {
	sz ahead;
	sz updates;
}

fn milktea::Cmd FramesModel.init(FramesModel* self) @dynamic {
	frames_until(frame_ms() + self.ahead);
	return null;
}

fn milktea::Cmd FramesModel.update(FramesModel* self, milktea::Msg msg) @dynamic {
	self.updates++;
	if (msg.kind == KEY && msg.key.rune == 'q') return quit();
	if (msg.kind == KEY) frames_until(frame_ms() + self.ahead);
	return null;
}

fn milktea::View FramesModel.view(FramesModel* self) @dynamic => view("");

fn void test_frames_until_arms_one_repaint_timer() @test {
	FramesModel m = { .ahead = 1000 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 1, "got %d repaint timers", repaint_timers(&p));
}

fn void test_frames_until_in_the_past_arms_nothing() @test {
	FramesModel m = { .ahead = -1 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "abcq");
	p.run()!!;
	assert(repaint_timers(&p) == 0, "got %d repaint timers", repaint_timers(&p));
}

// Repaints are not messages: frames run out without update() hearing of them.
fn void test_repaints_do_not_reach_update() @test {
	FramesModel m = { .ahead = 60 };
	DString out = dstring::temp();
	Program p = @test_program_input(&m, &out, 80, 24, "a");
	p.run()!!;
	assert(repaint_timers(&p) == 0, "frames stopped after the deadline");
	// The window size and the key; none of the repaints in between.
	assert(m.updates == 2, "update() saw %d messages", m.updates);
}

fn void test_frames_until_outside_a_program_is_ignored() @test {
	frames_until(frame_ms() + 1000); // must not crash with no program running
}
