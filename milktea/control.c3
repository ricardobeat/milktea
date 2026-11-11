// Left out of a build with -D NO_CONTROL (see control_off.c3).
module milktea @feat(!NO_CONTROL);

import xray;
import std::core::dstring;
import std::core::string;
import std::math;
import utf8;

// Control drives a running program from the command line. When the program's
// stdin is not a terminal, each line of stdin is a command and each reply a
// line on stdout. A GUI's stdin is never keys, so it takes commands even
// headed; a terminal program takes them whenever its stdin is piped.
//
//   tree [SEL]            the tree, from the root or each match's subtree
//   list SEL              the nodes a selector matches, one a line
//   match PATTERN         nodes whose on-screen text matches the pattern
//   click SEL | @c,r      move there, press and release; $name is a node's
//                         key ($"two words" holds spaces)
//   press, release, move SEL | @c,r
//   drag FROM TO          each a selector or @c,r
//   scroll [WHERE] [dy=N] [dx=N]
//   key SPEC              "ctrl+b", "enter", "shift+tab", "a"
//   type TEXT             the rest of the line, as keys
//   select SEL TEXT|/PAT/ [NTH]  drag across text on screen
//   screen [PATTERN]      the text on screen, or only the lines that match
//   stream                echo the input the program gets as commands
//   quit
//
// A program started with MILKTEA_CONTROL=1 also takes commands while it runs
// as usual, sent by `<program> --cmd ...` (see control_pipe.c3).
//
// A command answers with its output, then "ok"; a failure answers one line
// "err ...". A node is picked by selector, matched against the last drawn
// frame:
//
//   word          a node whose id, role (button, list-item, ...) or content
//                 type (View) is word; * is any node
//   [key="v"]     its key, id, role, type or on-screen text: = is equal,
//                 *= contains, ^= starts with
//   $v            a node whose key is v, as [key="v"]; $"a b" for spaces;
//                 after a word too: button$v
//   :focused      it has keyboard focus; :clickable, it takes clicks
//   :nth(n)       the nth match, from 0, of the whole selector
//   a b           b inside a
//
// With stream on, input the program gets is echoed back as the commands that
// repeat it: "key ctrl+b", "click @5,3", "scroll @5,3 dy=1".

// ── Input hooks ────────────────────────────────────────────────────────────

// A backend injects input its own way: the terminal through its message
// queue, a window through its event handler. Positions are in layout units.
alias ControlPointerFn = fn void(MouseAction action, sz x, sz y);
alias ControlScrollFn = fn void(sz x, sz y, double dx, double dy);

struct ControlHooks {
	ControlPointerFn pointer;
	ControlScrollFn scroll;
}

// A window installs hooks; a terminal has none.
fn bool g_ctl_is_window() @private => g_ctl.hooks.pointer != null;

// install_control_hooks is for backends whose input does not go through the
// message queue (see the GUI).
fn void install_control_hooks(ControlHooks hooks) {
	g_ctl.hooks = hooks;
}

// ── State ──────────────────────────────────────────────────────────────────

// CtlNode is a node of the last drawn frame. Strings are kept as spans of
// the snapshot's own buffer, since the frame's tree is freed after drawing.
struct CtlSpan @local {
	sz at;
	sz len;
}

struct CtlNode @local {
	sz parent;
	CtlSpan id;
	CtlSpan key;
	CtlSpan type;
	xray::Role role;
	xray::Rect rect;
	xray::Rect inner;
	bool clickable;
	bool interactive;
	bool focusable;
	bool focused;
	sz child_count;
}

struct Control @local {
	bool started;
	bool on;
	// Command lines come from the terminal's reader thread (true) or are
	// read from stdin here, which is what a GUI does with its spare stdin.
	bool from_queue;
	bool stdin_eof;
	// Where replies go: stdout, or nowhere for a program drawing on the
	// terminal that stdout is. A command from --cmd names a pipe of its own
	// for the one reply (reply_piped), closed when the reply ends.
	int reply_default;
	int reply_fd;
	bool reply_piped;
	// An input command's "ok" waits for the frame its input draws.
	bool ok_owed;
	// The loop itself reads stdin and the command pipe (a GUI): their lines
	// are put together here.
	LineAsm stdin_lines;
	LineAsm pipe_lines;
	DString inbuf;
	InputQueue queue;
	bool stream;
	ControlHooks hooks;
	bool pressed;
	// A command sent input: the lines after it wait for the frame that shows
	// what it did, so they act on that frame and not the one before.
	bool waiting;
	sz wait_frame;
	sz wait_passes;
	// The snapshot of the last drawn frame: a node array and the string pool
	// its spans point into, both exact-size (control_on_draw counts first).
	CtlNode[] nodes;
	char[] strs;
	sz strs_at;
	xray::ScreenBuffer* buf;
	xray::LayoutMetrics metrics;
	sz frame;
	sz repaint_ms;
	// The last pointer position reported to streamers, in layout units.
	sz event_x;
	sz event_y;
}

Control g_ctl @local;

// control_start turns the command stream on: stdin is commands, stdout
// replies. The GUI calls it, and a terminal program whose stdin is piped.
fn void control_start() {
	if (g_ctl.started) return;
	g_ctl.started = true;
	if (catch input_queue_init(&g_ctl.queue)) return;
	g_ctl.inbuf.init(mem);
	g_ctl.reply_default = STDOUT_FILENO;
	g_ctl.reply_fd = STDOUT_FILENO;
	g_ctl.on = true;
	// The first commands wait for the first frame: there is nothing to
	// select or read before it.
	ctl_await_frame();
}

// control_start_piped is control_start for a terminal program whose stdin
// is piped: the reader thread hands over whole lines.
fn void control_start_piped() {
	control_start();
	g_ctl.from_queue = true;
	// On a terminal stdout is the screen, so only --cmd gets replies.
	if (stdin_is_tty()) {
		g_ctl.reply_default = -1;
		g_ctl.reply_fd = -1;
	}
}

// LineAsm puts the bytes of a stream together into lines. A whole line goes
// to the reader thread's queue (to_queue) or, read by the loop itself,
// straight to the lines waiting to be handled.
struct LineAsm @private {
	char[1024] buf;
	sz len;
}

fn void LineAsm.feed(&self, char[] bytes, bool to_queue) {
	foreach (ch : bytes) {
		if (ch == '\n') {
			self.flush(to_queue);
		} else if (self.len < self.buf.len - 1) {
			self.buf[self.len++] = ch;
		}
	}
}

fn void LineAsm.flush(&self, bool to_queue) {
	if (self.len == 0) return;
	self.buf[self.len++] = '\n';
	String line = (String)self.buf[:self.len];
	self.len = 0;
	if (to_queue) {
		control_feed_line(line);
	} else {
		g_ctl.inbuf.append_string(line);
	}
}

// control_feed_line gives the reader thread's handoff for one command line.
fn void control_feed_line(String line) {
	if (!g_ctl.on) return;
	// The queue is a ring that drops what does not fit, so a script piped in
	// faster than the loop reads it waits here for room. The loop closing its
	// input queue, on the way out, ends the wait.
	while (input_queue_room(&g_ctl.queue) < line.len && !input_queue_is_closed(&g_input_queue)) {
		poll(null, 0, 1);
	}
	input_queue_push(&g_ctl.queue, (char[])line);
	// The loop waits on its own input queue, which gets nothing in this mode.
	input_queue_wake(&g_input_queue);
}

// control_busy reports whether commands are still to be handled, so a loop
// whose stdin has ended does not stop with some unread.
fn bool control_busy() {
	if (!g_ctl.on) return false;
	return g_ctl.waiting || g_ctl.inbuf.len() > 0 || (g_ctl.from_queue && !input_queue_is_empty(&g_ctl.queue));
}

// ctl_await_frame holds the lines after a command that sent input until the
// next frame is drawn.
fn void ctl_await_frame() @local {
	g_ctl.waiting = true;
	g_ctl.wait_frame = g_ctl.frame;
	g_ctl.wait_passes = 0;
}

// ctl_settled says whether the frame a command is waiting for has come. Both
// loops draw in the pass that handles the input, so input that is all handled
// and has drawn nothing a pass later changed nothing, and the wait is over.
fn bool ctl_settled() @local {
	if (!g_ctl.waiting) return true;
	bool drawn = g_ctl.frame != g_ctl.wait_frame;
	bool handled = g_program == null || g_program.send_head == g_program.send_tail;
	if (!drawn && !(handled && ++g_ctl.wait_passes >= 2)) return false;
	g_ctl.waiting = false;
	if (g_ctl.ok_owed) {
		g_ctl.ok_owed = false;
		ctl_ok();
	}
	ctl_reply_end();
	return true;
}

// control_stdin_eof says the command stream has ended.
fn void control_stdin_eof() {
	input_queue_close(&g_ctl.queue);
	g_ctl.stdin_eof = true;
}

// control_poll serves the command stream: new lines, replies. Backends call
// it once a pass of their loop.
fn void control_poll() {
	control_remote_poll();
	if (!g_ctl.started) return;
	if (!g_ctl.on) return;
	if (!ctl_settled()) return;
	@pool() {
		if (g_ctl.from_queue) {
			ctl_drain_queue();
		} else {
			ctl_read_stdin();
		}
	};
}

fn void ctl_drain_queue() @local {
	char[1024] chunk;
	for (;;) {
		sz n = input_queue_drain(&g_ctl.queue, chunk[..]);
		if (n == 0) break;
		g_ctl.inbuf.append_bytes(chunk[:n]);
	}
	ctl_handle_lines();
}

// ctl_read_stdin reads whatever lines arrived on stdin, and on the command
// pipe if there is one, since the last pass.
fn void ctl_read_stdin() @local {
	int pipe_fd = control_pipe_fd();
	while (pipe_fd >= 0) {
		PollFd pfd = { .fd = pipe_fd, .events = POLLIN };
		if (poll(&pfd, 1, 0) <= 0) break;
		char[1024] chunk;
		sz n = read(pipe_fd, &chunk, chunk.len);
		if (n <= 0) break;
		g_ctl.pipe_lines.feed(chunk[:n], false);
	}
	// Lines read before the end of stdin may still be waiting on a frame.
	while (!g_ctl.stdin_eof) {
		PollFd pfd = { .fd = STDIN_FILENO, .events = POLLIN };
		if (poll(&pfd, 1, 0) <= 0) break;
		char[1024] chunk;
		sz n = read(STDIN_FILENO, &chunk, chunk.len);
		if (n == 0) {
			g_ctl.stdin_lines.flush(false);
			g_ctl.stdin_eof = true;
			break;
		}
		if (n < 0) break;
		g_ctl.stdin_lines.feed(chunk[:n], false);
	}
	ctl_handle_lines();
}

// ctl_handle_lines handles the whole lines read so far, up to and including
// one that sends input; the rest wait for the next frame (see ctl_settled).
fn void ctl_handle_lines() @local {
	while (!g_ctl.waiting) {
		String s = g_ctl.inbuf.str_view();
		sz? nl = s.index_of_char('\n');
		if (catch nl) break;
		String line = s[:nl].tcopy();
		g_ctl.inbuf.delete(0, nl + 1);
		// ">PATH<tab>COMMAND" is a command from --cmd, answered on PATH.
		if (line.len > 0 && line[0] == '>') {
			sz? tab = line.index_of_char('\t');
			if (catch tab) continue;
			g_ctl.reply_fd = control_reply_open(line[1:tab - 1]);
			g_ctl.reply_piped = true;
			line = line[tab + 1..];
		}
		if (line.trim().len > 0) ctl_handle(line);
		if (!g_ctl.waiting) ctl_reply_end();
	}
}

// ── Replies ────────────────────────────────────────────────────────────────

// ctl_line writes one reply line to stdout in a single write, so the lines
// of two writers at once cannot interleave mid-line.
fn void ctl_line_to(int fd, String s) @local {
	if (fd < 0) return;
	@pool() {
		DString out = dstring::temp();
		out.append_string(s);
		out.append_char('\n');
		control_write(fd, out.str_view());
	};
}

fn void ctl_line(String s) @local => ctl_line_to(g_ctl.reply_fd, s);

// ctl_last_line is the line a reply ends with, marked as such for --cmd.
fn void ctl_last_line(String s) @local {
	ctl_line(g_ctl.reply_piped ? string::tformat("%c%s", REPLY_END, s) : s);
}

// ctl_ok ends a reply. After a command that sent input it waits for the
// frame that input draws, so "ok" means the screen shows what was done.
fn void ctl_ok() @local {
	if (g_ctl.waiting) {
		g_ctl.ok_owed = true;
		return;
	}
	ctl_last_line("ok");
}

fn void ctl_err(String message) @local => ctl_last_line(string::tformat("err %s", message));

// ctl_reply_end closes the pipe a --cmd reply went to; later replies go
// where they usually do.
fn void ctl_reply_end() @local {
	if (!g_ctl.reply_piped) return;
	if (g_ctl.reply_fd >= 0) control_reply_close(g_ctl.reply_fd);
	g_ctl.reply_fd = g_ctl.reply_default;
	g_ctl.reply_piped = false;
}

// ctl_quote appends s as a double-quoted string, escapes intact.
fn void ctl_quote(DString* out, String s) @local {
	out.append_char('"');
	foreach (ch : s) {
		switch (ch) {
			case '"': out.append_string("\\\"");
			case '\\': out.append_string("\\\\");
			case '\n': out.append_string("\\n");
			case '\r': out.append_string("\\r");
			case '\t': out.append_string("\\t");
			default: out.append_char(ch);
		}
	}
	out.append_char('"');
}

// ── Requests ───────────────────────────────────────────────────────────────

// ctl_tokens splits a line into words. A "..." group is one word and a
// backslash quotes the next character, so a selector holding a space travels
// as one word. Returns how many words, at most the array holds.
fn sz ctl_tokens(String s, String[] out) @local {
	sz n = 0;
	sz i = 0;
	while (i < s.len) {
		while (i < s.len && s[i] == ' ') i++;
		if (i >= s.len) break;
		if (s[i] == '"') {
			i++;
			DString v = dstring::temp();
			while (i < s.len && s[i] != '"') {
				if (s[i] == '\\' && i + 1 < s.len) i++;
				v.append_char(s[i]);
				i++;
			}
			if (i < s.len) i++;
			if (n < out.len) out[n++] = v.str_view();
			continue;
		}
		sz start = i;
		// A key shortcut may hold a quoted name with spaces: $"New file", or
		// button$"New file".
		char quote = 0;
		while (i < s.len && (quote != 0 || s[i] != ' ')) {
			if (s[i] == '\\' && i + 1 < s.len) {
				i++;
			} else if (quote != 0) {
				if (s[i] == quote) quote = 0;
			} else if (i > start && s[i - 1] == '$' && (s[i] == '"' || s[i] == '\'')) {
				quote = s[i];
			}
			i++;
		}
		if (n < out.len) out[n++] = s[start:i - start];
	}
	return n;
}

fn void ctl_handle(String line) @local {
	String[8] toks;
	sz n = ctl_tokens(line, toks[..]);
	if (n == 0) return;
	String cmd = toks[0];
	switch (cmd) {
		case "ping": ctl_ok();
		case "tree": ctl_tree(toks[..], n);
		case "list": ctl_list(toks[..], n);
		case "match": ctl_match(toks[..], n);
		case "click":
		case "press":
		case "release":
		case "move": ctl_pointer(toks[..], n, cmd);
		case "drag": ctl_drag(toks[..], n);
		case "scroll": ctl_scroll(toks[..], n);
		case "key": ctl_key(toks[..], n);
		case "type": ctl_type(line, toks[..], n);
		case "select": ctl_select_text(toks[..], n);
		case "screen": ctl_screen(toks[..], n);
		case "stream": ctl_stream();
		case "quit": ctl_quit();
		default: ctl_err(string::tformat("unknown command \"%s\"", cmd));
	}
}

fn void ctl_stream() @local {
	g_ctl.stream = !g_ctl.stream;
	ctl_line(g_ctl.stream ? "stream on" : "stream off");
	ctl_ok();
}

fn void ctl_quit() @local {
	if (g_program != null) g_program.send({ .kind = MsgKind.QUIT });
	ctl_ok();
}

// ── Snapshot ───────────────────────────────────────────────────────────────

fn CtlSpan ctl_span(String s) @local {
	CtlSpan sp = { .at = g_ctl.strs_at, .len = s.len };
	g_ctl.strs[sp.at:sp.len] = s[..];
	g_ctl.strs_at += s.len;
	return sp;
}

fn String ctl_str(CtlSpan sp) @local => sp.len == 0 ? "" : (String)g_ctl.strs[sp.at:sp.len];

// ctl_count and ctl_span_len walk the tree the snapshot's record does, so the
// arrays come out exact: the frame's tree is freed after drawing, but these
// two passes happen while it is still alive.
fn sz ctl_count(xray::Node* n) @local {
	if (n == null || n.alpha_value == 0) return 0;
	sz c = 1;
	for (sz i = 0; i < n.child_count; i++) c += ctl_count(n.children[i]);
	return c;
}

fn sz ctl_span_len(xray::Node* n) @local {
	if (n == null || n.alpha_value == 0) return 0;
	sz c = n.id_str.len + n.key_str.len + n.type_name.len;
	for (sz i = 0; i < n.child_count; i++) c += ctl_span_len(n.children[i]);
	return c;
}

// control_on_draw records the frame just drawn, for selectors. draw() calls it.
fn void control_on_draw(xray::Node* root, xray::ScreenBuffer* buf, sz repaint_ms) {
	if (!g_ctl.started) return;
	if (!g_ctl.on) return;
	if (g_ctl.nodes.ptr != null) mem::free(g_ctl.nodes.ptr);
	if (g_ctl.strs.ptr != null) mem::free(g_ctl.strs.ptr);
	sz ncount = ctl_count(root);
	sz slen = ctl_span_len(root);
	g_ctl.nodes = mem::new_array(CtlNode, ncount);
	g_ctl.strs = mem::new_array(char, slen);
	g_ctl.strs_at = 0;
	g_ctl.buf = buf;
	g_ctl.metrics = root.layout_metrics;
	g_ctl.repaint_ms = repaint_ms;
	g_ctl.frame++;
	sz z = 0;
	ctl_record(root, -1, &z);
}

fn void ctl_record(xray::Node* n, sz parent, sz* ni) @local {
	if (n == null || n.alpha_value == 0) return;
	CtlNode cn = {
		.parent = parent,
		.id = ctl_span(n.id_str),
		.key = ctl_span(n.key_str),
		.type = ctl_span(n.type_name),
		.role = n.role_value,
		.rect = n.computed_rect,
		.inner = n.content_layout_rect(),
		.clickable = n.on_click_fn != null,
		.interactive = n.on_click_fn != null || n.on_drag_fn != null || n.on_hover_in_fn != null
			|| n.on_hover_out_fn != null,
		.focusable = n.can_focus,
		.focused = n.has_keyboard_focus(),
		.child_count = n.child_count,
	};
	sz me = *ni;
	g_ctl.nodes[(*ni)++] = cn;
	for (sz i = 0; i < n.child_count; i++) ctl_record(n.children[i], me, ni);
}

fn sz ctl_uw() @local => g_ctl.metrics.unit_w();
fn sz ctl_uh() @local => g_ctl.metrics.unit_h();

// ctl_cells is a rect in layout units as the cells its content is drawn on.
fn xray::Rect ctl_cells(xray::Rect r) @local {
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	return {
		.x = xray::floor_cell(r.x, uw), .y = xray::floor_cell(r.y, uh),
		.w = (r.w + uw - 1) / uw, .h = (r.h + uh - 1) / uh,
	};
}

// ctl_text is what the last frame shows in a node's rect, each row trimmed
// at the end, blank rows at the end left out.
fn String ctl_text(sz i) @local {
	xray::ScreenBuffer* b = g_ctl.buf;
	if (b == null) return "";
	xray::Rect r = ctl_cells(g_ctl.nodes[i].rect);
	DString out = dstring::temp();
	sz keep = 0;
	for (sz y = r.y; y < r.y + r.h; y++) {
		if (y < 0 || y >= b.height) continue;
		if (y > r.y) out.append_char('\n');
		for (sz x = r.x; x < r.x + r.w; x++) {
			if (x < 0 || x >= b.width) continue;
			xray::Cell* cell = &b.cells[y * b.width + x];
			if (cell.content_len == 0) continue;
			out.append_string((String)cell.content[:cell.content_len]);
		}
		while (out.len() > 0 && out.str_view()[out.len() - 1] == ' ') out.delete(out.len() - 1, 1);
		if (out.len() > 0 && out.str_view()[out.len() - 1] != '\n') keep = out.len();
	}
	return out.str_view()[:keep];
}

// The names roles go by, in xray::Role's order.
const String[*] ROLE_NAMES @private = {
	"", "group", "button", "link", "checkbox", "text", "text-field", "list", "list-item",
	"menu-bar", "menu", "menu-item", "dialog", "tab", "scrollbar", "status", "image",
};

fn String role_name(xray::Role r) => ROLE_NAMES[(int)r];

// ── Selectors ──────────────────────────────────────────────────────────────

enum CtlOp : char @local {
	EQUALS,
	CONTAINS,
	STARTS,
}

struct CtlAttr @local {
	String name;
	CtlOp op;
	String value;
}

struct CtlCompound @local {
	String word;
	CtlAttr[8] attrs;
	sz attrs_len;
	bool focused;
	bool clickable;
	sz nth;
}

const sz CTL_MAX_COMPOUNDS @local = 8;

faultdef CTL_BAD_SELECTOR;

fn bool sel_word_char(char ch) @local {
	return ch.is_alnum() || ch == '_' || ch == '-' || ch == '.' || ch == '*';
}

// An attribute's name stops at the * of "*=".
fn bool sel_attr_char(char ch) @local => ch.is_alnum() || ch == '_' || ch == '-';

// ctl_parse_sel turns a selector into its compounds, outermost first.
fn bool ctl_parse_sel(String s, CtlCompound* cs, sz cap, sz* count) @local {
	*count = 0;
	sz i = 0;
	while (i < s.len) {
		while (i < s.len && s[i] == ' ') i++;
		if (i >= s.len) break;
		CtlCompound c = { .nth = -1 };
		sz start = i;
		// A word may be followed by $name, or be only that: button$OK is
		// button[key="OK"], and $OK is any node with that key.
		if (s[i] == '$') {
			c.word = "*";
		} else {
			while (i < s.len && sel_word_char(s[i])) i++;
			c.word = i > start ? s[start:i - start] : "*";
		}
		if (i < s.len && s[i] == '$') {
			// $"a name" in quotes holds spaces; a bare name ends at a space or
			// a :state.
			i++;
			DString kv = dstring::temp();
			if (i < s.len && (s[i] == '"' || s[i] == '\'')) {
				char kq = s[i];
				i++;
				while (i < s.len && s[i] != kq) {
					if (s[i] == '\\' && i + 1 < s.len) i++;
					kv.append_char(s[i]);
					i++;
				}
				if (i >= s.len) return false;
				i++;
			} else {
				while (i < s.len && s[i] != ' ' && s[i] != ':') {
					kv.append_char(s[i]);
					i++;
				}
			}
			if (kv.len() == 0) return false;
			c.attrs[c.attrs_len++] = { .name = "key", .op = EQUALS, .value = kv.str_view() };
		}
		while (i < s.len && (s[i] == '[' || s[i] == ':')) {
			if (s[i] == '[') {
				i++;
				sz ns = i;
				while (i < s.len && sel_attr_char(s[i])) i++;
				CtlAttr a = { .name = s[ns:i - ns] };
				if (i + 1 < s.len && s[i] == '*' && s[i + 1] == '=') {
					a.op = CONTAINS;
					i += 2;
				} else if (i + 1 < s.len && s[i] == '^' && s[i + 1] == '=') {
					a.op = STARTS;
					i += 2;
				} else if (i < s.len && s[i] == '=') {
					a.op = EQUALS;
					i++;
				} else {
					return false;
				}
				// A value is quoted, with either quote so a selector that
				// travels in double quotes can use single ones inside, or bare,
				// running to the closing ]: a shell or xargs in between may
				// strip the quotes.
				DString v = dstring::temp();
				if (i < s.len && (s[i] == '"' || s[i] == '\'')) {
					char quote = s[i];
					i++;
					while (i < s.len && s[i] != quote) {
						if (s[i] == '\\' && i + 1 < s.len) i++;
						v.append_char(s[i]);
						i++;
					}
					if (i + 1 >= s.len || s[i + 1] != ']') return false;
					i += 2;
				} else {
					while (i < s.len && s[i] != ']') {
						v.append_char(s[i]);
						i++;
					}
					if (i >= s.len) return false;
					i++;
				}
				a.value = v.str_view();
				if (c.attrs_len < c.attrs.len) c.attrs[c.attrs_len++] = a;
			} else {
				i++;
				sz ns = i;
				while (i < s.len && sel_word_char(s[i])) i++;
				String p = s[ns:i - ns];
				switch (p) {
					case "focused": c.focused = true;
					case "clickable": c.clickable = true;
					case "nth":
						if (i >= s.len || s[i] != '(') return false;
						i++;
						sz ds = i;
						while (i < s.len && s[i].is_digit()) i++;
						if (i >= s.len || s[i] != ')' || i == ds) return false;
						c.nth = ctl_int(s[ds:i - ds]);
						i++;
					default: return false;
				}
			}
		}
		if (i < s.len && s[i] != ' ') return false;
		if (*count < cap) cs[(*count)++] = c;
	}
	return *count > 0;
}

fn bool sel_value(String have, CtlOp op, String want) @local {
	switch (op) {
		case EQUALS: return have == want;
		case CONTAINS: return have.contains(want);
		case STARTS: return have.starts_with(want);
	}
}

fn bool sel_compound(sz i, CtlCompound* c) @local {
	CtlNode* n = &g_ctl.nodes[i];
	if (c.word != "*") {
		if (ctl_str(n.id) != c.word && role_name(n.role) != c.word && ctl_str(n.type) != c.word) return false;
	}
	if (c.focused && !n.focused) return false;
	if (c.clickable && !n.clickable) return false;
	for (sz k = 0; k < c.attrs_len; k++) {
		CtlAttr* a = &c.attrs[k];
		String have;
		switch (a.name) {
			case "id": have = ctl_str(n.id);
			case "key": have = ctl_str(n.key);
			case "role": have = role_name(n.role);
			case "type": have = ctl_str(n.type);
			case "text": have = ctl_text(i).trim();
			default: return false;
		}
		if (!sel_value(have, a.op, a.value)) return false;
	}
	return true;
}

fn bool sel_matches(sz i, CtlCompound[] cs) @local {
	if (!sel_compound(i, &cs[cs.len - 1])) return false;
	sz k = (sz)cs.len - 2;
	sz p = g_ctl.nodes[i].parent;
	while (k >= 0 && p >= 0) {
		if (sel_compound(p, &cs[k])) k--;
		p = g_ctl.nodes[p].parent;
	}
	return k < 0;
}

// ctl_find is the nth node a selector matches, in paint order: the :nth(n)
// of the selector, else the nth given. NOT_FOUND when there is no such node.
fn sz? ctl_find(String sel, sz nth) @local {
	CtlCompound[CTL_MAX_COMPOUNDS] cs;
	sz count;
	if (!ctl_parse_sel(sel, &cs[0], CTL_MAX_COMPOUNDS, &count)) return CTL_BAD_SELECTOR~;
	sz last_nth = cs[count - 1].nth;
	if (last_nth >= 0) nth = last_nth;
	sz k = 0;
	for (sz i = 0; i < g_ctl.nodes.len; i++) {
		if (sel_matches(i, cs[:count])) {
			if (k == nth) return i;
			k++;
		}
	}
	return NOT_FOUND~;
}

// ── tree / list / match / screen ───────────────────────────────────────────

// ctl_node_line is one node as one line:
// name [key="k"] @x,y WxH :flags "text"
fn void ctl_node_line(sz i, sz indent) @local {
	CtlNode* n = &g_ctl.nodes[i];
	DString out = dstring::temp();
	for (sz k = 0; k < indent; k++) out.append_string("  ");
	if (ctl_str(n.id).len > 0) {
		out.append_string(ctl_str(n.id));
	} else if (n.role != NONE) {
		out.append_string(role_name(n.role));
	} else if (ctl_str(n.type).len > 0) {
		out.append_string(ctl_str(n.type));
	} else {
		out.append_char('*');
	}
	if (ctl_str(n.key).len > 0) {
		out.append_string(" [key=");
		ctl_quote(&out, ctl_str(n.key));
		out.append_char(']');
	}
	xray::Rect r = ctl_cells(n.rect);
	out.appendf(" @%d,%d %dx%d", r.x, r.y, r.w, r.h);
	if (n.clickable) out.append_string(" :clickable");
	if (n.focusable) out.append_string(" :focusable");
	if (n.focused) out.append_string(" :focused");
	if (n.child_count == 0) {
		String text = ctl_text(i).trim();
		if (text.len > 0 && text.len <= 200 && !text.contains("\n")) {
			out.append_char(' ');
			ctl_quote(&out, text);
		}
	}
	ctl_line(out.str_view());
}

fn void ctl_subtree(sz i, sz indent) @local {
	ctl_node_line(i, indent);
	for (sz j = i + 1; j < g_ctl.nodes.len; j++) {
		if (g_ctl.nodes[j].parent != i) continue;
		ctl_subtree(j, indent + 1);
	}
}

fn void ctl_tree(String[] toks, sz n) @local {
	if (g_ctl.nodes.len == 0) {
		ctl_err("nothing drawn yet");
		return;
	}
	if (n >= 2) {
		CtlCompound[CTL_MAX_COMPOUNDS] cs;
		sz count;
		if (!ctl_parse_sel(toks[1], &cs[0], CTL_MAX_COMPOUNDS, &count)) {
			ctl_err(string::tformat("bad selector: %s", toks[1]));
			return;
		}
		bool found = false;
		sz nth = cs[count - 1].nth;
		sz k = 0;
		for (sz i = 0; i < g_ctl.nodes.len; i++) {
			if (!sel_matches(i, cs[:count])) continue;
			if (nth >= 0 && k++ != nth) continue;
			found = true;
			ctl_subtree(i, 0);
		}
		if (!found) {
			ctl_err(string::tformat("no node matches %s", toks[1]));
			return;
		}
	} else {
		ctl_subtree(0, 0);
	}
	ctl_ok();
}

fn void ctl_list(String[] toks, sz n) @local {
	if (n < 2) {
		ctl_err("list needs a selector");
		return;
	}
	CtlCompound[CTL_MAX_COMPOUNDS] cs;
	sz count;
	if (!ctl_parse_sel(toks[1], &cs[0], CTL_MAX_COMPOUNDS, &count)) {
		ctl_err(string::tformat("bad selector: %s", toks[1]));
		return;
	}
	sz nth = cs[count - 1].nth;
	sz k = 0;
	for (sz i = 0; i < g_ctl.nodes.len; i++) {
		if (!sel_matches(i, cs[:count])) continue;
		if (nth >= 0 && k++ != nth) continue;
		ctl_node_line(i, 0);
	}
	ctl_ok();
}

fn void ctl_match(String[] toks, sz n) @local {
	if (n < 2) {
		ctl_err("match needs a pattern");
		return;
	}
	sz start;
	sz end;
	for (sz i = 0; i < g_ctl.nodes.len; i++) {
		// Trimmed, as a selector's text is, so ^ and $ mean the text's ends.
		String text = ctl_text(i).trim();
		if (text.len == 0) continue;
		if (pattern_find(toks[1], text, 0, &start, &end)) ctl_node_line(i, 0);
	}
	ctl_ok();
}

fn void ctl_screen(String[] toks, sz n) @local {
	xray::ScreenBuffer* b = g_ctl.buf;
	if (b == null) {
		ctl_err("nothing drawn yet");
		return;
	}
	String pat = n >= 2 ? toks[1] : "";
	for (sz y = 0; y < b.height; y++) {
		DString row = dstring::temp();
		bool wide = false;
		for (sz x = 0; x < b.width; x++) {
			xray::Cell* cell = &b.cells[y * b.width + x];
			String s = cell.content_len > 0 ? (String)cell.content[:cell.content_len] : (wide ? "" : " ");
			wide = cell.width == 2;
			row.append_string(s);
		}
		String t = row.str_view().trim();
		if (t.len == 0) continue;
		if (pat.len > 0) {
			sz a;
			sz e;
			if (!pattern_find(pat, t, 0, &a, &e)) continue;
		}
		ctl_line(t);
	}
	ctl_ok();
}

// ── Input ──────────────────────────────────────────────────────────────────

// ctl_is_cell says whether a word is a cell, @col,row with each a whole
// number, which a leading - makes the outside of the program, and not a key.
fn bool ctl_is_cell(String tok) @local {
	if (tok.len < 4 || tok[0] != '@') return false;
	sz comma = -1;
	for (sz i = 1; i < tok.len; i++) {
		char ch = tok[i];
		if (ch == ',' && comma < 0 && i > 1) {
			comma = i;
		} else if (!ch.is_digit() && !(ch == '-' && (i == 1 || i == comma + 1))) {
			return false;
		}
	}
	return comma > 1 && comma < tok.len - 1;
}

// ctl_place_err says why a word does not point anywhere: it is not a
// selector, or it is one that matches nothing on screen.
fn void ctl_place_err(String tok) @local {
	CtlCompound[CTL_MAX_COMPOUNDS] cs;
	sz count;
	if (!ctl_parse_sel(tok, &cs[0], CTL_MAX_COMPOUNDS, &count)) {
		ctl_err(string::tformat("bad selector: %s", tok));
		return;
	}
	ctl_err(string::tformat("no node matches %s", tok));
}

// ctl_place_tok works out where a word points, in layout units: a selector's
// first match's middle, else a cell "@col,row" of the screen.
fn bool ctl_place_tok(String tok, sz* x, sz* y) @local {
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	// @col,row is a cell; any other @word is a key, found as a selector.
	if (ctl_is_cell(tok)) {
		sz comma = tok.len;
		for (sz i = 1; i < tok.len; i++) {
			if (tok[i] == ',') {
				comma = i;
				break;
			}
		}
		if (comma == tok.len) return false;
		sz col = ctl_int(tok[1:comma - 1]);
		sz row = ctl_int(tok[comma + 1..]);
		// A negative place is outside the program, where a pointer that left
		// it is.
		if (col < 0 || row < 0) {
			*x = -1;
			*y = -1;
			return true;
		}
		*x = col * uw + uw / 2;
		*y = row * uh + uh / 2;
		return true;
	}
	sz? i = ctl_find(tok, 0);
	if (catch i) return false;
	CtlNode* n = &g_ctl.nodes[i];
	*x = n.rect.x + n.rect.w / 2;
	*y = n.rect.y + n.rect.h / 2;
	return true;
}

fn void ctl_inject(MouseAction action, sz x, sz y) @local {
	if (action == MOUSE_PRESS) g_ctl.pressed = true;
	if (action == MOUSE_RELEASE) g_ctl.pressed = false;
	ctl_await_frame();
	if (g_ctl.hooks.pointer) {
		g_ctl.hooks.pointer(action, x, y);
		return;
	}
	// The terminal: a mouse message, which dispatch() hit-tests.
	if (g_program == null) return;
	MouseMsg m = {
		.action = action,
		.button = action == MOUSE_MOTION && !g_ctl.pressed ? MOUSE_NONE : MOUSE_LEFT,
		.col = xray::floor_cell(x, ctl_uw()),
		.row = xray::floor_cell(y, ctl_uh()),
	};
	g_program.send({ .kind = MsgKind.MOUSE, .mouse = m });
}

fn void ctl_pointer(String[] toks, sz n, String cmd) @local {
	if (n < 2) {
		ctl_err("say where: a selector or @col,row");
		return;
	}
	sz x;
	sz y;
	if (!ctl_place_tok(toks[1], &x, &y)) {
		ctl_place_err(toks[1]);
		return;
	}
	switch (cmd) {
		case "click":
			ctl_inject(MOUSE_MOTION, x, y);
			ctl_inject(MOUSE_PRESS, x, y);
			ctl_inject(MOUSE_RELEASE, x, y);
		case "press": ctl_inject(MOUSE_PRESS, x, y);
		case "release": ctl_inject(MOUSE_RELEASE, x, y);
		default: ctl_inject(MOUSE_MOTION, x, y);
	}
	ctl_ok();
}

fn void ctl_drag(String[] toks, sz n) @local {
	if (n < 3) {
		ctl_err("drag needs a from and a to");
		return;
	}
	sz x0;
	sz y0;
	sz x1;
	sz y1;
	if (!ctl_place_tok(toks[1], &x0, &y0)) {
		ctl_place_err(toks[1]);
		return;
	}
	if (!ctl_place_tok(toks[2], &x1, &y1)) {
		ctl_place_err(toks[2]);
		return;
	}
	ctl_inject(MOUSE_MOTION, x0, y0);
	ctl_inject(MOUSE_PRESS, x0, y0);
	ctl_inject(MOUSE_MOTION, x1, y1);
	ctl_inject(MOUSE_RELEASE, x1, y1);
	ctl_ok();
}

fn void ctl_scroll(String[] toks, sz n) @local {
	sz x = g_ctl.event_x;
	sz y = g_ctl.event_y;
	double dy = 0;
	double dx = 0;
	for (sz k = 1; k < n; k++) {
		String t = toks[k];
		if (t.starts_with("dy=")) {
			dy = ctl_num(t[3..]);
		} else if (t.starts_with("dx=")) {
			dx = ctl_num(t[3..]);
		} else {
			if (!ctl_place_tok(t, &x, &y)) {
				ctl_place_err(t);
				return;
			}
		}
	}
	ctl_await_frame();
	if (g_ctl.hooks.scroll) {
		g_ctl.hooks.scroll(x, y, dx, dy);
	} else if (g_program != null) {
		// The terminal: a wheel notch per row.
		sz col = xray::floor_cell(x, ctl_uw());
		sz row = xray::floor_cell(y, ctl_uh());
		sz count = (sz)(dy < 0 ? -dy : dy);
		for (sz i = 0; i < count; i++) {
			MouseMsg m = { .action = MOUSE_PRESS, .button = dy < 0 ? MOUSE_WHEEL_UP : MOUSE_WHEEL_DOWN,
				.col = col, .row = row };
			g_program.send({ .kind = MsgKind.MOUSE, .mouse = m });
		}
	}
	ctl_ok();
}

// The names keys go by, in KeyCode's order: what key_spec writes and
// parse_key_spec reads. CTRL_C is "c" with ctrl.
const String[*] KEY_NAMES @private = {
	"", "", "enter", "backspace", "esc", "tab", "up", "down", "left", "right", "home", "end",
	"delete", "pageup", "pagedown", "insert", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8",
	"f9", "f10", "f11", "f12", "c",
};

// ctl_ieq: a and b are equal, ASCII letters in either case.
fn bool ctl_ieq(String a, String b) @private {
	if (a.len != b.len) return false;
	for (sz i = 0; i < a.len; i++) {
		char x = a[i];
		char y = b[i];
		if (x >= 'A' && x <= 'Z') x += 32;
		if (y >= 'A' && y <= 'Z') y += 32;
		if (x != y) return false;
	}
	return true;
}

// ctl_int reads a whole number, perhaps with a leading -, or gives def.
fn sz ctl_int(String s, sz def = 0) @private {
	sz i = s.len > 0 && s[0] == '-' ? 1 : 0;
	if (i >= s.len) return def;
	sz v = 0;
	for (; i < s.len; i++) {
		if (!s[i].is_digit()) return def;
		v = v * 10 + (sz)(s[i] - '0');
	}
	return s[0] == '-' ? -v : v;
}

// ctl_num reads a decimal number such as -1.25, or gives 0.
fn double ctl_num(String s) @private {
	sz dot = s.len;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '.') {
			dot = i;
			break;
		}
	}
	bool neg = s.len > 0 && s[0] == '-';
	String whole = s[(neg ? 1 : 0):dot - (neg ? 1 : 0)];
	double v = whole.len > 0 ? (double)ctl_int(whole) : 0;
	double scale = 1;
	for (sz i = dot + 1; i < s.len; i++) {
		if (!s[i].is_digit()) return 0;
		scale /= 10;
		v += (double)(s[i] - '0') * scale;
	}
	return neg ? -v : v;
}

fn KeyMsg? parse_key_spec(String spec) @local {
	KeyMsg k = { .code = RUNE };
	// Modifiers come before the last + that is not the key itself, so
	// "ctrl++" is ctrl and the + key.
	sz cut = -1;
	for (sz i = spec.len - 2; i >= 0; i--) {
		if (spec[i] == '+') {
			cut = i;
			break;
		}
	}
	for (sz at = 0; at < cut;) {
		sz e = at;
		while (e < cut && spec[e] != '+') e++;
		String m = spec[at:e - at];
		if (ctl_ieq(m, "ctrl")) {
			k.ctrl = true;
		} else if (ctl_ieq(m, "alt") || ctl_ieq(m, "opt") || ctl_ieq(m, "option")) {
			k.alt = true;
		} else if (ctl_ieq(m, "shift")) {
			k.shift = true;
		} else if (ctl_ieq(m, "cmd") || ctl_ieq(m, "super")) {
			k.super = true;
		} else {
			return NOT_FOUND~;
		}
		at = e + 1;
	}
	String name = spec[cut + 1..];
	if (name.len == 0) return NOT_FOUND~;
	if (ctl_ieq(name, "return")) name = "enter";
	if (ctl_ieq(name, "escape")) name = "esc";
	if (ctl_ieq(name, "space")) name = " ";
	if (name.len > 1) {
		for (int c = (int)KeyCode.ENTER; c < (int)KeyCode.CTRL_C; c++) {
			if (ctl_ieq(name, KEY_NAMES[c])) {
				k.code = (KeyCode)c;
				return k;
			}
		}
	}
	uint r;
	if (utf8::decode(name, &r) != name.len) return NOT_FOUND~;
	if (k.ctrl && r >= 'A' && r <= 'Z') r += 32;
	k.rune = r;
	if (k.ctrl && r == 'c' && !k.alt && !k.shift && !k.super) {
		k.code = CTRL_C;
		k.rune = 0;
	}
	return k;
}

fn void ctl_key(String[] toks, sz n) @local {
	if (n < 2) {
		ctl_err("key needs a spec");
		return;
	}
	KeyMsg? k = parse_key_spec(toks[1]);
	if (catch k) {
		ctl_err(string::tformat("unknown key \"%s\"", toks[1]));
		return;
	}
	ctl_await_frame();
	if (g_program != null) g_program.send({ .kind = MsgKind.KEY, .key = k });
	ctl_ok();
}

fn void ctl_type(String line, String[] toks, sz n) @local {
	if (n < 2) {
		ctl_err("type needs text");
		return;
	}
	// Everything after the command word, as keys, spaces and all. A line that
	// is one quoted word, `type "a b"`, is that word without its quotes.
	sz at = 0;
	while (at < line.len && line[at] == ' ') at++;
	at += toks[0].len;
	while (at < line.len && line[at] == ' ') at++;
	String text = n == 2 && line[at] == '"' ? toks[1] : line[at..];
	ctl_await_frame();
	for (sz i = 0; g_program != null && i < text.len;) {
		uint r;
		i += utf8::decode(text[i..], &r);
		KeyMsg k = r == '\n' ? (KeyMsg){ .code = ENTER } : (KeyMsg){ .code = RUNE, .rune = r };
		g_program.send({ .kind = MsgKind.KEY, .key = k });
	}
	ctl_ok();
}

// ── select ─────────────────────────────────────────────────────────────────

// CtlScreenText is what a node shows on screen as one string, a row to a
// line, with the cell each byte was drawn in.
struct CtlScreenText @local {
	String text;
	sz[] col;
	sz[] row;
}

// ctl_screen_text reads node i's cells into a CtlScreenText, on tmem. A blank
// cell reads as a space, so text with spaces in it still matches, and the
// right half of a wide character is passed over. A first pass counts so the
// arrays are exact, and the byte each cell was drawn in travels beside it.
fn CtlScreenText ctl_screen_text(sz i) @local {
	CtlScreenText st;
	xray::ScreenBuffer* b = g_ctl.buf;
	if (b == null) return st;
	xray::Rect r = ctl_cells(g_ctl.nodes[i].rect);
	sz bytes = 0;
	sz cells = 0;
	sz rows = 0;
	for (sz y = math::max(r.y, (sz)0); y < r.y + r.h && y < b.height; y++) {
		if (rows > 0) {
			bytes++;
			cells++;
		}
		bool wide = false;
		for (sz x = math::max(r.x, (sz)0); x < r.x + r.w && x < b.width; x++) {
			xray::Cell* cell = &b.cells[y * b.width + x];
			sz l = cell.content_len > 0 ? cell.content_len : (wide ? 0 : 1);
			wide = cell.width == 2;
			bytes += l;
			cells += l;
		}
		rows++;
	}
	DString out = dstring::temp();
	sz[] col = mem::talloc_array(sz, cells);
	sz[] row = mem::talloc_array(sz, cells);
	sz ci = 0;
	rows = 0;
	for (sz y = math::max(r.y, (sz)0); y < r.y + r.h && y < b.height; y++) {
		if (rows > 0) {
			out.append_char('\n');
			col[ci] = r.x + r.w;
			row[ci] = y - 1;
			ci++;
		}
		bool wide = false;
		for (sz x = math::max(r.x, (sz)0); x < r.x + r.w && x < b.width; x++) {
			xray::Cell* cell = &b.cells[y * b.width + x];
			String s2 = cell.content_len > 0 ? (String)cell.content[:cell.content_len] : (wide ? "" : " ");
			wide = cell.width == 2;
			out.append_string(s2);
			for (sz k = 0; k < s2.len; k++) {
				col[ci] = x;
				row[ci] = y;
				ci++;
			}
		}
		rows++;
	}
	st.text = out.str_view();
	st.col = col;
	st.row = row;
	return st;
}

// ctl_occurrence finds where the nth occurrence of needle starts in hay,
// counting overlapping ones, from 0.
fn sz? ctl_occurrence(String hay, String needle, sz nth) @local {
	if (needle.len == 0) return NOT_FOUND~;
	sz k = 0;
	for (sz at = 0; at + needle.len <= hay.len; at++) {
		if (hay[at:needle.len] != needle) continue;
		if (k++ == nth) return at;
	}
	return NOT_FOUND~;
}

// ctl_select_text selects text the way a person would: it finds the text in
// what the target shows and drags from the cell the text starts in to the
// cell after it ends. Only what is on screen can be found; scroll first for
// the rest.
fn void ctl_select_text(String[] toks, sz n) @local {
	if (n < 3) {
		ctl_err("select needs a target and the text (or /pattern/)");
		return;
	}
	sz? t = ctl_find(toks[1], 0);
	if (catch t) {
		ctl_place_err(toks[1]);
		return;
	}
	CtlScreenText st = ctl_screen_text(t);
	sz nth = n >= 4 ? ctl_int(toks[3]) : 0;
	sz start;
	sz end;
	String what = toks[2];
	if (what.len >= 2 && what.starts_with("/") && what.ends_with("/")) {
		String pat = what[1:what.len - 2];
		if (!pattern_find(pat, st.text, nth, &start, &end)) {
			ctl_err("no match on screen");
			return;
		}
	} else {
		sz? at = ctl_occurrence(st.text, what, nth);
		if (catch at) {
			ctl_err("no such text on screen");
			return;
		}
		start = at;
		end = at + what.len;
	}
	if (end <= start) {
		ctl_err("nothing to select");
		return;
	}
	// From the first byte's cell to just past the last byte's: the next
	// cell along, or the end of a wide character.
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	sz last = end - 1;
	sz end_col = st.col[last] + 1;
	if (last + 1 < st.col.len && st.row[last + 1] == st.row[last] && st.col[last + 1] > end_col) {
		end_col = st.col[last + 1];
	}
	sz x0 = st.col[start] * uw + uw / 2;
	sz y0 = st.row[start] * uh + uh / 2;
	sz x1 = end_col * uw + uw / 2;
	sz y1 = st.row[last] * uh + uh / 2;
	ctl_inject(MOUSE_MOTION, x0, y0);
	ctl_inject(MOUSE_PRESS, x0, y0);
	ctl_inject(MOUSE_MOTION, x1, y1);
	ctl_inject(MOUSE_RELEASE, x1, y1);
	ctl_line(string::tformat("selected %s", st.text[start:end - start]));
	ctl_ok();
}

// ── Events ─────────────────────────────────────────────────────────────────

// control_pointer_event tells streamers about pointer input: "press",
// "release" or "move", at (x, y) in layout units, (-2, -2) for where it last
// was. dispatch_click, end_drag and dispatch_hover call it, which both
// backends go through.
fn void control_pointer_event(String type, sz x, sz y) {
	if (!g_ctl.on) return;
	// A release comes with no place of its own: it is where the pointer was.
	if (x == -2) {
		x = g_ctl.event_x;
		y = g_ctl.event_y;
	} else if (x < 0 || y < 0) {
		// Outside the window, however the backend says so.
		x = -1;
		y = -1;
	}
	// Where the pointer is is kept whether or not anyone streams: a scroll
	// that names no place happens there.
	bool moved = x != g_ctl.event_x || y != g_ctl.event_y;
	g_ctl.event_x = x;
	g_ctl.event_y = y;
	if (!g_ctl.stream) return;
	if (type == "move" && !moved) return;
	@pool() {
		DString out = dstring::temp();
		out.append_string(type);
		out.appendf(" @%d,%d", xray::floor_cell(x, ctl_uw()), xray::floor_cell(y, ctl_uh()));
		ctl_line_to(g_ctl.reply_default, out.str_view());
	};
}

// control_msg_event tells streamers about the input that arrives as a
// message: keys, and the wheel. Both backends' dispatch call it.
fn void control_msg_event(Msg m) {
	if (!g_ctl.on || !g_ctl.stream) return;
	@pool() {
		DString out = dstring::temp();
		if (m.kind == MsgKind.KEY && m.key.action != KeyAction.KEY_RELEASE) {
			out.append_string("key ");
			out.append_string(key_spec(m.key));
			ctl_line_to(g_ctl.reply_default, out.str_view());
			return;
		}
		if (m.kind != MsgKind.MOUSE || m.mouse.action != MOUSE_PRESS) return;
		int notch = m.mouse.button == MOUSE_WHEEL_DOWN ? 1 : m.mouse.button == MOUSE_WHEEL_UP ? -1 : 0;
		if (notch == 0) return;
		double dy = notch;
		double dx = 0;
		if (m.mouse.scroll_dy != 0 || m.mouse.scroll_dx != 0) {
			dy = -(double)m.mouse.scroll_dy / (double)ctl_uh();
			dx = -(double)m.mouse.scroll_dx / (double)ctl_uw();
		}
		sz cx = g_ctl.event_x;
		sz cy = g_ctl.event_y;
		if (!g_ctl.hooks.pointer) {
			cx = m.mouse.col;
			cy = m.mouse.row;
		}
		out.appendf("scroll @%d,%d dy=%.2f", xray::floor_cell(cx, ctl_uw()), xray::floor_cell(cy, ctl_uh()), dy);
		if (dx != 0) out.appendf(" dx=%.2f", dx);
		ctl_line_to(g_ctl.reply_default, out.str_view());
	};
}

// key_spec writes a key the way parse_key_spec reads it.
fn String key_spec(KeyMsg k) @local {
	DString s = dstring::temp();
	if (k.ctrl || k.code == CTRL_C) s.append_string("ctrl+");
	if (k.alt) s.append_string("alt+");
	if (k.shift) s.append_string("shift+");
	if (k.super) s.append_string("cmd+");
	if (k.code != RUNE && k.code != NONE) {
		s.append_string(KEY_NAMES[(int)k.code]);
	} else if (k.rune == ' ') {
		s.append_string("space");
	} else {
		char[4] b;
		s.append_string((String)b[:utf8::encode(k.rune, b[..])]);
	}
	return s.str_view();
}
