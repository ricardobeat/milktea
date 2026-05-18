module pearls;

import tea;
import lipgloss;

// Stopwatch is a count-up timer component.
// Embed it in your model; call tick() on TICK messages, return view() in your View.
struct Stopwatch {
    int  elapsed_seconds;
    bool running;
    lipgloss::Style timer_style;
    lipgloss::Style paused_style;
    lipgloss::Style subtle_style;
}

// new_stopwatch creates a stopwatch starting at zero.
fn Stopwatch new_stopwatch() {
    Stopwatch s = {};
    s.running = true;
    s.timer_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    s.paused_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ffff00"));
    s.subtle_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    return s;
}

// with_styles returns a copy with custom styles.
fn Stopwatch Stopwatch.with_styles(self, lipgloss::Style timer_s, lipgloss::Style paused_s) {
    Stopwatch s = self;
    s.timer_style = timer_s;
    s.paused_style = paused_s;
    return s;
}

// tick handles a TICK message. Call from your update() when msg.kind == TICK.
// Returns a Cmd to schedule the next tick, or null if stopped.
fn tea::Cmd Stopwatch.tick(&self) {
    if (self.running) {
        self.elapsed_seconds++;
    }
    return tea::tick(1000);
}

// init_cmd returns the first Cmd to start the stopwatch.
fn tea::Cmd Stopwatch.init_cmd(&self) {
    if (self.running) return tea::tick(1000);
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
    int hours = self.elapsed_seconds / 3600;
    int minutes = (self.elapsed_seconds % 3600) / 60;
    int secs = self.elapsed_seconds % 60;

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
