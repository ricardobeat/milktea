module boba;

import milktea;
import xray;
import glaze;

// Timer is a countdown timer component.
// Embed it in your model; call tick() on TICK messages, return view() in your View.
struct Timer (xray::Content) {
	int total_seconds;
	int elapsed_seconds;
	bool running;
	bool done;
	glaze::Style timer_style;
	glaze::Style paused_style;
	glaze::Style done_style;
	glaze::Style subtle_style;
}

// Timer creates a countdown timer with the given duration in seconds.
fn Timer new_timer(int seconds) {
	Timer t = { };
	t.total_seconds = seconds;
	t.running = true;
	t.timer_style = glaze::style().foreground(glaze::color_hex("#ff00ff")).bold(true);
	t.paused_style = glaze::style().foreground(glaze::color_hex("#ffff00"));
	t.done_style = glaze::style().foreground(glaze::color_hex("#00ff00")).bold(true);
	t.subtle_style = glaze::style().foreground(glaze::color_hex("#666666"));
	return t;
}

// with_styles returns a copy with custom styles.
fn Timer Timer.with_styles(self, glaze::Style timer_s, glaze::Style paused_s, glaze::Style done_s) {
	Timer t = self;
	t.timer_style = timer_s;
	t.paused_style = paused_s;
	t.done_style = done_s;
	return t;
}

fn milktea::Cmd Timer.update(&self, milktea::Msg msg) {
	if (msg.kind != milktea::MsgKind.TICK || msg.owner != self) return null;
	if (self.running) {
		self.elapsed_seconds++;
		if (self.elapsed_seconds >= self.total_seconds) {
			self.elapsed_seconds = self.total_seconds;
			self.running = false;
			self.done = true;
			return null;
		}
	}
	milktea::every(1000, owner: self);
	return null;
}

fn milktea::Cmd Timer.init_cmd(&self) {
	if (self.running) milktea::every(1000, owner: self);
	return null;
}

// toggle pauses or resumes the timer.
fn void Timer.toggle(&self) {
	self.running = !self.running;
}

// reset restarts the countdown from the original duration.
fn void Timer.reset(&self) {
	self.elapsed_seconds = 0;
	self.running = true;
	self.done = false;
}

// pause stops the timer.
fn void Timer.pause(&self) {
	self.running = false;
}

// resume starts the timer.
fn void Timer.resume(&self) {
	if (!self.done) self.running = true;
}

// remaining returns the seconds left on the countdown.
fn int Timer.remaining(&self) {
	int r = self.total_seconds - self.elapsed_seconds;
	return r > 0 ? r : 0;
}

// view returns the rendered timer string.
fn String Timer.view(&self) {
	int rem = self.remaining();
	int minutes     = rem / 60;
	int secs        = rem % 60;
	String time_str = string::tformat("%02d:%02d", minutes, secs);

	DString out = dstring::temp();
	out.append_string(self.timer_style.render(time_str));
	out.append_char('\n');

	if (self.done) {
		out.append_string(self.done_style.render("Time's up!"));
	} else if (self.running) {
		out.append_string(self.subtle_style.render("Running"));
	} else {
		out.append_string(self.paused_style.render("PAUSED"));
	}
	return out.str_view();
}
