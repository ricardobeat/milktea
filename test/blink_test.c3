module blink_test;

import std::core::dstring;
import milktea;
import xray;

// A drawn cursor spends half its blink period returning nothing. The repaint
// it asks for has to be scheduled on those frames too, or the animation stops
// after the first off phase and only resumes when something else — a
// keystroke — forces a frame.

fn String blink_cursor(int x, int y, bool blink, String under) {
	return blink ? "*" : "";
}

struct Field (xray::Content) {
	int unused;
}

fn String Field.render(&self, xray::Rect r) @dynamic => "ab";

fn xray::ContentCursor Field.cursor(&self, xray::Rect r) @dynamic {
	return { .x = r.x, .y = r.y, .has_cursor = true, .draw = &blink_cursor, .blink_ms = 20 };
}

struct BlinkModel {
	Field field;
	int ticks;
}

fn milktea::Cmd BlinkModel.init(&self) @dynamic => null;

fn milktea::Cmd BlinkModel.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) {
		self.ticks++;
		if (self.ticks > 5) return milktea::quit();
	}
	return null;
}

fn milktea::View BlinkModel.view(&self) @dynamic {
	return milktea::draw(milktea::root().add(milktea::component(&self.field)));
}

fn void test_drawn_cursor_keeps_rescheduling_itself() @test {
	BlinkModel m;
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 20, 3);

	// No input and no app timer: the only thing that can keep this program
	// running is the cursor asking to be painted again.
	p.run()!!;

	assert(m.ticks > 5, "expected repeated repaints, got %d", m.ticks);
}
