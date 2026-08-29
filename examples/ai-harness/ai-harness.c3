module ai_harness;

import milktea;
import glaze;
import boba;
import xray::layout;
import std::io;
import std::core::dstring;
import std::core::mem;
import std::atomic;
import std::thread::channel;
import llm;

const int INPUT_BUF_SIZE = 4096;
const int MAX_HISTORY = 64;

const String API_URL = "https://token-plan-ams.xiaomimimo.com/v1/chat/completions";
const String DEFAULT_MODEL = "mimo-v2.5";
const int HTTP_TIMEOUT_MS = 120000;

extern fn char* getenv(char* name);

// Message tags for llm callbacks -> main thread.
const int MSG_STREAM = 1; // user = DString* (delta text)
const int MSG_DONE   = 2; // user = llm::Result*
const int MSG_TOOL   = 3; // user = DString* (tool description)
const int MSG_BASH   = 4; // user = BashReq*

struct BashReq {
	DString cmd;
	channel::OneShotChannel{int}* ack;
}

struct Model {
	char[INPUT_BUF_SIZE] input_buf;
	sz input_len;
	sz input_cursor;
	DString output;
	int loading;
	int cursor_blink;
	boba::Spinner thinking;
	char[512] api_key;
	int api_key_len;
	llm::HistoryEntry[MAX_HISTORY] history;
	int history_count;
	int modal;
	int modal_msg_len;
	char[1024] modal_msg;
	int[64] log_status;
	int log_count;
	int sidebar_open;
	int confirm_quit;
	int ask_bash;
	char[4096] bash_pending;
	int bash_pending_len;
	channel::OneShotChannel{int}* bash_ack;
	sz think_start_ms;
	double last_think_sec;
	boba::Viewport output_view;
	int output_follow;
	int show_thinking;
	Atomic{int} cancel;
}

// ── Callbacks (run on the background thread) ───────────────────────────────

fn int cb_stream(void* ctx, String delta) {
	DString* ds = mem::new(DString);
	*ds = dstring::new(mem);
	ds.append_string(delta);
	milktea::g_program.send({ .kind = milktea::MsgKind.USER, .tag = MSG_STREAM, .user = (void*)ds });
	return 0;
}

fn void cb_tool(void* ctx, String description) {
	DString* ds = mem::new(DString);
	*ds = dstring::new(mem);
	ds.append_string(description);
	milktea::g_program.send({ .kind = milktea::MsgKind.USER, .tag = MSG_TOOL, .user = (void*)ds });
}

fn int cb_bash(void* ctx, String command) {
	channel::OneShotChannel{int}* ack = channel::create_one_shot(mem)!!;
	BashReq* br = mem::new(BashReq);
	br.cmd = dstring::new(mem);
	br.cmd.append_string(command);
	br.ack = ack;
	milktea::g_program.send({ .kind = milktea::MsgKind.USER, .tag = MSG_BASH, .user = (void*)br });
	int go = ack.pop()!!;
	br.cmd.free();
	mem::free(br);
	ack.destroy();
	return go;
}

fn void cb_done(void* ctx, llm::Result* result) {
	milktea::g_program.send({ .kind = milktea::MsgKind.USER, .tag = MSG_DONE, .user = (void*)result });
}

// ── History helpers ────────────────────────────────────────────────────────

fn void json_escape(DString* out, String input) {
	sz i = 0;
	while (i < input.len) {
		char c = input[i];
		switch (c) {
			case '"':  out.append_string("\\\"");
			case '\\': out.append_string("\\\\");
			case '\n': out.append_string("\\n");
			case '\r': out.append_string("\\r");
			case '\t': out.append_string("\\t");
			case '\b': out.append_string("\\b");
			case '\f': out.append_string("\\f");
			default:
				if (c < 0x20) {
					out.append_string(string::tformat("\\u%04x", (int)c));
				} else {
					out.append_char(c);
				}
		}
		i++;
	}
}

fn void add_message(Model* self, String role, String content) {
	if (self.history_count >= MAX_HISTORY) return;
	llm::HistoryEntry* msg = &self.history[self.history_count];
	msg.json.tinit();
	msg.json.append_string("{\"role\":\"");
	msg.json.append_string(role);
	msg.json.append_string("\",\"content\":\"");
	json_escape(&msg.json, content);
	msg.json.append_string("\"}");
	self.history_count++;
}

fn void add_raw_message(Model* self, String json_obj) {
	if (self.history_count >= MAX_HISTORY) return;
	llm::HistoryEntry* msg = &self.history[self.history_count];
	msg.json.tinit();
	msg.json.append_string(json_obj);
	self.history_count++;
}

fn bool read_api_key(Model* self) {
	char* val = getenv("XIAOMI_TOKEN_PLAN_KEY");
	if (val == null) return false;
	sz len = 0;
	while (val[len] != 0) len++;
	if (len > 511) len = 511;
	mem::copy(&self.api_key[0], val, len);
	self.api_key[len] = 0;
	self.api_key_len = (int)len;
	return true;
}

// ── Kickoff ────────────────────────────────────────────────────────────────

fn milktea::Cmd kickoff(Model* self) {
	self.think_start_ms = milktea::time_ms();
	self.loading = 1;
	self.cancel.store(0);

	llm::Config config = {};
	mem::copy(&config.url[0], &API_URL[0], (sz)API_URL.len + 1);
	mem::copy(&config.api_key[0], &self.api_key[0], (sz)self.api_key_len + 1);
	mem::copy(&config.model[0], &DEFAULT_MODEL[0], (sz)DEFAULT_MODEL.len + 1);
	config.timeout_ms = HTTP_TIMEOUT_MS;

	llm::start(config, &self.history[0], self.history_count, &self.cancel,
		&cb_stream, &cb_tool, &cb_bash, &cb_done, (void*)self);

	return milktea::tick(80);
}

// ── Modal / log helpers ────────────────────────────────────────────────────

fn void show_modal(Model* self, String title, String body) {
	DString buf = dstring::new(mem);
	buf.append_string(title);
	buf.append_string("\n\n");
	buf.append_string(body);
	String s = buf.str_view();
	sz n = s.len < 1023 ? s.len : 1023;
	mem::copy(&self.modal_msg[0], s.ptr, n);
	self.modal_msg[n] = 0;
	self.modal_msg_len = (int)n;
	buf.free();
	self.modal = 1;
}

fn void add_log(Model* self, int status) {
	if (self.log_count < 64) {
		self.log_status[self.log_count] = status;
		self.log_count++;
	}
}

fn String status_label(int code) {
	if (code < 300) return "ok";
	if (code < 400) return "redirect";
	return "error";
}

// ── init / update / view ───────────────────────────────────────────────────

fn milktea::Cmd Model.init(&self) @dynamic {
	self.output.tinit();
	self.thinking = boba::new_spinner(boba::SpinnerKind.LINE).with_color(glaze::color_hex("#00ffcc"));
	self.last_think_sec = -1.0;
	self.output_view = boba::new_viewport(0, 0);
	self.output_follow = 1;

	if (!read_api_key(self)) {
		io::eprintfn("ai-harness: XIAOMI_TOKEN_PLAN_KEY is not set.\n");
		io::eprintfn("Set it and re-run, e.g.  export XIAOMI_TOKEN_PLAN_KEY=your_key_here\n");
		return milktea::quit();
	}
	self.output.append_string("AI Harness ready. Type a prompt, press Enter.\n");
	self.output.append_string("Tools: view_file, edit_file, bash\n");
	add_message(self, "system", llm::SYSTEM_PROMPT);
	return null;
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	// Incoming messages from the llm background thread.
	if (msg.kind == milktea::MsgKind.USER) {
		if (msg.tag == MSG_STREAM) {
			DString* ds = (DString*)msg.user;
			self.output.append_string(ds.str_view());
			ds.free();
			mem::free(ds);
			return null;
		}
		if (msg.tag == MSG_TOOL) {
			DString* ds = (DString*)msg.user;
			glaze::Style tool_s = glaze::style().foreground(glaze::color_hex("#8888ff"));
			self.output.append_char('\n');
			self.output.append_string(tool_s.render(ds.str_view()));
			self.output.append_char('\n');
			ds.free();
			mem::free(ds);
			return null;
		}
		if (msg.tag == MSG_BASH) {
			BashReq* br = (BashReq*)msg.user;
			String cmd = br.cmd.str_view();
			int n = cmd.len < 4095 ? (int)cmd.len : 4095;
			mem::copy(&self.bash_pending[0], cmd.ptr, (sz)n);
			self.bash_pending[n] = 0;
			self.bash_pending_len = n;
			self.bash_ack = br.ack;
			self.ask_bash = 1;
			return null;
		}
		if (msg.tag == MSG_DONE) {
			llm::Result* hr = (llm::Result*)msg.user;
			add_log(self, hr.status);
			if (hr.ok) {
				if (self.show_thinking && hr.reasoning.len() > 0) {
					glaze::Style think_s = glaze::style().foreground(glaze::color_hex("#666666")).with_italic(true);
					self.output.append_string("\n");
					self.output.append_string(think_s.render(hr.reasoning.str_view()));
					self.output.append_string("\n\n");
				}
				DString styled = md_render(hr.body.str_view());
				self.output.append_string("\n");
				self.output.append_string(styled.str_view());
				styled.free();
				add_message(self, "assistant", hr.body.str_view());
				self.output.append_char('\n');
			} else {
				show_modal(self, "Error", hr.body.str_view());
			}
			self.last_think_sec = ((double)(milktea::time_ms() - self.think_start_ms)) / 1000.0;
			self.loading = 0;
			hr.body.free();
			hr.reasoning.free();
			mem::free(hr);
			return null;
		}
	}

	// A bash tool is awaiting approval: only y/Enter (run) or n/ESC (deny)
	// resolve it. We resolve before the quit handling so ESC denies the command
	// rather than quitting.
	if (self.ask_bash) {
		if (msg.kind == milktea::MsgKind.KEY) {
			milktea::KeyMsg ak = msg.key;
			bool yes = ak.code == milktea::KeyCode.ENTER
				|| (ak.code == milktea::KeyCode.RUNE && (ak.rune == 'y' || ak.rune == 'Y'));
			bool no = ak.code == milktea::KeyCode.ESC
				|| (ak.code == milktea::KeyCode.RUNE && (ak.rune == 'n' || ak.rune == 'N'));
			if (yes || no) {
				self.bash_ack.push(yes ? 1 : 0)!!;
				self.ask_bash = 0;

				self.output.append_char('\n');
				String cmd = (String)self.bash_pending[:self.bash_pending_len];
				glaze::Style run_s  = glaze::style().foreground(glaze::color_hex("#7cf68e")).with_bold(true);
				glaze::Style deny_s = glaze::style().foreground(glaze::color_hex("#ff5555"));
				DString cline = dstring::new(mem);
				if (yes) {
					cline.append_string("$ ");
					cline.append_string(cmd);
					self.output.append_string(run_s.render(cline.str_view()));
				} else {
					cline.append_string("[denied] $ ");
					cline.append_string(cmd);
					self.output.append_string(deny_s.render(cline.str_view()));
				}
				cline.free();
				self.output.append_char('\n');
				return milktea::tick(80);
			}
		}
		return null;
	}

	// Quit keys: ESC/Ctrl-C cancel if loading, otherwise quit.
	if (msg.kind == milktea::MsgKind.KEY) {
		milktea::KeyMsg qk = msg.key;
		if (qk.code == milktea::KeyCode.ESC || qk.code == milktea::KeyCode.CTRL_C) {
			if (self.loading) {
				self.cancel.store(1);
				self.loading = 0;
				self.last_think_sec = ((double)(milktea::time_ms() - self.think_start_ms)) / 1000.0;
				self.output.append_string("\n[cancelled]\n");
				return null;
			}
			return milktea::quit();
		}
		if (qk.code == milktea::KeyCode.RUNE && qk.rune == 'q' && self.input_len == 0) {
			if (self.confirm_quit) return milktea::quit();
			self.confirm_quit = 1;
			return null;
		}
		if (self.confirm_quit) self.confirm_quit = 0;
	}

	// A modal dialog is showing: consume any key to dismiss it.
	if (self.modal != 0) {
		if (msg.kind == milktea::MsgKind.KEY) {
			self.modal = 0;
		}
		return null;
	}

	// TICK drives the spinner while loading, otherwise the cursor blink.
	if (msg.kind == milktea::MsgKind.TICK) {
		if (self.loading) {
			self.thinking.advance();
			return milktea::tick(80);
		}
		self.cursor_blink = 1 - self.cursor_blink;
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
			self.output_view.handle_key(k);
			{
				int maxo = self.output_view.total_lines - self.output_view.height;
				if (maxo < 0) maxo = 0;
				self.output_follow = (self.output_view.offset >= maxo) ? 1 : 0;
			}
			return null;
		case milktea::KeyCode.ENTER:
			if (self.input_len > 0 && self.api_key_len > 0 && self.loading == 0) {
				String user_input = (String)self.input_buf[:self.input_len];

				self.output.append_string("\n> ");
				self.output.append_string(user_input);
				self.output.append_char('\n');

				add_message(self, "user", user_input);
				self.input_len = 0;
				self.input_cursor = 0;

				return kickoff(self);
			}
		case milktea::KeyCode.BACKSPACE:
			if (self.input_cursor > 0) {
				for (sz i = self.input_cursor; i < self.input_len; i++) {
					self.input_buf[i - 1] = self.input_buf[i];
				}
				self.input_len--;
				self.input_cursor--;
			}
		case milktea::KeyCode.LEFT:
			if (self.input_cursor > 0) self.input_cursor--;
		case milktea::KeyCode.RIGHT:
			if (self.input_cursor < self.input_len) self.input_cursor++;
		case milktea::KeyCode.RUNE:
			if (k.rune == '=') {
				self.sidebar_open = 1 - self.sidebar_open;
				return null;
			}
			if (k.rune == 't' && self.input_len == 0) {
				self.show_thinking = 1 - self.show_thinking;
				return null;
			}
			char[4] enc;
			sz n = milktea::utf8_encode(k.rune, enc[..]);
			if (self.input_len + n < INPUT_BUF_SIZE) {
				for (sz i = self.input_len; i > self.input_cursor; i--) {
					self.input_buf[i + n - 1] = self.input_buf[i - 1];
				}
				for (sz i = 0; i < n; i++) self.input_buf[self.input_cursor + i] = enc[i];
				self.input_len += n;
				self.input_cursor += n;
			}
		default:
	}
	return null;
}

// ---- lightweight markdown->ANSI renderer for assistant output ----

fn void md_seg_render(DString* out, glaze::Style style, String s) {
	if (s.len == 0) return;
	out.append_string(style.render(s));
}

fn void md_plain(DString* out, glaze::Style style, String s) {
	DString clean = dstring::new(mem);
	for (sz i = 0; i < s.len; i++) {
		char c = s[i];
		if (c == '*' || c == '_') continue;
		clean.append_char(c);
	}
	md_seg_render(out, style, clean.str_view());
	clean.free();
}

fn void md_emit_inline(DString* out, String line, glaze::Style base, glaze::Style code) {
	if (!line.contains_char('`')) {
		md_plain(out, base, line);
		return;
	}
	bool is_code = false;
	Splitter it = line.tokenize_all("`");
	while (!it.at_end()) {
		String seg = it.next() ?? "";
		if (is_code) {
			md_seg_render(out, code, seg);
		} else {
			md_plain(out, base, seg);
		}
		is_code = !is_code;
	}
}

fn int count_lines(String s) {
	int n = 0;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') n++;
	}
	if (s.len == 0 || s[s.len - 1] != '\n') n++;
	return n;
}

fn String slice_lines(String s, int start, int count) {
	if (count <= 0 || start < 0) return (String)s[0:0];
	sz begin = 0;
	int line = 0;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') {
			line++;
			if (line == start) {
				begin = i + 1;
				break;
			}
		}
	}
	if (line < start) return (String)s[0:0];

	sz end = s.len;
	int taken = 0;
	for (sz i = begin; i < s.len; i++) {
		if (s[i] == '\n') {
			taken++;
			if (taken == count) {
				end = i + 1;
				break;
			}
		}
	}
	return (String)s[begin:end - begin];
}

fn DString md_render(String md) {
	glaze::Style base   = glaze::style().foreground(glaze::color_hex("#aaaaaa"));
	glaze::Style header = glaze::style().foreground(glaze::color_hex("#00ffcc")).with_bold(true);
	glaze::Style code   = glaze::style().foreground(glaze::color_hex("#ffcc00"));
	glaze::Style quote  = glaze::style().foreground(glaze::color_hex("#7f7f7f"));

	DString o = dstring::new(mem);
	bool in_code = false;
	Splitter lines = md.tokenize_all("\n");
	while (!lines.at_end()) {
		String line = lines.next() ?? "";

		if (line.starts_with("```")) {
			in_code = !in_code;
			continue;
		}
		if (in_code) {
			DString ind = dstring::new(mem);
			ind.append_string("    ");
			ind.append_string(line);
			md_seg_render(&o, code, ind.str_view());
			ind.free();
			o.append_char('\n');
			continue;
		}
		if (line.starts_with("#")) {
			String rest = line;
			while (rest.starts_with("#")) rest = rest.strip_prefix("#");
			rest = rest.trim_left(" \t");
			md_emit_inline(&o, rest, header, code);
			o.append_char('\n');
			continue;
		}
		if (line.starts_with(">")) {
			String rest = line.strip_prefix(">").trim_left(" \t");
			o.append_string(quote.render("> "));
			md_emit_inline(&o, rest, quote, code);
			o.append_char('\n');
			continue;
		}
		md_emit_inline(&o, line, base, code);
		o.append_char('\n');
	}
	return o;
}

fn DString wrap_text(String s, sz width) {
	DString out = dstring::new(mem);
	sz col = 0;
	for (sz i = 0; i < s.len; i++) {
		char c = s[i];
		if (c == '\n') {
			out.append_char('\n');
			col = 0;
		} else {
			if (col == width) {
				out.append_char('\n');
				col = 0;
			}
			out.append_char(c);
			col++;
		}
	}
	return out;
}

fn milktea::View draw_dialog(milktea::View v, xray::Rect area, int w, String body, glaze::Style style) {
	int bw = w - 6;
	if (bw < 2) bw = 2;
	if (bw > 76) bw = 76;
	DString wrapped = wrap_text(body, (sz)(bw - 4));
	sz lines = 1;
	String ws = wrapped.str_view();
	for (sz i = 0; i < ws.len; i++) if (ws[i] == '\n') lines++;
	sz bh = lines + 2;
	if (bh > (sz)area.h) bh = (sz)area.h;
	if (bh < 4) bh = 4;

	xray::Rect r = {
		.x = (w - bw) / 2,
		.y = area.y + (area.h - (int)bh) / 2,
		.w = bw,
		.h = (int)bh,
	};
	v = v.draw(r, style, wrapped.str_view());
	wrapped.free();
	return v;
}

fn milktea::View Model.view(&self) @dynamic {
	int w = milktea::screen_width();
	int h = milktea::screen_height();

	String inp_content = string::tformat("> %s", (String)self.input_buf[:self.input_len]);
	if (self.cursor_blink != 0 && !self.loading) {
		inp_content = string::tformat("> %s\xe2\x96\x88", (String)self.input_buf[:self.input_len]);
	}

	String status;
	if (self.confirm_quit) {
		status = "  press q again to quit";
	} else if (self.api_key_len == 0) {
		status = "  set XIAOMI_TOKEN_PLAN_KEY to use";
	} else {
		status = string::tformat("  %s | Enter send, q quit, = log, t thinking", DEFAULT_MODEL);
	}

	int sb_w = self.sidebar_open ? 30 : 0;
	if (sb_w > w - 24) sb_w = w - 24;
	if (sb_w < 0) sb_w = 0;
	xray::Rect main_r = { .x = 0, .y = 0, .w = w - sb_w, .h = h };
	xray::Rect title_r, output_r, input_r, hint_r;
	layout::vstack(main_r, {
		layout::slot(layout::cells(1),    &title_r),
		layout::slot(layout::fill(1),   &output_r),
		layout::slot(layout::cells(3),    &input_r),
		layout::slot(layout::cells(1),    &hint_r),
	});

	glaze::Style title_s  = glaze::style().foreground(glaze::color_hex("#00ffcc")).with_bold(true);
	glaze::Style output_s = glaze::style().foreground(glaze::color_hex("#aaaaaa"));
	glaze::Style input_s  = glaze::style().foreground(glaze::color_hex("#ffff00"))
		.with_border(glaze::ROUNDED).padding(0, 1, 0, 1);
	glaze::Style hint_s   = glaze::style().foreground(glaze::color_hex("#555555"));

	DString out_content = dstring::new(mem);
	out_content.append_string(self.output.str_view());
	if (self.ask_bash) {
		int cap = main_r.w - 16;
		if (cap < 10) cap = 10;
		DString block = dstring::new(mem);
		block.append_string("  $ ");
		int shown = 0;
		for (int k = 0; k < self.bash_pending_len && shown < cap; k++) {
			char bc = self.bash_pending[k];
			block.append_char(bc == '\n' ? ' ' : bc);
			shown++;
		}
		if (self.bash_pending_len > cap) block.append_string("...");
		block.append_string("   [y]es  [n]o");
		glaze::Style bstyle = glaze::style()
			.foreground(glaze::color_hex("#ffcc00"))
			.background(glaze::color_hex("#3d2f00"))
			.with_bold(true);
		out_content.append_string(bstyle.render(block.str_view()));
		block.free();
	} else if (self.loading) {
		out_content.append_string(string::tformat("%s Thinking...", self.thinking.current_frame()));
	} else if (self.last_think_sec > 10.0) {
		out_content.append_string(string::tformat("Thought for %.1fs", self.last_think_sec));
	}

	self.output_view.width = output_r.w;
	self.output_view.height = output_r.h;
	String log_view = out_content.str_view();
	self.output_view.set_content(count_lines(log_view));
	if (self.output_follow != 0) {
		self.output_view.scroll_to_bottom();
	}
	String visible = slice_lines(log_view, self.output_view.offset, (int)output_r.h);

	milktea::View v = milktea::new_cell_view(w, h)
		.draw(title_r, title_s, "  AI HARNESS")
		.draw(output_r, output_s, visible)
		.draw(input_r, input_s, inp_content)
		.draw(hint_r, hint_s, status);
	out_content.free();

	if (self.sidebar_open && sb_w > 0) {
		xray::Rect sb = { .x = w - sb_w, .y = 0, .w = sb_w, .h = h };
		glaze::Style sb_bg = glaze::style()
			.background(glaze::color_hex("#151515")).foreground(glaze::color_hex("#cccccc"));
		v = v.draw(sb, sb_bg, "");

		glaze::Style hdr = glaze::style()
			.foreground(glaze::color_hex("#00ffcc")).with_bold(true).background(glaze::color_hex("#151515"));
		v = v.draw({ .x = sb.x, .y = sb.y, .w = sb.w, .h = 1 }, hdr, " REQUESTS");

		int rows = self.log_count;
		int fit  = sb.h - 2;
		if (rows > fit) rows = fit;
		if (rows < 0) rows = 0;
		for (int i = 0; i < rows; i++) {
			int code = self.log_status[self.log_count - 1 - i];
			glaze::Style rs = code < 400
				? glaze::style().foreground(glaze::color_hex("#00ff88")).background(glaze::color_hex("#151515"))
				: glaze::style().foreground(glaze::color_hex("#ff5555")).background(glaze::color_hex("#151515"));
			xray::Rect rr = { .x = sb.x, .y = sb.y + 2 + i, .w = sb.w, .h = 1 };
			v = v.draw(rr, rs, string::tformat("  %-3d %s", code, status_label(code)));
		}
	}

	if (self.modal != 0) {
		glaze::Style modal_s = glaze::style()
			.foreground(glaze::color_hex("#ff7777"))
			.background(glaze::color_hex("#1a1a1a"))
			.with_border(glaze::ROUNDED).padding(1, 2, 1, 2);
		v = draw_dialog(v, output_r, w, (String)self.modal_msg[:self.modal_msg_len], modal_s);
	}

	return v;
}

fn void Model.on_destroy(&self) @dynamic {
	self.output.free();
	for (int i = 0; i < self.history_count; i++) {
		self.history[i].json.free();
	}
}

fn int main() {
	Model* m = mem::new(Model);
	*m = {};
	return milktea::@run(m);
}
