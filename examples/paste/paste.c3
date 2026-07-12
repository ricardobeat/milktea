module paste_example;

import milktea;
import glaze;
import boba;
import xray;
import xray::layout;
import std::core::string;
import std::core::dstring;

// paste_example — demonstrates bracketed paste support.
//
// The app fills most of the screen with a Textarea; a one-line status bar at
// the bottom reports paste events (byte and line counts) and shows a usage
// hint while idle.  Normal typing goes through Textarea.handle_key; pasted
// text is delivered via MsgKind.PASTE → Textarea.handle_paste.
// Quit: Ctrl+C only ('q' must remain typeable inside the textarea).

struct PasteModel {
	boba::Textarea ta;
	int width;
	int height;
	// Status message shown in the footer bar.
	// Stored as a fixed char buffer so we never heap-allocate in update.
	char[128] status_buf;
	sz status_len;
}

fn String PasteModel.status(PasteModel* self) {
	if (self.status_len == 0) {
		return "paste something!  ctrl+c quits";
	}
	return (String)self.status_buf[:self.status_len];
}

fn void PasteModel.set_status(PasteModel* self, String s) {
	sz n = s.len < self.status_buf.len ? s.len : self.status_buf.len - 1;
	for (sz i = 0; i < n; i++) self.status_buf[i] = s[i];
	self.status_len = n;
}

fn milktea::Cmd PasteModel.init(PasteModel* self) @dynamic {
	self.ta = boba::new_textarea(80, 20)
		.with_placeholder("Start typing or paste text here...");
	self.ta.focused = true;
	self.ta.start_blink();
	return null;
}

fn milktea::Cmd PasteModel.update(PasteModel* self, milktea::Msg msg) @dynamic {
	switch (msg.kind) {
		case milktea::MsgKind.WINDOW_SIZE:
			self.width  = msg.window_size.width;
			self.height = msg.window_size.height;
			return null;

		case milktea::MsgKind.PASTE:
			// msg.paste is only valid during this dispatch call.
			// Capture byte count and line count before calling handle_paste,
			// which may modify the textarea but leaves the original slice intact.
			sz byte_count = msg.paste.len;
			int line_count = 1;
			for (sz i = 0; i < byte_count; i++) {
				if (msg.paste[i] == '\n') line_count++;
			}
			self.ta.handle_paste(msg.paste);
			// Build the status string into the fixed buffer via a temp DString.
			String s = string::tformat("pasted %d bytes (%d line%s)",
				(int)byte_count,
				line_count,
				line_count == 1 ? "" : "s");
			self.set_status(s);
			return null;

		case milktea::MsgKind.TICK:
			self.ta.update(msg);
			return null;

		case milktea::MsgKind.KEY:
			milktea::KeyMsg k = msg.key;
			if (k.code == milktea::KeyCode.CTRL_C) return milktea::quit();
			self.ta.handle_key(k);
			return null;

		default:
			return null;
	}
}

fn milktea::View PasteModel.view(PasteModel* self) @dynamic {
	int w = self.width  > 0 ? self.width  : 80;
	int h = self.height > 0 ? self.height : 24;

	// Layout: textarea area (fill) + one-line status bar.
	xray::Rect editor_r, status_r;
	layout::vstack(layout::screen(w, h), {
		layout::slot(layout::fill(1), &editor_r),
		layout::slot(layout::len(1),  &status_r),
	});

	// Fit textarea to available area (no padding — use full rect).
	self.ta.width  = editor_r.w;
	self.ta.height = editor_r.h;

	// Styles.
	glaze::Style editor_style = glaze::style()
		.foreground(glaze::color_hex("#e0e0e8"))
		.background(glaze::color_hex("#12121a"));

	glaze::Style status_style = glaze::style()
		.foreground(glaze::color_hex("#aaaaaa"))
		.background(glaze::color_hex("#1e1e30"))
		.width(w);

	glaze::Style hint_style = glaze::style()
		.foreground(glaze::color_hex("#555566"))
		.bold(false);

	// The status line: show paste result or the idle hint.
	String status_text;
	if (self.status_len > 0) {
		glaze::Style ok_style = glaze::style()
			.foreground(glaze::color_hex("#50fa7b"))
			.bold(true);
		status_text = status_style.render(
			string::tformat(" %s", ok_style.render(self.status())));
	} else {
		status_text = status_style.render(
			string::tformat(" %s", hint_style.render(self.status())));
	}

	// Render textarea filling the editor rect.
	String ta_rendered = editor_r.render(editor_style, self.ta.view());

	// Stack the two rows.
	DString out = dstring::temp();
	out.append_string(ta_rendered);
	out.append_char('\n');
	out.append_string(status_text);

	return milktea::new_alt_screen_view(out.str_view());
}

fn int main() {
	PasteModel m = { };
	milktea::@run(&m);
	return 0;
}
