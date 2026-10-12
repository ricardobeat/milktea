module blink_test;

import std::core::dstring;
import milktea;
import xray;

// A drawn cursor spends half its blink period returning nothing. The repaint
// it asks for has to be scheduled on those frames too, or the animation stops
// after the first off phase and only resumes when something else — a
// keystroke — forces a frame.

fn String blink_cursor(sz x, sz y, bool blink, String under) {
	return blink ? "*" : "";
}

struct Field (xray::Content) {
	sz unused;
}

fn String Field.render(&self, xray::Rect r) @dynamic => "ab";

fn xray::ContentCursor Field.cursor(&self, xray::Rect r) @dynamic {
	return { .x = r.x, .y = r.y, .has_cursor = true, .draw = &blink_cursor, .blink_ms = 20 };
}

struct BlinkModel {
	Field field;
	sz frames;
}

// The app's one timer only ends the run; it is what the repaints are counted
// against, not what drives them.
fn milktea::Cmd BlinkModel.init(&self) @dynamic => milktea::tick(200);

fn milktea::Cmd BlinkModel.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) return milktea::quit();
	return null;
}

fn milktea::Node* BlinkModel.view(&self) @dynamic {
	self.frames++;
	return milktea::root().add(milktea::component(&self.field));
}

fn void test_drawn_cursor_keeps_rescheduling_itself() @test {
	BlinkModel m;
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 20, 3);

	// No input, and update() changes nothing: every frame after the first is
	// the cursor asking to be painted again. A 20ms blink over 200ms is ~10.
	p.run()!!;

	assert(m.frames > 5, "expected repeated repaints, got %d", m.frames);
}
