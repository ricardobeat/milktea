module boba;

import milktea;
import glaze;

// Timer is a countdown timer component.
// Embed it in your model; call tick() on TICK messages, return view() in your View.
struct Timer {
	int total_seconds;
	int remaining_seconds;
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
	t.remaining_seconds = seconds;
	t.running = true;
	t.timer_style = glaze::new_style().foreground(glaze::color_hex("#ff00ff")).set_bold(true);
	t.paused_style = glaze::new_style().foreground(glaze::color_hex("#ffff00"));
	t.done_style = glaze::new_style().foreground(glaze::color_hex("#00ff00")).set_bold(true);
	t.subtle_style = glaze::new_style().foreground(glaze::color_hex("#666666"));
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

// tick handles a TICK message. Call from your update() when msg.kind == TICK.
// Returns a Cmd to schedule the next tick, or null if stopped.
fn milktea::Cmd Timer.tick(&self) {
	if (self.running) {
		self.remaining_seconds--;
		if (self.remaining_seconds <= 0) {
			self.remaining_seconds = 0;
			self.running = false;
			self.done = true;
			return null;
		}
	}
	return milktea::tick(1000);
}

// init_cmd returns the first Cmd to start the countdown.
fn milktea::Cmd Timer.init_cmd(&self) {
	if (self.running) return milktea::tick(1000);
	return null;
}

// toggle pauses or resumes the timer.
fn void Timer.toggle(&self) {
	self.running = !self.running;
}

// reset restarts the countdown from the original duration.
fn void Timer.reset(&self) {
	self.remaining_seconds = self.total_seconds;
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

// view returns the rendered timer string.
fn String Timer.view(&self) {
	int minutes     = self.remaining_seconds / 60;
	int secs        = self.remaining_seconds % 60;
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