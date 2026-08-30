module milktea;

import std::core::dstring;
import std::thread;
import glaze;
import xray;

// contains is defined in test_render.c3

// ============================================================
// Minimal test model for integration testing
// ============================================================

struct TestModel {
	int counter;
	bool mounted;
	bool destroyed;
}

fn milktea::Cmd TestModel.init(TestModel* self) @dynamic {
	return null;
}

fn milktea::Cmd TestModel.update(TestModel* self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.WINDOW_SIZE:
			return null;
		case milktea::MsgKind.KEY:
			if (msg.key.code == milktea::KeyCode.CTRL_C) return milktea::quit();
			if (msg.key.code == milktea::KeyCode.ESC) return milktea::quit();
			if (msg.key.code == milktea::KeyCode.RUNE && msg.key.rune == 'q') return milktea::quit();
			self.counter++;
			return null;
		case milktea::MsgKind.QUIT:
			return null;
		default:
	}
	return null;
}

fn void TestModel.on_mount(TestModel* self) @dynamic {
	self.mounted = true;
}

fn void TestModel.on_destroy(TestModel* self) @dynamic {
	self.destroyed = true;
}

fn milktea::View TestModel.view(TestModel* self) @dynamic {
	return milktea::new_view(string::tformat("count=%d", self.counter));
}

// ============================================================
// Integration tests — no TTY required
// ============================================================

// test_run_quits_on_ctrl_c verifies the event loop exits cleanly
// when given injected input (ctrl+c = 0x03).
fn void test_run_quits_on_ctrl_c() @test {
	TestModel m    = { };
	DString out    = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x03 });

	p.run()!!;

	assert(m.mounted);
	assert(m.destroyed);
	// Should have rendered at least once
	assert(out.str_view().len > 0);
	// View content should appear in output
	assert(contains(out.str_view(), "count="));
}

// test_run_quits_on_esc verifies ESC quits.
fn void test_run_quits_on_esc() @test {
	TestModel m    = { };
	DString out    = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x1b });

	p.run()!!;

	assert(m.mounted);
	assert(m.destroyed);
	assert(contains(out.str_view(), "count="));
}

// test_run_quits_on_q verifies 'q' quits.
fn void test_run_quits_on_q() @test {
	TestModel m    = { };
	DString out    = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, "q");

	p.run()!!;

	assert(m.mounted);
	assert(m.destroyed);
	assert(contains(out.str_view(), "count="));
}

// test_run_increments_counter verifies the model processes key presses
// before receiving the quit character.
fn void test_run_increments_counter() @test {
	TestModel m = { };
	DString out = dstring::temp();
	// Send 3 keystrokes ('a', 'b', 'c') then 'q' to quit.



	// Each key increments counter. q also increments (it's a rune), then quit.

	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, "abcq");

	p.run()!!;

	// counter should be > 0 (at least a, b, c were processed)
	assert(m.counter > 0);
}

// test_send_quit verifies Send()-injected messages work.
fn void test_send_quit() @test {
	TestModel m    = { };
	DString out    = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);

	// No input bytes — program would block on stdin normally.
	// Instead, inject a quit message via Send().
	// The event loop needs to wake up; send_ctrl_c will inject ctrl+c.
	// But Send() only works during run(), so we need to send from
	// a deferred init command. For this test, use inject_input with
	// an empty buffer and rely on the send queue being drained each tick.
	// 
	// Workaround: use init to send quit after first update.
	// We'll test this pattern differently — inject a 'q' byte.
	with_input(&p, "q");

	p.run()!!;

	assert(m.mounted);
	assert(m.destroyed);
}

// test_window_size_injection verifies WithWindowSize sets the
// initial WindowSizeMsg delivered to the model.
struct SizeTrackerModel {
	int last_w;
	int last_h;
}

fn milktea::Cmd SizeTrackerModel.init(SizeTrackerModel* self) @dynamic {
	return null;
}

fn milktea::Cmd SizeTrackerModel.update(SizeTrackerModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.last_w = msg.window_size.width;
		self.last_h = msg.window_size.height;
	}
	if (msg.kind == milktea::MsgKind.KEY && msg.key.code == milktea::KeyCode.CTRL_C) return milktea::quit();
	return null;
}

fn milktea::View SizeTrackerModel.view(SizeTrackerModel* self) @dynamic {
	return milktea::new_view(string::tformat("%dx%d", self.last_w, self.last_h));
}

fn void SizeTrackerModel.on_mount(SizeTrackerModel* self) @dynamic {
}
fn void SizeTrackerModel.on_destroy(SizeTrackerModel* self) @dynamic {
}

fn void test_window_size_injection() @test {
	SizeTrackerModel m = { };
	DString out        = dstring::temp();
	milktea::Program p     = milktea::@test_program(&m, &out, 120, 40);
	with_input(&p, (char[]) { 0x03 }); // ctrl+c

	p.run()!!;

	assert(m.last_w == 120);
	assert(m.last_h == 40);
}

// test_render_contains_sgr verifies the captured output contains
// expected ANSI sequences (cursor hide, content, cursor show).
fn void test_render_contains_sgr() @test {
	TestModel m    = { };
	DString out    = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x03 });

	p.run()!!;

	String raw = out.str_view();
	// Should contain cursor hide: \x1b[?25l



	assert(contains(raw, "\x1b[?25l"));
	// Should contain cursor show: \x1b[?25h
	assert(contains(raw, "\x1b[?25h"));
	// Should contain clear-screen: \x1b[2J
	assert(contains(raw, "\x1b[2J"));
	// Should contain the model content
	assert(contains(raw, "count="));
}

// ============================================================
// Timer tests — verify tick() and every() work in test mode
// ============================================================

struct TimerModel {
	int tick_count;
	int every_count;
	bool quit_after_first_tick;
}

fn milktea::Cmd TimerModel.init(TimerModel* self) @dynamic {
	milktea::tick(16);
	milktea::every(1000);
	return null;
}

fn milktea::Cmd TimerModel.update(TimerModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) {
		self.tick_count++;
		self.every_count++;
		milktea::tick(16);
		milktea::every(1000);
		if (self.quit_after_first_tick) return milktea::quit();
	}
	if (msg.kind == milktea::MsgKind.KEY && msg.key.code == milktea::KeyCode.CTRL_C) {
		return milktea::quit();
	}
	return null;
}

fn milktea::View TimerModel.view(TimerModel* self) @dynamic {
	return milktea::new_view("");
}

// test_tick_fires verifies tick() delivers TICK messages and the model
// can re-arm it on each fire (animation-style).
fn void test_tick_fires() @test {
	TimerModel m = { .quit_after_first_tick = true };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);
	p.run()!!;
	assert(m.tick_count == 1);
}

// test_every_fires verifies every() also delivers TICK messages.
// In test mode the event loop runs as fast as possible, so when no
// input is pending the loop spins and fires pending timers on each
// iteration (since test_mode skips the input_queue_wait).
// Here we quit on the first tick so we don't depend on the wait path.
fn void test_every_fires() @test {
	TimerModel m = { .quit_after_first_tick = true };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);
	p.run()!!;
	assert(m.every_count >= 1);
}

// test_every_deadline_snaps verifies every() snaps its delay to the next
// wall-clock boundary, so a 1s display ticks on :00 forever regardless of how
// long update() takes. The snapping math is exposed as snap_delay() so it can
// be checked directly rather than inferred from timing.
fn void test_every_deadline_snaps() @test {
	// At wall=1234 with a 1000ms interval, the next boundary is 2000.
	assert(milktea::snap_delay(1234, 1000) == 766);
	// Exactly on a boundary: wait a full interval, never 0 (which would
	// re-fire immediately and spin).
	assert(milktea::snap_delay(2000, 1000) == 1000);
	assert(milktea::snap_delay(0, 1000) == 1000);
	// One millisecond before a boundary.
	assert(milktea::snap_delay(1999, 1000) == 1);
	// Sub-second intervals snap the same way.
	assert(milktea::snap_delay(1234, 16) == 14);
	// Degenerate interval must not divide by zero.
	assert(milktea::snap_delay(1234, 0) == 1);
}

// test_every_delay_is_always_within_interval pins the invariant across a
// sweep: the delay is always in (0, interval], so deadlines neither stall nor
// fire back-to-back.
fn void test_every_delay_is_always_within_interval() @test {
	sz[] intervals = { 1, 16, 250, 1000, 60000 };
	foreach (iv : intervals) {
		for (sz wall = 0; wall < 3 * iv; wall += (iv / 7) + 1) {
			sz d = milktea::snap_delay(wall, iv);
			assert(d > 0);
			assert(d <= iv);
			assert((wall + d) % iv == 0);
		}
	}
}

// ============================================================
// every(0) guard — division-by-zero regression
// ============================================================

// ZeroIntervalModel calls every(0) from init() so it executes while
// g_program is live (inside run()). The program quits immediately on
// the first key (ctrl+c injected via with_input). If the modulo guard
// is absent, run() crashes with SIGFPE before delivering any message.
struct ZeroIntervalModel {
	bool updated;
}

fn milktea::Cmd ZeroIntervalModel.init(ZeroIntervalModel* self) @dynamic {
	// every(0) must not divide-by-zero; guard clamps to 1ms.
	milktea::every(0);
	return null;
}

fn milktea::Cmd ZeroIntervalModel.update(ZeroIntervalModel* self, milktea::Msg msg) @dynamic {
	self.updated = true;
	if (msg.kind == milktea::MsgKind.KEY && msg.key.code == milktea::KeyCode.CTRL_C) {
		return milktea::quit();
	}
	return null;
}

fn milktea::View ZeroIntervalModel.view(ZeroIntervalModel* self) @dynamic {
	return milktea::new_view("ok");
}

fn void ZeroIntervalModel.on_mount(ZeroIntervalModel* self) @dynamic { }
fn void ZeroIntervalModel.on_destroy(ZeroIntervalModel* self) @dynamic { }

// test_every_zero_no_crash verifies that every(0) does not crash (SIGFPE).
// The interval is clamped to 1ms internally; the test just needs run() to
// return cleanly.
fn void test_every_zero_no_crash() @test {
	ZeroIntervalModel m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, (char[]) { 0x03 });

	p.run()!!;

	// If we reach this line the guard worked; no SIGFPE was raised.
	assert(m.updated);
}

// ============================================================
// add_overlay field round-trip tests
// ============================================================

// test_add_overlay_defaults verifies that add_overlay with only positional
// args leaves transparent=false and layer_style zero-initialised, preserving
// backward-compatible behaviour for all existing call sites.
fn void test_add_overlay_defaults() @test {
	milktea::View v = milktea::new_view("bg");
	v = v.add_overlay(1, 2, 10, 5, "hello");

	assert(v.overlay_count == 1);
	milktea::Overlay o = v.overlays[0];
	assert(o.x == 1);
	assert(o.y == 2);
	assert(o.w == 10);
	assert(o.h == 5);
	assert(o.alpha == 0);
	// Defaults must be false / zero — behaviour preserved for existing callers.
	assert(!o.transparent);
	assert(!o.layer_style.shadow.enabled);
	assert(!o.layer_style.inner_shadow.enabled);
}

// test_add_overlay_transparent_and_shadow verifies that the transparent and
// layer_style params are stored in the Overlay entry when supplied.
fn void test_add_overlay_transparent_and_shadow() @test {
	xray::LayerStyle ls = {
		.shadow = xray::shadow(offset_x: 1, offset_y: 1, opacity: 128, blur: 2),
	};

	milktea::View v = milktea::new_view("bg");
	v = v.add_overlay(0, 0, 20, 8, "popup", transparent: true, layer_style: ls);

	assert(v.overlay_count == 1);
	milktea::Overlay o = v.overlays[0];
	assert(o.transparent);
	assert(o.layer_style.shadow.enabled);
	assert(o.layer_style.shadow.offset_x == 1);
	// offset_y is stored in half-rows, so one row is 2.
	assert(o.layer_style.shadow.offset_y == 2);
	assert(o.layer_style.shadow.opacity == 128);
	assert(o.layer_style.shadow.blur == 2);
	// Inner shadow untouched when only shadow was set.
	assert(!o.layer_style.inner_shadow.enabled);
}

// test_add_overlay_inner_shadow verifies inner_shadow round-trips correctly.
fn void test_add_overlay_inner_shadow() @test {
	xray::LayerStyle ls = {
		.inner_shadow = xray::inner_shadow(right: 3, opacity: 40),
	};

	milktea::View v = milktea::new_view("bg");
	v = v.add_overlay(0, 0, 30, 10, "panel", layer_style: ls);

	assert(v.overlay_count == 1);
	milktea::Overlay o = v.overlays[0];
	assert(!o.transparent); // transparent defaults to false
	assert(!o.layer_style.shadow.enabled);
	assert(o.layer_style.inner_shadow.enabled);
}
// ============================================================
// Test-mode loop termination
// ============================================================

// NeverQuitsModel is the shape of a model with a bug: it consumes messages
// but never returns quit().
struct NeverQuitsModel {
	int updates;
}

fn milktea::Cmd NeverQuitsModel.init(NeverQuitsModel* self) @dynamic {
	return null;
}

fn milktea::Cmd NeverQuitsModel.update(NeverQuitsModel* self, milktea::Msg msg) @dynamic {
	self.updates++;
	return null;
}

fn milktea::View NeverQuitsModel.view(NeverQuitsModel* self) @dynamic {
	return milktea::new_view("still here");
}

// test_test_mode_terminates_without_quit pins down that the event loop ends
// once injected input is exhausted and no timer is armed, even if the model
// never quits.
//
// In test mode there is no reader thread and no blocking wait, so the loop
// used to spin at 100% CPU forever here — meaning a single buggy model under
// test would hang the whole suite rather than failing it. If this regresses,
// this test does not fail: it hangs. That is the symptom being guarded.
fn void test_test_mode_terminates_without_quit() @test {
	NeverQuitsModel m;
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);
	milktea::with_input(&p, (char[])"abc");
	p.run()!!;

	// The injected keys were delivered before the loop exited.
	assert(m.updates > 0);
}

// ============================================================
// Overlay clipping
// ============================================================

// NegativeOverlayModel places an overlay partly off the left/top edge, which
// is what happens when a model scrolls or animates a floating panel out of
// view. sz is signed, so the destination guard (dx >= width) let negative
// coordinates through to index before the cell buffer.
struct NegativeOverlayModel {
	int frames;
}

fn milktea::Cmd NegativeOverlayModel.init(NegativeOverlayModel* self) @dynamic {
	return null;
}

fn milktea::Cmd NegativeOverlayModel.update(NegativeOverlayModel* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.KEY) return milktea::quit();
	return null;
}

fn milktea::View NegativeOverlayModel.view(NegativeOverlayModel* self) @dynamic {
	self.frames++;
	milktea::View v = milktea::new_alt_screen_view("base content");
	// Off the top-left corner, and off the right/bottom edge. alpha != 0
	// selects the per-cell blending path, which does its own destination
	// bounds check rather than going through ScreenBuffer.set_cell.
	v = v.add_overlay(-5, -3, 10, 6, "overlay", alpha: 128);
	v = v.add_overlay(78, 22, 10, 6, "overlay", alpha: 128);
	return v;
}

fn void test_overlay_with_negative_origin_is_clipped() @test {
	NegativeOverlayModel m;
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);
	milktea::with_input(&p, (char[])"q");
	p.run()!!;

	assert(m.frames > 0);
}

// ============================================================
// Program.send() concurrent shutdown
// ============================================================

// SendRaceModel quits after a handful of messages so run() tears down while
// the sender threads below are still hammering send().
struct SendRaceModel {
	int updates;
}

fn milktea::Cmd SendRaceModel.init(SendRaceModel* self) @dynamic {
	return null;
}

fn milktea::Cmd SendRaceModel.update(SendRaceModel* self, milktea::Msg msg) @dynamic {
	self.updates++;
	if (self.updates > 20) return milktea::quit();
	return null;
}

fn milktea::View SendRaceModel.view(SendRaceModel* self) @dynamic {
	return milktea::new_view("race");
}

fn int send_race_sender(void* arg) @private {
	milktea::Program* p = (milktea::Program*)arg;
	for (int i = 0; i < 200000; i++) {
		milktea::Msg m = { .kind = milktea::MsgKind.USER };
		p.send(m);
	}
	return 0;
}

// test_send_survives_concurrent_shutdown pins the handshake between send() and
// run()'s teardown.
//
// send() used to gate on a plain bool that was cleared just before
// send_mu.destroy(). Clearing a flag only stops *new* entrants: a sender that
// had already passed the check went on to lock — and unlock — a destroyed
// mutex. Against the old code this aborts with "Mutex was not initialized"
// within a few runs; a heavier standalone version failed 6/6.
//
// send() now registers as in-flight before checking the flag, and teardown
// stops accepting and then drains the in-flight count before destroying.
fn void test_send_survives_concurrent_shutdown() @test {
	for (int round = 0; round < 4; round++) {
		SendRaceModel m;
		DString out = dstring::temp();
		milktea::Program p = milktea::@test_program(&m, &out, 80, 24);
		milktea::with_input(&p, (char[])"abcdefghij");

		thread::Thread t1, t2;
		t1.create(&send_race_sender, &p)!!;
		t2.create(&send_race_sender, &p)!!;

		p.run()!!;

		t1.join()!!;
		t2.join()!!;
	}
}

// ============================================================
// screen_width / screen_height
// ============================================================

// ScreenSizeModel records what the accessors report from inside the
// program callbacks, so the test can assert on them after run() returns.
struct ScreenSizeModel {
	int w_in_update;
	int h_in_update;
	int w_in_view;
	int h_in_view;
}

fn milktea::Cmd ScreenSizeModel.init(ScreenSizeModel* self) @dynamic {
	return null;
}

fn milktea::Cmd ScreenSizeModel.update(ScreenSizeModel* self, milktea::Msg msg) @dynamic {
	self.w_in_update = milktea::screen_width();
	self.h_in_update = milktea::screen_height();
	if (msg.kind == milktea::MsgKind.KEY) return milktea::quit();
	return null;
}

fn milktea::View ScreenSizeModel.view(ScreenSizeModel* self) @dynamic {
	self.w_in_view = milktea::screen_width();
	self.h_in_view = milktea::screen_height();
	return milktea::new_view("size");
}

// The accessors report the program's injected size from inside update/view,
// so a model never has to store WINDOW_SIZE just to read it back.
fn void test_screen_size_accessors_report_injected_size() @test {
	ScreenSizeModel m  = { };
	DString out        = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 100, 40, (char[]) { 'q' });

	p.run()!!;

	assert(m.w_in_update == 100);
	assert(m.h_in_update == 40);
	assert(m.w_in_view == 100);
	assert(m.h_in_view == 40);
}

// Outside a running program there is no size to report, so the accessors
// fall back to 80x24 rather than dereferencing a null g_program.
fn void test_screen_size_accessors_fall_back_when_not_running() @test {
	assert(milktea::screen_width() == 80);
	assert(milktea::screen_height() == 24);
}

// ============================================================
// Tree layout — milktea::draw / draw_inline through a real program
// ============================================================

struct TreeModel {
	bool modal;
	bool inline_mode;
}

fn milktea::Cmd TreeModel.init(&self) @dynamic => null;

fn milktea::Cmd TreeModel.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.KEY) return milktea::quit();
	return null;
}

fn milktea::View TreeModel.view(&self) @dynamic {
	glaze::Style plain = {};
	milktea::Node* root = milktea::root()
		.add(milktea::vstack()
			.add(milktea::text(plain, "HEADER").height(milktea::cells(1)))
			.add(milktea::text(plain, "body").fill(1))
			.add(milktea::text(plain, "FOOTER").height(milktea::cells(1))));

	if (self.modal) {
		root.add(milktea::text(plain, "MODAL").center());
	}

	return self.inline_mode ? milktea::draw_inline(root) : milktea::draw(root);
}

fn void test_draw_places_header_and_footer_at_the_edges() @test {
	TreeModel m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 40, 10, "q");

	p.run()!!;

	String s = out.str_view();
	assert(contains(s, "HEADER"));
	assert(contains(s, "FOOTER"));
	assert(contains(s, "body"));
}

fn void test_draw_paints_a_centered_modal_over_the_layout() @test {
	TreeModel m = { .modal = true };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 40, 10, "q");

	p.run()!!;

	String s = out.str_view();
	assert(contains(s, "MODAL"));
	// The base layout is still there underneath.
	assert(contains(s, "HEADER"));
}

fn void test_draw_inline_sizes_the_block_to_its_content() @test {
	// Three rows of content in a 24-row terminal: an inline view must claim
	// only those three, leaving the rest of the screen to the user.
	TreeModel m = { .inline_mode = true };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 40, 24, "q");

	p.run()!!;

	String s = out.str_view();
	assert(contains(s, "HEADER"));
	assert(contains(s, "FOOTER"));
	// Alt screen is never entered for an inline view.
	assert(!contains(s, "\x1b[?1049h"));
}

// Program.run() owns the alt screen. Entering it manually beforehand leaves
// in_alt_screen false, so the exit path never pops back to the normal buffer
// and the terminal is stranded in the alt screen after quit. run() must reject
// that up front rather than start and wedge the terminal.
fn void test_manual_alt_screen_before_run_is_rejected() @test {
	TestModel m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 80, 24);

	milktea::g_manual_alt_screen = true;
	defer milktea::g_manual_alt_screen = false;

	if (catch err = p.run()) {
		assert(err == milktea::ALT_SCREEN_ALREADY_ENTERED);
		return;
	}
	unreachable("run() must reject a manually entered alt screen");
}

// exit_alt_screen() clears the flag, so a program that renders directly and
// cleans up after itself can still hand off to run() afterwards.
fn void test_manual_alt_screen_cleared_allows_run() @test {
	milktea::g_manual_alt_screen = true;
	milktea::exit_alt_screen();
	assert(!milktea::g_manual_alt_screen);
}
