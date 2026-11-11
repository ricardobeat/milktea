module milktea;

import xray;
import std::core::dstring;
import std::core::string;
import std::math;

// Control drives a running program from the command line. When the program's
// stdin is not a terminal, each line of stdin is a command and each reply a
// line on stdout. A GUI's stdin is never keys, so it takes commands even
// headed; a terminal program takes them whenever its stdin is piped.
//
//   tree [SEL]            the tree, from the root or each match's subtree
//   list SEL              the nodes a selector matches, one a line
//   match PATTERN         nodes whose on-screen text matches the pattern
//   click SEL | @c,r      move there, press and release
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
// A command answers with its output, then "ok"; a failure answers one line
// "err ...". A node is picked by selector, matched against the last drawn
// frame:
//
//   word          a node whose id, role (button, list-item, ...) or content
//                 type (View) is word; * is any node
//   [key="v"]     its key, id, role, type or on-screen text: = is equal,
//                 *= contains, ^= starts with
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
	DString inbuf;
	InputQueue queue;
	bool stream;
	ControlHooks hooks;
	bool pressed;
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

// control_active reports whether the command stream is open, so a loop that
// would sleep for long wakes often enough to serve it.
fn bool control_active() => g_ctl.on;

// control_start turns the command stream on: stdin is commands, stdout
// replies. The GUI calls it, and a terminal program whose stdin is piped.
fn void control_start() {
	if (g_ctl.started) return;
	g_ctl.started = true;
	if (catch input_queue_init(&g_ctl.queue)) return;
	g_ctl.inbuf.init(mem);
	g_ctl.on = true;
}

// control_start_piped is control_start for a terminal program whose stdin
// is piped: the reader thread hands over whole lines.
fn void control_start_piped() {
	control_start();
	g_ctl.from_queue = true;
}

// control_feed_line gives the reader thread's handoff for one command line.
fn void control_feed_line(String line) {
	if (g_ctl.on) input_queue_push(&g_ctl.queue, (char[])line);
}

// control_stdin_eof says the command stream has ended.
fn void control_stdin_eof() {
	input_queue_close(&g_ctl.queue);
	g_ctl.stdin_eof = true;
}

// control_poll serves the command stream: new lines, replies. Backends call
// it once a pass of their loop.
fn void control_poll() {
	if (!g_ctl.started) return;
	if (!g_ctl.on) return;
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

// ctl_read_stdin reads whatever lines arrived on stdin since the last pass.
// A GUI's stdin sits in canonical mode, so a line arrives whole after Enter.
fn void ctl_read_stdin() @local {
	if (g_ctl.stdin_eof) return;
	for (;;) {
		PollFd pfd = { .fd = STDIN_FILENO, .events = POLLIN };
		if (poll(&pfd, 1, 0) <= 0) break;
		char[1024] chunk;
		sz n = read(STDIN_FILENO, &chunk, chunk.len);
		if (n == 0) {
			g_ctl.stdin_eof = true;
			break;
		}
		if (n < 0) break;
		g_ctl.inbuf.append_bytes(chunk[:n]);
	}
	ctl_handle_lines();
}

fn void ctl_handle_lines() @local {
	for (;;) {
		String s = g_ctl.inbuf.str_view();
		sz? nl = s.index_of_char('\n');
		if (catch nl) break;
		String line = s[:nl].tcopy();
		g_ctl.inbuf.delete(0, nl + 1);
		if (line.trim().len > 0) ctl_handle(line);
	}
}

// ── Replies ────────────────────────────────────────────────────────────────

// ctl_line writes one reply line to stdout in a single write, so the lines
// of two writers at once cannot interleave mid-line.
fn void ctl_line(String s) @local {
	@pool() {
		DString out = dstring::temp();
		out.append_string(s);
		out.append_char('\n');
		String v = out.str_view();
		(void)write(1, v.ptr, v.len);
	};
}

fn void ctl_ok() @local => ctl_line("ok");

fn void ctl_err(String message) @local => ctl_line(string::tformat("err %s", message));

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
		while (i < s.len && s[i] != ' ') {
			if (s[i] == '\\' && i + 1 < s.len) i++;
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

fn String role_name(xray::Role r) {
	switch (r) {
		case NONE: return "";
		case GROUP: return "group";
		case BUTTON: return "button";
		case LINK: return "link";
		case CHECKBOX: return "checkbox";
		case TEXT: return "text";
		case TEXT_FIELD: return "text-field";
		case LIST: return "list";
		case LIST_ITEM: return "list-item";
		case MENU_BAR: return "menu-bar";
		case MENU: return "menu";
		case MENU_ITEM: return "menu-item";
		case DIALOG: return "dialog";
		case TAB: return "tab";
		case SCROLLBAR: return "scrollbar";
		case STATUS: return "status";
		case IMAGE: return "image";
	}
}

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

// ctl_parse_sel turns a selector into its compounds, outermost first.
fn bool ctl_parse_sel(String s, CtlCompound* cs, sz cap, sz* count) @local {
	*count = 0;
	sz i = 0;
	while (i < s.len) {
		while (i < s.len && s[i] == ' ') i++;
		if (i >= s.len) break;
		CtlCompound c = { .nth = -1 };
		sz start = i;
		while (i < s.len && sel_word_char(s[i])) i++;
		c.word = i > start ? s[start:i - start] : "*";
		while (i < s.len && (s[i] == '[' || s[i] == ':')) {
			if (s[i] == '[') {
				i++;
				sz ns = i;
				while (i < s.len && sel_word_char(s[i])) i++;
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
				if (i >= s.len || s[i] != '"') return false;
				i++;
				DString v = dstring::temp();
				while (i < s.len && s[i] != '"') {
					if (s[i] == '\\' && i + 1 < s.len) i++;
					v.append_char(s[i]);
					i++;
				}
				if (i + 1 >= s.len || s[i + 1] != ']') return false;
				i += 2;
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
						c.nth = (sz)(s[ds:i - ds].to_int() ?? 0);
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
// of the selector, else the nth given. -1 when there is no such node.
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
	return -1;
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
		for (sz i = 0; i < g_ctl.nodes.len; i++) {
			if (!sel_matches(i, cs[:count])) continue;
			found = true;
			ctl_subtree(i, 0);
		}
		if (!found) {
			ctl_err(string::tformat("nothing matches %s", toks[1]));
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
	for (sz i = 0; i < g_ctl.nodes.len; i++) {
		if (sel_matches(i, cs[:count])) ctl_node_line(i, 0);
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
		String text = ctl_text(i);
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

// ctl_place_tok works out where a word points, in layout units: a selector's
// first match's middle, else a cell "@col,row" of the screen.
fn bool ctl_place_tok(String tok, sz* x, sz* y) @local {
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	if (tok.len > 0 && tok[0] == '@') {
		sz comma = tok.len;
		for (sz i = 1; i < tok.len; i++) {
			if (tok[i] == ',') {
				comma = i;
				break;
			}
		}
		if (comma == tok.len) return false;
		sz col = (sz)(tok[1:comma - 1].to_int() ?? 0);
		sz row = (sz)(tok[comma + 1..].to_int() ?? 0);
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
		ctl_err(string::tformat("bad place: %s", toks[1]));
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
	if (!ctl_place_tok(toks[1], &x0, &y0) || !ctl_place_tok(toks[2], &x1, &y1)) {
		ctl_err("bad place in drag");
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
			dy = t[3..].to_double() ?? 0;
		} else if (t.starts_with("dx=")) {
			dx = t[3..].to_double() ?? 0;
		} else {
			if (!ctl_place_tok(t, &x, &y)) {
				ctl_err(string::tformat("bad place: %s", t));
				return;
			}
		}
	}
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

fn KeyMsg? parse_key_spec(String spec) @local {
	KeyMsg k = { .code = RUNE };
	String[] parts = spec.tsplit("+");
	if (parts.len == 0) return NOT_FOUND~;
	String name = parts[^1];
	sz mods = parts.len - 1;
	if (spec.len > 1 && spec.ends_with("++")) {
		name = "+";
		mods = parts.len - 2;
	} else if (spec == "+") {
		name = "+";
		mods = 0;
	}
	for (sz i = 0; i < mods; i++) {
		switch (parts[i].to_lower_tcopy()) {
			case "ctrl": k.ctrl = true;
			case "alt":
			case "opt":
			case "option": k.alt = true;
			case "shift": k.shift = true;
			case "cmd":
			case "super": k.super = true;
			default: return NOT_FOUND~;
		}
	}
	String lower = name.to_lower_tcopy();
	switch (lower) {
		case "enter":
		case "return": k.code = ENTER;
		case "esc":
		case "escape": k.code = ESC;
		case "tab": k.code = TAB;
		case "backspace": k.code = BACKSPACE;
		case "delete": k.code = DELETE;
		case "up": k.code = UP;
		case "down": k.code = DOWN;
		case "left": k.code = LEFT;
		case "right": k.code = RIGHT;
		case "home": k.code = HOME;
		case "end": k.code = END;
		case "pageup": k.code = PAGE_UP;
		case "pagedown": k.code = PAGE_DOWN;
		case "insert": k.code = INSERT;
		case "space": k.rune = ' ';
		case "f1": k.code = F1;
		case "f2": k.code = F2;
		case "f3": k.code = F3;
		case "f4": k.code = F4;
		case "f5": k.code = F5;
		case "f6": k.code = F6;
		case "f7": k.code = F7;
		case "f8": k.code = F8;
		case "f9": k.code = F9;
		case "f10": k.code = F10;
		case "f11": k.code = F11;
		case "f12": k.code = F12;
		default:
			Char32[]? runes = name.to_temp_utf32();
			if (catch runes) return NOT_FOUND~;
			if (runes.len != 1) return NOT_FOUND~;
			k.rune = runes[0];
			if (k.ctrl && k.rune >= 'A' && k.rune <= 'Z') k.rune += 'a' - 'A';
			if (k.ctrl && k.rune == 'c' && !k.alt && !k.shift && !k.super) {
				k.code = CTRL_C;
				k.rune = 0;
			}
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
	if (g_program != null) g_program.send({ .kind = MsgKind.KEY, .key = k });
	ctl_ok();
}

fn void ctl_type(String line, String[] toks, sz n) @local {
	if (n < 2) {
		ctl_err("type needs text");
		return;
	}
	// Everything after the command word, as keys. A line that said
	// `type "a b"` has its quotes already eaten by ctl_tokens.
	String text = toks[1];
	Char32[]? runes = text.to_temp_utf32();
	if (catch runes) {
		ctl_err("text is not UTF-8");
		return;
	}
	if (g_program != null) {
		foreach (r : runes) {
			KeyMsg k = r == '\n' ? (KeyMsg){ .code = ENTER } : (KeyMsg){ .code = RUNE, .rune = r };
			g_program.send({ .kind = MsgKind.KEY, .key = k });
		}
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
	sz from = 0;
	for (sz k = 0; ; k++) {
		sz at = hay[from..].index_of(needle)!;
		if (k == nth) return from + at;
		from += at + 1;
	}
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
		ctl_err(string::tformat("nothing matches %s", toks[1]));
		return;
	}
	CtlScreenText st = ctl_screen_text(t);
	sz nth = n >= 4 ? (sz)(toks[3].to_int() ?? 0) : 0;
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
	if (!g_ctl.on || !g_ctl.stream) return;
	// A release comes with no place of its own: it is where the pointer was.
	if (x == -2) {
		x = g_ctl.event_x;
		y = g_ctl.event_y;
	} else if (x < 0 || y < 0) {
		// Outside the window, however the backend says so.
		x = -1;
		y = -1;
	}
	if (type == "move" && x == g_ctl.event_x && y == g_ctl.event_y) return;
	g_ctl.event_x = x;
	g_ctl.event_y = y;
	@pool() {
		DString out = dstring::temp();
		out.append_string(type);
		out.appendf(" @%d,%d", xray::floor_cell(x, ctl_uw()), xray::floor_cell(y, ctl_uh()));
		ctl_emit(out.str_view());
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
			ctl_emit(out.str_view());
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
		ctl_emit(out.str_view());
	};
}

fn void ctl_emit(String s) @local {
	@pool() {
		DString out = dstring::temp();
		out.append_string(s);
		out.append_char('\n');
		String v = out.str_view();
		(void)write(1, v.ptr, v.len);
	};
}

// key_spec writes a key the way parse_key reads it.
fn String key_spec(KeyMsg k) @local {
	DString s = dstring::temp();
	if (k.ctrl || k.code == CTRL_C) s.append_string("ctrl+");
	if (k.alt) s.append_string("alt+");
	if (k.shift) s.append_string("shift+");
	if (k.super) s.append_string("cmd+");
	switch (k.code) {
		case ENTER: s.append_string("enter");
		case ESC: s.append_string("esc");
		case TAB: s.append_string("tab");
		case BACKSPACE: s.append_string("backspace");
		case DELETE: s.append_string("delete");
		case UP: s.append_string("up");
		case DOWN: s.append_string("down");
		case LEFT: s.append_string("left");
		case RIGHT: s.append_string("right");
		case HOME: s.append_string("home");
		case END: s.append_string("end");
		case PAGE_UP: s.append_string("pageup");
		case PAGE_DOWN: s.append_string("pagedown");
		case INSERT: s.append_string("insert");
		case CTRL_C: s.append_char('c');
		case F1: s.append_string("f1");
		case F2: s.append_string("f2");
		case F3: s.append_string("f3");
		case F4: s.append_string("f4");
		case F5: s.append_string("f5");
		case F6: s.append_string("f6");
		case F7: s.append_string("f7");
		case F8: s.append_string("f8");
		case F9: s.append_string("f9");
		case F10: s.append_string("f10");
		case F11: s.append_string("f11");
		case F12: s.append_string("f12");
		default:
			if (k.rune == ' ') {
				s.append_string("space");
			} else if (k.rune == '+') {
				s.append_string("+");
			} else {
				s.append_char32(k.rune);
			}
	}
	return s.str_view();
}
