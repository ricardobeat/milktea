// A terminal chat harness for a streaming completions API, with tool calls
// and an approval prompt for bash.
//
// The example is split by concern:
//   state.c3     the Model and its sub-structs, with their own small methods
//   session.c3   API config, message history, worker-thread callbacks
//   ui.c3        styles and the node tree view() builds
//   markdown.c3  module md: markdown -> ANSI, line slicing, wrapping
//   llm.c3       module llm: the request worker itself
//
// This file has the program lifecycle: init, the update loop, teardown.
module ai_harness;

import milktea;
import glaze;
import boba;
import md;
import std::io;
import std::core::dstring;
import std::core::mem;
import llm;

fn milktea::Cmd Model.init(&self) @dynamic {
	self.log.text.tinit();
	self.log.view = boba::new_viewport(0, 0);
	self.log.follow = true;
	self.request.spinner = boba::new_spinner(boba::SpinnerKind.LINE).with_color(glaze::color_hex(ACCENT));
	self.request.last_sec = -1.0;

	if (!self.session.read_api_key()) {
		io::eprintfn("ai-harness: XIAOMI_TOKEN_PLAN_KEY is not set.\n");
		io::eprintfn("Set it and re-run, e.g.  export XIAOMI_TOKEN_PLAN_KEY=your_key_here\n");
		return milktea::quit();
	}
	self.log.line("AI Harness ready. Type a prompt, press Enter.");
	self.log.line("Tools: view_file, edit_file, bash");
	self.session.add_message("system", llm::SYSTEM_PROMPT);
	return null;
}

// handle_worker_msg takes the payloads the llm thread posts back. Each tag
// owns its allocation from here on, so every branch frees what it was given.
fn milktea::Cmd Model.handle_worker_msg(&self, milktea::Msg msg) {
	switch (msg.tag) {
		case MSG_STREAM:
			DString* ds = (DString*)msg.user;
			self.log.text.append_string(ds.str_view());
			ds.free();
			mem::free(ds);

		case MSG_TOOL:
			DString* ds = (DString*)msg.user;
			glaze::Style tool_s = glaze::style().foreground(glaze::color_hex("#8888ff"));
			self.log.text.append_char('\n');
			self.log.text.append_string(tool_s.render(ds.str_view()));
			self.log.text.append_char('\n');
			ds.free();
			mem::free(ds);

		case MSG_BASH:
			BashReq* br = (BashReq*)msg.user;
			self.bash.set(br.cmd.str_view(), br.ack);

		case MSG_DONE:
			llm::Result* hr = (llm::Result*)msg.user;
			self.requests.add(hr.status);
			if (hr.ok) {
				if (self.session.show_thinking && hr.reasoning.len() > 0) {
					glaze::Style think_s = glaze::style().foreground(glaze::color_hex("#666666")).with_italic(true);
					self.log.text.append_string("\n");
					self.log.text.append_string(think_s.render(hr.reasoning.str_view()));
					self.log.text.append_string("\n\n");
				}
				DString styled = md::render(hr.body.str_view());
				self.log.text.append_string("\n");
				self.log.text.append_string(styled.str_view());
				styled.free();
				self.session.add_message("assistant", hr.body.str_view());
				self.log.text.append_char('\n');
			} else {
				self.dialog.show("Error", hr.body.str_view());
			}
			self.request.finish();
			hr.body.free();
			hr.reasoning.free();
			mem::free(hr);

		default:
	}
	return null;
}

// handle_bash_key resolves a pending approval. Only y/Enter and n/ESC count;
// every other key is swallowed so the prompt cannot be walked past.
fn milktea::Cmd Model.handle_bash_key(&self, milktea::KeyMsg k) {
	bool yes = k.code == milktea::KeyCode.ENTER
		|| (k.code == milktea::KeyCode.RUNE && (k.rune == 'y' || k.rune == 'Y'));
	bool no = k.code == milktea::KeyCode.ESC
		|| (k.code == milktea::KeyCode.RUNE && (k.rune == 'n' || k.rune == 'N'));
	if (!yes && !no) return null;

	String cmd = self.bash.command();
	self.bash.resolve(yes);

	glaze::Style style = yes
		? glaze::style().foreground(glaze::color_hex("#7cf68e")).with_bold(true)
		: glaze::style().foreground(glaze::color_hex("#ff5555"));
	String prefix = yes ? "$ " : "[denied] $ ";
	self.log.text.append_char('\n');
	self.log.text.append_string(style.render(string::tformat("%s%s", prefix, cmd)));
	self.log.text.append_char('\n');
	return milktea::tick(80);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER) {
		return self.handle_worker_msg(msg);
	}

	// A bash tool is awaiting approval. This is checked before the quit keys
	// so ESC denies the command rather than quitting the program.
	if (self.bash.pending()) {
		if (msg.kind == milktea::MsgKind.KEY) return self.handle_bash_key(msg.key);
		return null;
	}

	// Quit keys: ESC/Ctrl-C cancel if loading, otherwise quit.
	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg qk = msg.key;
		if (qk.code == milktea::KeyCode.ESC || qk.code == milktea::KeyCode.CTRL_C) {
			if (self.request.loading) {
				self.request.cancel.store(1);
				self.request.finish();
				self.log.text.append_string("\n[cancelled]\n");
				return null;
			}
			return milktea::quit();
		}
		if (qk.code == milktea::KeyCode.RUNE && qk.rune == 'q' && self.input.len == 0) {
			if (self.confirm_quit) return milktea::quit();
			self.confirm_quit = true;
			return null;
		}
		self.confirm_quit = false;
	}

	// A modal is showing: any key dismisses it.
	if (self.dialog.showing) {
		if (msg.kind == milktea::MsgKind.KEY) self.dialog.showing = false;
		return null;
	}

	// TICK drives the spinner while loading, otherwise the caret blink.
	if (msg.kind == milktea::MsgKind.TICK) {
		if (self.request.loading) {
			self.request.spinner.advance();
			return milktea::tick(80);
		}
		self.input.caret_on = !self.input.caret_on;
		return milktea::tick(500);
	}

	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.UP:
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.PAGE_UP:
		case milktea::KeyCode.PAGE_DOWN:
		case milktea::KeyCode.HOME:
		case milktea::KeyCode.END:
			self.log.view.handle_key(k);
			// Scrolling back turns off follow; scrolling to the end turns it
			// on again, so new output resumes tracking without a keybind.
			sz maxo = self.log.view.total_lines - self.log.view.height;
			if (maxo < 0) maxo = 0;
			self.log.follow = self.log.view.offset >= maxo;
			return null;

		case milktea::KeyCode.ENTER:
			if (self.input.len > 0 && self.session.has_key() && !self.request.loading) {
				String user_input = self.input.text();
				self.log.text.append_string("\n> ");
				self.log.text.append_string(user_input);
				self.log.text.append_char('\n');
				self.session.add_message("user", user_input);
				self.input.clear();
				return self.kickoff();
			}

		case milktea::KeyCode.BACKSPACE: self.input.backspace();
		case milktea::KeyCode.LEFT:      self.input.left();
		case milktea::KeyCode.RIGHT:     self.input.right();

		case milktea::KeyCode.RUNE:
			if (k.rune == '=') {
				self.requests.open = !self.requests.open;
				return null;
			}
			if (k.rune == 't' && self.input.len == 0) {
				self.session.show_thinking = !self.session.show_thinking;
				return null;
			}
			self.input.insert(k.rune);

		default:
	}
	return null;
}

fn void Model.on_destroy(&self) @dynamic {
	self.log.text.free();
	for (sz i = 0; i < self.session.history_count; i++) {
		self.session.history[i].json.free();
	}
}

fn int main() {
	Model* m = mem::new(Model);
	*m = {};
	return milktea::@run(m, { .alt_screen = true });
}
