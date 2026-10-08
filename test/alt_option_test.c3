module alt_probe @test;
import milktea;
import std::io;

struct Probe { sz n; }
fn milktea::Cmd Probe.init(&self) @dynamic => null;
fn milktea::Cmd Probe.update(&self, milktea::Msg msg) @dynamic => milktea::quit();
fn milktea::Node* Probe.view(&self) @dynamic => milktea::text("x");

fn void test_alt_option_emits_enter_and_exit() @test {
	Probe m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 40, 10, { .alt_screen = true });
	p.send({ .kind = milktea::MsgKind.QUIT });
	p.run()!!;
	String s = out.str_view();
	assert(s.contains("\x1b[?1049h"), "expected alt-screen enter");
	assert(s.contains("\x1b[?1049l"), "expected alt-screen exit");
}

fn void test_no_alt_option_stays_inline() @test {
	Probe m = { };
	DString out = dstring::temp();
	milktea::Program p = milktea::@test_program(&m, &out, 40, 10);
	p.send({ .kind = milktea::MsgKind.QUIT });
	p.run()!!;
	assert(!out.str_view().contains("\x1b[?1049h"), "inline program must not enter alt screen");
}
