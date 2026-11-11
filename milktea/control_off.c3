// What the rest of milktea calls in the control layer, as nothing, for a
// build with -D NO_CONTROL. See control.c3 for the real thing.
module milktea @feat(NO_CONTROL);

import xray;

alias ControlPointerFn = fn void(MouseAction action, sz x, sz y);
alias ControlScrollFn = fn void(sz x, sz y, double dx, double dy);

struct ControlHooks {
	ControlPointerFn pointer;
	ControlScrollFn scroll;
}

fn void install_control_hooks(ControlHooks hooks) {}
fn void control_start(bool use_stdin) {}
fn sz control_watch(PollFd[] out) => 0;
fn void control_disarm() {}
fn bool control_busy() => false;
fn bool control_ended() => false;
fn void control_poll() {}
fn void control_on_draw(xray::Node* root, xray::ScreenBuffer* buf, sz repaint_ms) {}
fn bool control_remote_key(KeyMsg k) => false;
fn Node* control_overlay(Node* tree) @private => tree;
fn bool control_announce() => false;
fn void control_client() {}
