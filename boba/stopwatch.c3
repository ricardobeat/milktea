module boba;

import milktea;
import glaze;

// Stopwatch is a count-up timer component.
// Embed it in your model; call tick() on TICK messages, return view() in your View.
struct Stopwatch {
	int elapsed_seconds;
	bool running;
	glaze::Style timer_style;
	glaze::Style paused_style;
	glaze::Style subtle_style;
}

// new_stopwatch creates a stopwatch starting at zero.
fn Stopwatch new_stopwatch() {
	Stopwatch s = { };
	s.running = true;
	s.timer_style = glaze::new_style().foreground(glaze::color_hex("#00d7ff")).set_bold(true);
	s.paused_style = glaze::new_style().foreground(glaze::color_hex("#ffff00"));
	s.subtle_style = glaze::new_style().foreground(glaze::color_hex("#666666"));
	return s;
}

// with_styles returns a copy with custom styles.
fn Stopwatch Stopwatch.with_styles(self, glaze::Style timer_s, glaze::Style paused_s) {
	Stopwatch s = self;
	s.timer_style = timer_s;
	s.paused_style = paused_s;
	return s;
}

// tick handles a TICK message. Call from your update() when msg.kind == TICK.
// Returns a Cmd to schedule the next tick, or null if stopped.
fn milktea::Cmd Stopwatch.tick(&self) {
	if (self.running) {
		self.elapsed_seconds++;
	}
	return milktea::tick(1000);
}

// init_cmd returns the first Cmd to start the stopwatch.
fn milktea::Cmd Stopwatch.init_cmd(&self) {
	if (self.running) return milktea::tick(1000);
	return null;
}

// toggle pauses or resumes the stopwatch.
fn void Stopwatch.toggle(&self) {
	self.running = !self.running;
}

// reset sets the elapsed time back to zero and starts.
fn void Stopwatch.reset(&self) {
	self.elapsed_seconds = 0;
	self.running = true;
}

// pause stops the stopwatch.
fn void Stopwatch.pause(&self) {
	self.running = false;
}

// resume starts the stopwatch.
fn void Stopwatch.resume(&self) {
	self.running = true;
}

// view returns the rendered stopwatch string.
fn String Stopwatch.view(&self) {
	int hours   = self.elapsed_seconds / 3600;
	int minutes = (self.elapsed_seconds % 3600) / 60;
	int secs    = self.elapsed_seconds % 60;

	DString out = dstring::temp();
	if (hours > 0) {
		out.append_string(self.timer_style.render(string::tformat("%d:%02d:%02d", hours, minutes, secs)));
	} else {
		out.append_string(self.timer_style.render(string::tformat("%02d:%02d", minutes, secs)));
	}
	out.append_char('\n');

	if (self.running) {
		out.append_string(self.subtle_style.render("Running"));
	} else {
		out.append_string(self.paused_style.render("PAUSED"));
	}
	return out.str_view();
}