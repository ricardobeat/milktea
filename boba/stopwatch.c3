module boba;

import milktea;
import xray;
import glaze;

// Stopwatch is a count-up timer component.
// Embed it in your model; call tick() on TICK messages, return view() in your View.
const int STOPWATCH_INTERVAL_MS = 10;

struct Stopwatch (xray::Content) {
	long elapsed_ms;
	bool running;
	glaze::Style timer_style;
	glaze::Style paused_style;
	glaze::Style subtle_style;
}

// new_stopwatch creates a stopwatch starting at zero.
fn Stopwatch new_stopwatch() {
	Stopwatch s = { };
	s.running = true;
	s.timer_style = glaze::style().foreground(glaze::color_hex("#00d7ff")).with_bold(true);
	s.paused_style = glaze::style().foreground(glaze::color_hex("#ffff00"));
	s.subtle_style = glaze::style().foreground(glaze::color_hex("#666666"));
	return s;
}

// with_styles returns a copy with custom styles.
fn Stopwatch Stopwatch.with_styles(self, glaze::Style timer_s, glaze::Style paused_s) {
	Stopwatch s = self;
	s.timer_style = timer_s;
	s.paused_style = paused_s;
	return s;
}

fn milktea::Cmd Stopwatch.update(&self, milktea::Msg msg) {
	if (msg.kind != milktea::MsgKind.TICK || msg.owner != self) return null;
	if (self.running) {
		self.elapsed_ms += STOPWATCH_INTERVAL_MS;
	}
	milktea::every(STOPWATCH_INTERVAL_MS, owner: self);
	return null;
}

fn milktea::Cmd Stopwatch.init_cmd(&self) {
	if (self.running) milktea::every(STOPWATCH_INTERVAL_MS, owner: self);
	return null;
}

// toggle pauses or resumes the stopwatch.
fn void Stopwatch.toggle(&self) {
	self.running = !self.running;
}

// reset sets the elapsed time back to zero and starts.
fn void Stopwatch.reset(&self) {
	self.elapsed_ms = 0;
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
	long total_secs = self.elapsed_ms / 1000;
	int hours   = (int)(total_secs / 3600);
	int minutes = (int)((total_secs % 3600) / 60);
	int secs    = (int)(total_secs % 60);
	int cs      = (int)((self.elapsed_ms % 1000) / 10);

	DString out = dstring::temp();
	if (hours > 0) {
		out.append_string(self.timer_style.render(string::tformat("%d:%02d:%02d.%02d", hours, minutes, secs, cs)));
	} else {
		out.append_string(self.timer_style.render(string::tformat("%02d:%02d.%02d", minutes, secs, cs)));
	}
	out.append_char('\n');

	if (self.running) {
		out.append_string(self.subtle_style.render("Running"));
	} else {
		out.append_string(self.paused_style.render("PAUSED"));
	}
	return out.str_view();
}

// ── layout tree ──────────────────────────────────────────────────────────────

fn String Stopwatch.render(&self, xray::Rect r) @dynamic => self.view();
fn int Stopwatch.measure(&self, int width) @dynamic => 1;
fn int Stopwatch.measure_width(&self, int height) @dynamic => glaze::string_width(self.view());

fn xray::Node* Stopwatch.node(&self) => xray::content_node(self);
