// The view: styles, the log pane's Content, and the node tree the whole
// screen is built from.
module ai_harness;

import milktea;
import glaze;
import xray;
import md;
import std::core::dstring;
import std::core::mem;

// Theme holds every color the harness paints with, so restyling is one edit
// rather than a hunt through the tree.
struct Theme {
	glaze::Style title;
	glaze::Style output;
	glaze::Style input;
	glaze::Style hint;
	glaze::Style sidebar;
	glaze::Style sidebar_header;
	glaze::Style row_ok;
	glaze::Style row_error;
	glaze::Style dialog;
	glaze::Style bash_prompt;
}

const String SIDEBAR_BG = "#151515";
const String ACCENT     = "#00ffcc";

fn Theme theme() {
	glaze::Style boxed = glaze::style()
		.with_border(glaze::SQUARE).padding(0, 1, 0, 1)
		.border_fg(glaze::color_hex("#444444"))
		.corner_fg(glaze::color_hex(ACCENT));
	glaze::Style on_sidebar = glaze::style().background(glaze::color_hex(SIDEBAR_BG));
	return {
		.title  = glaze::style().foreground(glaze::color_hex(ACCENT)).with_bold(true),
		.output = boxed.foreground(glaze::color_hex("#aaaaaa")),
		.input  = boxed.foreground(glaze::color_hex("#ffff00")),
		.hint   = glaze::style().foreground(glaze::color_hex("#555555")),
		.sidebar = on_sidebar.foreground(glaze::color_hex("#cccccc")),
		.sidebar_header = on_sidebar.foreground(glaze::color_hex(ACCENT)).with_bold(true),
		.row_ok    = on_sidebar.foreground(glaze::color_hex("#00ff88")),
		.row_error = on_sidebar.foreground(glaze::color_hex("#ff5555")),
		.dialog = glaze::style()
			.foreground(glaze::color_hex("#ff7777"))
			.background(glaze::color_hex("#1a1a1a"))
			.with_border(glaze::ROUNDED).padding(1, 2, 1, 2),
		.bash_prompt = glaze::style()
			.foreground(glaze::color_hex("#ffcc00"))
			.background(glaze::color_hex("#3d2f00"))
			.with_bold(true),
	};
}

// OutputPane is the log pane's content. Scroll math needs the pane's real
// size, which the solver only settles at paint time — so it happens here in
// render(), not in view(), and the Viewport is updated with the rect the
// layout actually chose.
struct OutputPane (xray::Content) {
	Model* model;
	String text;
	glaze::Style style;
}

fn String OutputPane.render(&self, xray::Rect r) @dynamic {
	Transcript* t = &self.model.log;
	// The style frames the text with a border, so the text area is the rect
	// less that frame.
	t.view.width = r.w - 2;
	t.view.height = r.h - 2;
	t.view.set_content(md::count_lines(self.text));
	if (t.follow) t.view.scroll_to_bottom();
	String visible = md::slice_lines(self.text, t.view.offset, r.h - 2);
	return self.style.with_width(r.w).with_height(r.h).render(visible);
}

// hint_line is the status text under the input box.
fn String Model.hint_line(&self) {
	if (self.confirm_quit) return "  press q again to quit";
	if (!self.session.has_key()) return "  set XIAOMI_TOKEN_PLAN_KEY to use";
	return string::tformat("  %s | Enter send, q quit, = log, t thinking", DEFAULT_MODEL);
}

// prompt_line is the input box's contents, with a block caret when idle.
fn String Model.prompt_line(&self) {
	String typed = self.input.text();
	if (self.input.caret_on && !self.request.loading) {
		return string::tformat("> %s\xe2\x96\x88", typed);
	}
	return string::tformat("> %s", typed);
}

// transcript_text is the log plus whatever transient line belongs at the
// bottom: a pending bash approval, the spinner, or the last timing.
fn String Model.transcript_text(&self, Theme th, int width) {
	DString out = dstring::temp();
	out.append_string(self.log.text.str_view());

	if (self.bash.pending()) {
		int cap = width - 16;
		if (cap < 10) cap = 10;
		DString block = dstring::temp();
		block.append_string("  $ ");
		String cmd = self.bash.command();
		int shown = 0;
		for (int k = 0; k < cmd.len && shown < cap; k++) {
			block.append_char(cmd[k] == '\n' ? ' ' : cmd[k]);
			shown++;
		}
		if (cmd.len > cap) block.append_string("...");
		block.append_string("   [y]es  [n]o");
		out.append_string(th.bash_prompt.render(block.str_view()));
	} else if (self.request.loading) {
		out.append_string(string::tformat("%s Thinking...", self.request.spinner.current_frame()));
	} else if (self.request.last_sec > 10.0) {
		out.append_string(string::tformat("Thought for %.1fs", self.request.last_sec));
	}
	return out.str_view();
}

// sidebar_node is the request list: a background layer with the rows stacked
// over it. Rows past the pane's height solve to zero and never paint.
fn xray::Node* Model.sidebar_node(&self, Theme th, int width) {
	xray::Node* list = milktea::vstack()
		.add(milktea::text(th.sidebar_header, " REQUESTS").height(milktea::cells(1)))
		.add(milktea::text(th.sidebar, "").height(milktea::cells(1)));

	int rows = self.requests.count;
	if (rows > MAX_SIDEBAR_ROWS) rows = MAX_SIDEBAR_ROWS;
	for (int i = 0; i < rows; i++) {
		int code = self.requests.status[self.requests.count - 1 - i];
		glaze::Style rs = code < 400 ? th.row_ok : th.row_error;
		list.add(milktea::text(rs, string::tformat("  %-3d %s", code, status_label(code)))
			.height(milktea::cells(1)));
	}
	// Soak up the leftover height so the rows sit at the top.
	list.add(milktea::text(th.sidebar, "").fill(1));

	return milktea::zstack()
		.add(milktea::text(th.sidebar, ""))
		.add(list)
		.width(milktea::cells(width));
}

// dialog_node builds the centered modal. The box sizes itself to the wrapped
// text, so .center() measures it rather than the caller computing a rect.
fn xray::Node* dialog_node(int screen_w, String body, glaze::Style style) {
	int bw = screen_w - 6;
	if (bw < 2) bw = 2;
	if (bw > 76) bw = 76;
	// The tree is painted after view() returns, so the text must outlive this
	// call: tformat puts it in the temp arena, which lives until the frame ends.
	String text = string::tformat("%s", md::wrap_text(body, (sz)(bw - 4)).str_view());
	return milktea::text(style.with_width(bw), text).center();
}

fn milktea::View Model.view(&self) @dynamic {
	Theme th = theme();
	int w = milktea::screen_width();

	int sb_w = self.requests.open ? 30 : 0;
	if (sb_w > w - 24) sb_w = w - 24;
	if (sb_w < 0) sb_w = 0;

	OutputPane* pane = mem::tnew(OutputPane);
	pane.model = self;
	pane.text  = self.transcript_text(th, w - sb_w);
	pane.style = th.output;

	xray::Node* main = milktea::vstack()
		.add(milktea::text(th.title, "  AI HARNESS").height(milktea::cells(1)))
		.add(milktea::component(pane).fill(1))
		.add(milktea::text(th.input, self.prompt_line()).height(milktea::cells(3)))
		.add(milktea::text(th.hint, self.hint_line()).height(milktea::cells(1)));

	xray::Node* body = milktea::hstack().add(main.fill(1));
	if (self.requests.open && sb_w > 0) {
		body.add(self.sidebar_node(th, sb_w));
	}

	xray::Node* modal = null;
	if (self.dialog.showing) {
		modal = dialog_node(w, self.dialog.text(), th.dialog);
	}

	return milktea::draw(milktea::root().add(body).add(modal));
}
