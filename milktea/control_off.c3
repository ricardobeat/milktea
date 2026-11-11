// What the rest of milktea calls in the control layer, as nothing, for a
// build with -D NO_CONTROL: no command line, no --cmd or --repl, no remote
// control dialog. See control.c3 for the real thing.
module milktea @feat(NO_CONTROL);

import xray;

alias ControlPointerFn = fn void(MouseAction action, sz x, sz y);
alias ControlScrollFn = fn void(sz x, sz y, double dx, double dy);

struct ControlHooks {
	ControlPointerFn pointer;
	ControlScrollFn scroll;
}

struct LineAsm @private {
	char unused;
}

fn void LineAsm.feed(&self, char[] bytes, bool to_queue) {}
fn void LineAsm.flush(&self, bool to_queue) {}

fn void install_control_hooks(ControlHooks hooks) {}
fn void control_start() {}
fn void control_start_piped() {}
fn void control_feed_line(String line) {}
fn bool control_busy() => false;
fn void control_stdin_eof() {}
fn void control_poll() {}
fn void control_on_draw(xray::Node* root, xray::ScreenBuffer* buf, sz repaint_ms) {}
fn void control_pointer_event(String type, sz x, sz y) {}
fn void control_msg_event(Msg m) {}
fn bool control_remote_key(KeyMsg k) => false;
fn Node* control_overlay(Node* tree) @private => tree;
fn bool control_pipe_wanted() => false;
fn void control_announce() {}
fn bool control_ask_pending() @private => false;
fn bool control_pipe_open() => false;
fn int control_pipe_fd() => -1;
fn void control_client() {}
