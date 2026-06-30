// pomodoro — a focus timer that demonstrates constraint layouts, timers,
// styling, and the full milktea update loop.
//
// Keys:
//   space    pause / resume
//   r        reset the current phase
//   tab      switch between FOCUS and BREAK
//   q / esc  quit
module pomodoro;

import milktea;
import glaze;
import xray::layout;
import std::io;

// ── Model ────────────────────────────────────────────────────────────────────

enum Phase : int {
	FOCUS,
	BREAK,
}

struct Model {
	Phase phase;
	int   remaining;   // seconds left in the current phase
	bool  running;
	int   completed;   // focus sessions finished
	int   width;
	int   height;
}

// Phase lengths, in seconds. Short for demoing; bump to 25*60 / 5*60 for real use.
const int FOCUS_SECS = 25 * 60;
const int BREAK_SECS = 5 * 60;

fn int phase_length(Phase p) {
	return p == Phase.FOCUS ? FOCUS_SECS : BREAK_SECS;
}

// ── init ─────────────────────────────────────────────────────────────────────

fn milktea::Cmd Model.init(&self) @dynamic {
	self.phase     = Phase.FOCUS;
	self.remaining = phase_length(self.phase);
	self.running   = true;
	// every() locks to the wall clock, so the countdown stays accurate
	// even if a frame takes a few milliseconds to draw.
	return milktea::every(1000);
}

// ── update ───────────────────────────────────────────────────────────────────

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.WINDOW_SIZE:
			self.width  = msg.window_size.width;
			self.height = msg.window_size.height;
			return null;

		case milktea::MsgKind.TICK:
			if (self.running && self.remaining > 0) {
				self.remaining--;
				if (self.remaining == 0) self.advance_phase();
			}
			return milktea::every(1000);   // re-arm for the next second

		case milktea::MsgKind.KEY:
			return self.handle_key(msg.key);

		default:
			return null;
	}
}

fn void Model.advance_phase(&self) {
	if (self.phase == Phase.FOCUS) {
		self.completed++;
		self.phase = Phase.BREAK;
	} else {
		self.phase = Phase.FOCUS;
	}
	self.remaining = phase_length(self.phase);
}

fn milktea::Cmd Model.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit();
		case milktea::KeyCode.TAB:
			self.phase     = self.phase == Phase.FOCUS ? Phase.BREAK : Phase.FOCUS;
			self.remaining = phase_length(self.phase);
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case 'q': return milktea::quit();
				case ' ': self.running = !self.running;
				case 'r': self.remaining = phase_length(self.phase);
				default:
			}
		default:
	}
	return null;
}

// ── view ─────────────────────────────────────────────────────────────────────

fn milktea::View Model.view(&self) @dynamic {
	int w = self.width  > 0 ? self.width  : 80;
	int h = self.height > 0 ? self.height : 24;

	bool focus = self.phase == Phase.FOCUS;

	// Warm pastel accents — one per phase.
	glaze::Color accent = focus
		? glaze::color_hex("#f3a26d")   // peach for focus
		: glaze::color_hex("#8fcab0");  // mint for break
	glaze::Color dim = glaze::color_hex("#7a6a58");

	// 1. Split the screen vertically: title / body / status.
	xray::Rect title_r, body_r, status_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::len(1),  &title_r),
		layout::slot(layout::fill(1), &body_r),
		layout::slot(layout::len(1),  &status_r),
	});

	// 2. Split the body horizontally: a stats sidebar and the timer panel.
	xray::Rect side_r, timer_r;
	layout::hstack(body_r, {
		layout::slot(layout::len(22), &side_r),
		layout::slot(layout::fill(1), &timer_r),
	});

	// 3. Styles.
	glaze::Style title_s = glaze::style()
		.foreground(glaze::color_hex("#4a3f35")).background(accent)
		.bold(true).padding(0, 1, 0, 1);

	glaze::Style side_s = glaze::style()
		.foreground(dim)
		.border(glaze::rounded_border()).border_fg(dim).padding(1, 2, 1, 2);

	glaze::Style timer_s = glaze::style()
		.foreground(accent).bold(true)
		.border(glaze::rounded_border()).border_fg(accent)
		.padding(1, 2, 1, 2)
		.align(glaze::Position.CENTER, glaze::Position.CENTER);

	glaze::Style status_s = glaze::style().foreground(dim);

	// 4. Build content.
	int mins = self.remaining / 60;
	int secs = self.remaining % 60;
	int total = phase_length(self.phase);
	int pct   = total > 0 ? 100 - (self.remaining * 100 / total) : 0;

	String bar = glaze::progress_bar(
		28, pct, "█", "░", accent, dim);

	String clock = string::tformat("%s\n\n  %02d:%02d  \n\n%s",
		focus ? "◆ FOCUS ◆" : "♦ BREAK ♦", mins, secs, bar);
	if (!self.running) clock = string::tformat("%s\n\n  -- paused --", clock);

	String side = string::tformat(
		"POMODORO\n────────\nsessions: %d\nphase:    %s\nstate:    %s",
		self.completed,
		focus ? "focus" : "break",
		self.running ? "running" : "paused");

	// 5. Render each piece into its rect, then stack them into one document.
	String title_v  = title_r.render(title_s,   " 🍵 milktea pomodoro");
	String side_v   = side_r.render(side_s,      side);
	String timer_v  = timer_r.render(timer_s,    clock);
	String status_v = status_r.render(status_s,
		"  space pause · tab switch · r reset · q quit");

	String body = glaze::join_horizontal(side_v, timer_v, 0);
	String doc  = glaze::join_vertical(glaze::Position.LEFT, title_v, body);
	doc = glaze::join_vertical(glaze::Position.LEFT, doc, status_v);

	return milktea::new_alt_screen_view(doc);
}

fn int main() {
	Model m = { };
	milktea::@run(&m);
	return 0;
}
