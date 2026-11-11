module milktea;

import glaze;
import xray;

// Remote control of a program that was not started with MILKTEA_CONTROL=1
// has to be allowed by whoever is at it. `app --cmd ...` leaves a request
// (see control_pipe.c3); the program then shows, over whatever it draws,
//
//     Allow remote control?  [yes]  [no]
//
// at the bottom of the screen. It is answered with the mouse, or with the
// keyboard: left, right or tab choose, enter answers, esc says no. "no" is
// what is chosen to begin with and letters answer nothing, so a person who
// was typing when it came up cannot say yes by accident. The keyboard is the
// dialog's alone until it is answered.
//
// While the program takes commands, however that came about, a white dot on
// red sits in the bottom left corner, and says "remote control on" under the
// pointer.

struct Remote @local {
	bool asking;
	bool yes_chosen;
	bool hover;
}

Remote g_remote @local;

// request_redraw has the running program draw a frame on its next pass,
// for a change that reached the screen by no message.
fn void request_redraw() {
	if (g_program != null) g_program.redraw_wanted = true;
}

// control_remote_poll looks for a request, or for one taken back. Backends
// reach it through control_poll, once a pass.
fn void control_remote_poll() @private {
	if (!control_ask_possible()) return;
	bool asked = control_ask_pending();
	if (control_pipe_fd() >= 0) {
		// Already allowed: the request has its answer.
		if (asked) control_ask_done();
		return;
	}
	if (asked == g_remote.asking) return;
	g_remote.asking = asked;
	g_remote.yes_chosen = false;
	request_redraw();
}

fn void remote_answer(bool yes) @local {
	if (!g_remote.asking) return;
	g_remote.asking = false;
	if (yes) {
		// A window reads its command pipe in its own loop; a terminal's
		// reader thread hands the lines over.
		if (g_ctl_is_window()) {
			control_start();
		} else {
			control_start_piped();
		}
		control_pipe_open();
	}
	control_ask_done();
	request_redraw();
}

// control_remote_key gives a key to the dialog. True when the dialog took
// it, which is every key while it is up.
fn bool control_remote_key(KeyMsg k) {
	if (!g_remote.asking) return false;
	if (k.action == KeyAction.KEY_RELEASE) return true;
	switch (k.code) {
		case LEFT:
		case RIGHT:
		case TAB:
			g_remote.yes_chosen = !g_remote.yes_chosen;
			request_redraw();
		case ENTER: remote_answer(g_remote.yes_chosen);
		case ESC: remote_answer(false);
		default:
	}
	return true;
}

fn void remote_yes(void* id, String id_str, sz col, sz row) @local => remote_answer(true);
fn void remote_no(void* id, String id_str, sz col, sz row) @local => remote_answer(false);

fn void remote_hover_in(void* id, String id_str, sz col, sz row) @local {
	g_remote.hover = true;
}

fn void remote_hover_out(void* id, String id_str, sz col, sz row) @local {
	g_remote.hover = false;
}

const String REMOTE_PANEL @local = "#2b2b2b";
const String REMOTE_INK @local = "#ffffff";
const String REMOTE_DIM @local = "#4a4a4a";
const String REMOTE_RED @local = "#d02020";

fn Node* remote_button(String label, bool chosen, xray::ClickFn on_click) @local {
	glaze::Style s = glaze::style().with_fg(chosen ? REMOTE_PANEL : REMOTE_INK).with_bg(chosen ? REMOTE_INK : REMOTE_DIM);
	return text(label, s).style({}, hover: glaze::style().with_fg(REMOTE_PANEL).with_bg(REMOTE_INK))
		.role(BUTTON).on_click(on_click).pointer(HAND);
}

// control_overlay wraps the frame's tree with what remote control shows over
// it, or hands the tree back when that is nothing. draw calls it.
fn Node* control_overlay(Node* tree) @private {
	bool on = control_pipe_fd() >= 0;
	if (tree == null || (!g_remote.asking && !on)) return tree;
	xray::LayoutMetrics m = layout_metrics();
	glaze::Style panel = glaze::style().with_fg(REMOTE_INK).with_bg(REMOTE_PANEL);
	Node* over = xray::root();
	over.add(tree);
	if (g_remote.asking) {
		Node* dialog = xray::hstack().id("remote-control-dialog").role(DIALOG).block_pointer();
		dialog.add(text("  Allow remote control?  ", panel));
		dialog.add(remote_button(" yes ", g_remote.yes_chosen, &remote_yes).key("yes"));
		dialog.add(text("  ", panel));
		dialog.add(remote_button(" no ", !g_remote.yes_chosen, &remote_no).key("no"));
		dialog.add(text("  ", panel));
		over.add(dialog.place(JUSTIFY_CENTER, ALIGN_END).offset(0, -1));
	} else {
		Node* badge = xray::hstack().id("remote-control").role(STATUS);
		glaze::Style red = glaze::style().with_fg(REMOTE_INK).with_bg(REMOTE_RED);
		badge.add(text(" ● ", red).decorate(xray::solid().round((float)m.unit_h() / 2.0f))
			.on_hover_in(&remote_hover_in).on_hover_out(&remote_hover_out));
		if (g_remote.hover) badge.add(text(" remote control on ", panel));
		over.add(badge.place(JUSTIFY_START, ALIGN_END).offset(1, -1));
	}
	return over;
}
