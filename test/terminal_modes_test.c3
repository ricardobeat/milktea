module terminal_modes_test @test;
import milktea;
import std::io;

// Toggler starts mouse reporting on 'm' and reports key events on 'k', so a
// test can watch the runtime bring the terminal in line with what it asked for.
struct Toggler { sz n; }
fn milktea::Cmd Toggler.init(&self) @dynamic => null;
fn milktea::Cmd Toggler.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind != milktea::MsgKind.KEY) return null;
	switch (msg.key.rune) {
		case 'm': milktea::set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);
		case 'k': milktea::set_report_key_events(true);
		case 'q': return milktea::quit();
	}
	return null;
}
fn milktea::View Toggler.view(&self) @dynamic => milktea::view("x");

const String MOUSE_ALL_ON  = "\x1b[?1003h";
const String MOUSE_CELL_ON = "\x1b[?1002h";
const String KEY_EVENTS_ON = "\x1b[>3u";

fn void test_a_program_starts_in_the_modes_its_options_name() @test {
	Toggler m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 40, 10, {
		.mouse_mode = milktea::MouseMode.MOUSE_MODE_CELL_MOTION,
		.report_key_events = true,
	});
	p.send({ .kind = milktea::MsgKind.QUIT });
	p.run()!!;
	assert(out.str_view().contains(MOUSE_CELL_ON), "cell motion on");
	assert(out.str_view().contains(KEY_EVENTS_ON), "key events on");
}

fn void test_modes_stay_off_unless_asked_for() @test {
	Toggler m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program_input(&m, &out, 40, 10, "q");
	p.run()!!;
	assert(!out.str_view().contains(MOUSE_ALL_ON), "no mouse");
	assert(!out.str_view().contains(KEY_EVENTS_ON), "no key events");
}

fn void test_update_can_change_the_modes_while_running() @test {
	Toggler m = { };
	DString out = dstring::temp();
	// The keys arrive as one batch and are drawn once; the quit comes after.
	milktea::Program p = milktea::@test_program_input(&m, &out, 40, 10, "mk");
	p.send({ .kind = milktea::MsgKind.QUIT });
	p.run()!!;
	assert(out.str_view().contains(MOUSE_ALL_ON), "mouse turned on");
	assert(out.str_view().contains(KEY_EVENTS_ON), "key events turned on");
}
