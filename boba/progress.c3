module boba;

import milktea;
import xray;
import glaze;

// Progress is an animated progress bar component.
struct Progress (xray::Content) {
	int width; // total width in cells
	double percent; // 0.0 - 100.0
	String fill_char; // character for filled portion
	String empty_char; // character for empty portion
	glaze::Style fill_style;
	glaze::Style empty_style;
	glaze::Style percent_style;
}

// new_progress creates a progress bar with the given width and initial percentage.
fn Progress new_progress(int width, double percent) {
	Progress p = { };
	p.width = width;
	p.percent = percent;
	p.fill_char = "\xe2\x96\x88"; // █
	p.empty_char = "\xe2\x96\x91"; // ░
	p.fill_style = glaze::style().foreground(glaze::color_hex("#00d7ff"));
	p.empty_style = glaze::style().foreground(glaze::color_hex("#333333"));
	p.percent_style = glaze::style().foreground(glaze::color_hex("#888888"));
	return p;
}

// with_styles returns a copy with custom styles.
fn Progress Progress.with_styles(self, glaze::Style fill_s, glaze::Style empty_s) {
	Progress p = self;
	p.fill_style = fill_s;
	p.empty_style = empty_s;
	return p;
}

// with_chars returns a copy with custom fill/empty characters.
fn Progress Progress.with_chars(self, String fill, String empty) {
	Progress p = self;
	p.fill_char = fill;
	p.empty_char = empty;
	return p;
}

// set_percent sets the progress percentage (0-100).
fn void Progress.set_percent(&self, double pct) {
	if (pct < 0) pct = 0;
	if (pct > 100) pct = 100;
	self.percent = pct;
}

// incr_percent increases the progress by the given amount.
fn void Progress.incr_percent(&self, double amount) {
	self.set_percent(self.percent + amount);
}

// view returns the rendered progress bar string.
fn String Progress.view(&self) {
	return glaze::progress_bar(
		self.width,
		(int)self.percent,
		self.fill_char,
		self.empty_char,
		self.fill_style.fg,
		self.empty_style.fg
	);
}

// view_with_percent returns the bar with a percentage label.
fn String Progress.view_with_percent(&self) {
	DString out = dstring::temp();
	out.append_string(self.view());
	out.append_char(' ');
	out.append_string(self.percent_style.render(string::tformat("%d%%", (int)self.percent)));
	return out.str_view();
}

// ── layout tree ──────────────────────────────────────────────────────────────

// A progress bar spans its rect — that is the whole point of one.
fn String Progress.render(&self, xray::Rect r) @dynamic {
	self.width = r.w;
	return self.view();
}

fn int Progress.measure(&self, int width) @dynamic => 1;
fn int Progress.measure_width(&self, int height) @dynamic => self.width;

fn xray::Node* Progress.node(&self) => xray::content_node(self);
