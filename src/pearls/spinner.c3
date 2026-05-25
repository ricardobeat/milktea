module pearls;

import tea;
import lipgloss;

// SpinnerKind selects the animation frame set.
enum SpinnerKind {
	DOTS,  // ⠋⠙⠹⠸⠼⠴⠦⠧  (default)
	LINE,  // -\|/
	ARROW, // ←↖↑↗→↘↓↙
	PULSE, // ∙∙∙ ●∙∙ ∙●∙ ∙∙●
	MOON,  // 🌑🌒🌓🌔🌕🌖🌗🌘
}

struct SpinnerFrames {
	String[8] frames;
	int count;
	int interval_ms;
}

fn SpinnerFrames spinner_frames(SpinnerKind kind) {
	switch (kind) {
		case DOTS: return { { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }, 8, 80 };
		case LINE: return { { "-", "\\", "|", "/", "-", "\\", "|", "/" }, 4, 100 };
		case ARROW: return { { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" }, 8, 120 };
		case PULSE: return { { "∙∙∙", "●∙∙", "∙●∙", "∙∙●", "∙∙∙", "∙∙∙", "∙∙∙", "∙∙∙" }, 4, 120 };
		case MOON: return { { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" }, 8, 120 };
		default: return { { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }, 8, 80 };
	}
}

// Spinner is a self-contained animated spinner component.
// Embed it in your model; call tick() from init() and on each TICK message.
// Call view() to get the current frame string to include in your view.
struct Spinner {
	SpinnerKind kind;
	int frame;
	lipgloss::Color fg;
}

// new_spinner creates a spinner with the given kind and no colour.
fn Spinner new_spinner(SpinnerKind kind = DOTS) {
	return { .kind = kind };
}

// with_color returns a copy of the spinner with a foreground colour set.
fn Spinner Spinner.with_color(self, lipgloss::Color fg) {
	Spinner s = self;
	s.fg = fg;
	return s;
}

// tick advances the frame and returns the Cmd to schedule the next tick.
// Call from your model's update() when the tick message arrives.
fn tea::Cmd Spinner.tick(&self) {
	SpinnerFrames fs = spinner_frames(self.kind);
	self.frame = (self.frame + 1) % fs.count;
	return tea::tick((sz)fs.interval_ms, &tea::tick_msg);
}

// init_cmd returns the first Cmd to start the animation.
// Return this from your model's init().
fn tea::Cmd Spinner.init_cmd(&self) {
	SpinnerFrames fs = spinner_frames(self.kind);
	return tea::tick((sz)fs.interval_ms, &tea::tick_msg);
}

// view returns the current frame string, styled with the spinner's colour.
fn String Spinner.view(&self) {
	SpinnerFrames fs = spinner_frames(self.kind);
	String frame_str = fs.frames[self.frame % fs.count];
	if (self.fg.kind == lipgloss::ColorKind.NONE) return frame_str;
	lipgloss::Style s = lipgloss::new_style().foreground(self.fg);
	return s.render(frame_str);
}

// advance_frame advances the frame counter without scheduling a tick.
// Useful when the host already has its own tick loop (e.g. jsrt's 60fps loop).
fn void Spinner.advance(&self) {
	SpinnerFrames fs = spinner_frames(self.kind);
	self.frame = (self.frame + 1) % fs.count;
}

// current_frame returns the raw frame string without styling.
fn String Spinner.current_frame(&self) {
	SpinnerFrames fs = spinner_frames(self.kind);
	return fs.frames[self.frame % fs.count];
}