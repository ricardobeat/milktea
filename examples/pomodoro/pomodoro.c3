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
import std::io;

// ── Model ────────────────────────────────────────────────────────────────────

// Width of the stats sidebar, and of the progress bar inside the timer panel.
const int SIDEBAR_COLS  = 22;
const int PROGRESS_CELLS = 28;
// Columns between the sidebar and the timer panel. Without it the two borders
// sit flush and the sidebar's right edge is overwritten.
const int PANEL_GAP = 1;

enum Phase : int {
	FOCUS,
	BREAK,
}

struct Model {
	Phase phase;
	int   remaining;   // seconds left in the current phase
	bool  running;
	int   completed;   // focus sessions finished
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
	bool focus = self.phase == Phase.FOCUS;

	// Warm pastel accents — one per phase.
	glaze::Color accent = focus
		? glaze::color_hex("#f3a26d")   // peach for focus
		: glaze::color_hex("#8fcab0");  // mint for break
	glaze::Color dim = glaze::color_hex("#7a6a58");

	glaze::Style title_s = {
		.fg = glaze::color_hex("#4a3f35"), .bg = accent, .bold = true,
		.pad_left = 1, .pad_right = 1,
	};
	glaze::Style side_s = {
		.fg = dim, .border = glaze::ROUNDED, .border_color = dim,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
	};
	glaze::Style timer_s = {
		.fg = accent, .bold = true,
		.border = glaze::ROUNDED, .border_color = accent,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
		.align_h = glaze::Position.CENTER, .align_v = glaze::Position.CENTER,
	};
	glaze::Style status_s = { .fg = dim };

	int mins = self.remaining / 60;
	int secs = self.remaining % 60;
	int total = phase_length(self.phase);
	int pct   = total > 0 ? 100 - (self.remaining * 100 / total) : 0;

	String bar = glaze::progress_bar(PROGRESS_CELLS, pct, "█", "░", accent, dim);

	String clock = string::tformat("%s\n\n  %02d:%02d  \n\n%s",
		focus ? "◆ FOCUS ◆" : "♦ BREAK ♦", mins, secs, bar);
	if (!self.running) clock = string::tformat("%s\n\n  -- paused --", clock);

	String side = string::tformat(
		"POMODORO\n────────\nsessions: %d\nphase:    %s\nstate:    %s",
		self.completed,
		focus ? "focus" : "break",
		self.running ? "running" : "paused");

	return milktea::draw(milktea::root()
		.add(milktea::vstack()
			.add(milktea::text(title_s, " 🍵 milktea pomodoro").height(milktea::cells(1)))
			.add(milktea::hstack()
				.fill(1)
				.with_gap(PANEL_GAP)
				.add(milktea::text(side_s, side).width(milktea::cells(SIDEBAR_COLS)))
				.add(milktea::text(timer_s, clock).fill(1)))
			.add(milktea::text(status_s,
				"  space pause · tab switch · r reset · q quit")
				.height(milktea::cells(1)))));
}

fn int main() {
	Model m = { };
	milktea::@run(&m);
	return 0;
}
