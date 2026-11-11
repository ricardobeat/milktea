// Left out of a build with -D NO_CONTROL (see control_off.c3).
module milktea @feat(!NO_CONTROL);

import xray;
import std::atomic;
import std::core::dstring;
import num;
import utf8;

// Control lets another program, such as an agent, drive this one: read what
// it shows, and send it the input a person would. A command is a line, and is
// answered with its output and then "ok", or with one line "err ...".
//
//   tree            the nodes on screen: name key=K @col,row WxH, state, text
//   screen          the text on screen, a line a row
//   click T         move to T, press and release
//   move T          move to T, which hovers it
//   drag T1 T2      press at T1, move to T2 and release there
//   scroll T N      N rows at T; positive scrolls towards the end
//   key SPEC...     ctrl+b, enter, shift+tab, a, ...
//   type TEXT       the rest of the line, a key a character
//   quit
//
// A target T is a cell, @col,row; a word, which is a node's id, role, type
// or key, or else text it shows; or text it shows, in quotes: "Save as". Of
// the nodes that match, the topmost.
//
// Commands come from stdin when it is not a terminal (always, in a window
// app), answered on stdout; and from `<program> --cmd COMMAND`, run anywhere
// else, through a named pipe. Whoever is at the program is asked to allow the
// first of those, unless it was started with MILKTEA_CONTROL=1;
// MILKTEA_CONTROL=0 turns the pipe off.
//
// Commands run while a frame is drawn, against the tree and the screen of
// that frame. One that sends input is answered in the first frame drawn once
// the input is handled, and the commands after it wait for that.

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
fn void install_control_hooks(ControlHooks hooks) => g_ctl.hooks = hooks;

// ── State ──────────────────────────────────────────────────────────────────

// CtlSrc is where command lines come from; buf holds what has been read, of
// which the first at bytes are handled.
struct CtlSrc @local {
	int fd;
	bool eof;
	DString buf;
	sz at;
}

struct Control @local {
	bool on;
	// stdin, and the command pipe.
	CtlSrc[2] src;
	// A terminal's reader thread watches the sources only while armed, so it
	// wakes the loop once for what arrives.
	Atomic{bool} armed;
	// Replies go to stdout, or nowhere on a terminal; a command from --cmd
	// names a pipe of its own for its reply (reply_piped).
	int reply_default;
	int reply_fd;
	bool reply_piped;
	bool failed;
	// A command sent input: its "ok" waits for a frame that has handled it.
	bool owed;
	bool pressed;
	ControlHooks hooks;
	// The frame being drawn, while commands run.
	xray::Node* root;
	xray::ScreenBuffer* buf;
	xray::LayoutMetrics metrics;
	// The command pipe.
	bool pipe_open;
	bool allowed;
	ZString path;
	ZString link;
	ZString target;
	String prefix;
	// The dialog that asks to allow it.
	bool asking;
	bool refused;
	bool yes_chosen;
	bool hover;
}

Control g_ctl @local;

// control_start turns commands on, from stdin too when use_stdin.
fn void control_start(bool use_stdin) {
	if (g_ctl.on) return;
	g_ctl.on = true;
	g_ctl.src[0].fd = use_stdin ? STDIN_FILENO : -1;
	g_ctl.src[1].fd = g_ctl.pipe_open ? g_ctl.src[1].fd : -1;
	g_ctl.src[0].buf.init(mem);
	g_ctl.src[1].buf.init(mem);
	g_ctl.reply_default = use_stdin ? STDOUT_FILENO : -1;
	g_ctl.reply_fd = g_ctl.reply_default;
	g_ctl.armed.store(true);
}

// control_watch gives a terminal's reader thread the sources to wake the loop
// for; control_disarm is what it calls when one has something.
fn sz control_watch(PollFd[] out) {
	if (!g_ctl.on || !g_ctl.armed.load()) return 0;
	sz n = 0;
	foreach (&s : g_ctl.src) {
		if (s.fd >= 0 && !s.eof) out[n++] = { .fd = s.fd, .events = POLLIN };
	}
	return n;
}

fn void control_disarm() => g_ctl.armed.store(false);

fn bool ctl_has_line(CtlSrc* s) @local => ctl_index(s.buf.str_view()[s.at..], "\n") >= 0;

// control_busy: commands are waiting to run, or an answer for a frame. The
// pipe's wait for a person to allow them does not count.
fn bool control_busy() {
	if (!g_ctl.on) return false;
	bool pipe = ctl_has_line(&g_ctl.src[1]) && (g_ctl.allowed || g_ctl.refused);
	return g_ctl.owed || ctl_has_line(&g_ctl.src[0]) || pipe;
}

// control_ended: stdin, as commands, has run out and is all handled.
fn bool control_ended() => g_ctl.on && g_ctl.src[0].fd >= 0 && g_ctl.src[0].eof && !control_busy();

// control_poll reads what has come, once a pass of a backend's loop, and asks
// for the frame commands run in.
fn void control_poll() {
	if (!g_ctl.on) return;
	foreach (&s : g_ctl.src) ctl_read(s);
	if (ctl_has_line(&g_ctl.src[1]) && !g_ctl.allowed && !g_ctl.refused && !g_ctl.asking) {
		g_ctl.asking = true;
		g_ctl.yes_chosen = false;
		request_redraw();
	}
	if (control_busy()) request_redraw();
	g_ctl.armed.store(true);
}

// ctl_read takes in what a source has, without waiting. The end of input
// ends a last line that has no newline.
fn void ctl_read(CtlSrc* s) @local {
	while (s.fd >= 0 && !s.eof) {
		PollFd p = { .fd = s.fd, .events = POLLIN };
		if (poll(&p, 1, 0) <= 0) return;
		char[1024] chunk;
		sz n = read(s.fd, &chunk, chunk.len);
		if (n < 0) return;
		if (n == 0) {
			s.eof = true;
			s.buf.append_char('\n');
			return;
		}
		s.buf.append_bytes(chunk[:n]);
	}
}

// ctl_next_line takes a source's next whole line. With none, what is handled
// is let go of.
fn bool ctl_next_line(CtlSrc* s, String* line) @local {
	String rest = s.buf.str_view()[s.at..];
	sz nl = ctl_index(rest, "\n");
	if (nl >= 0) {
		*line = rest[:nl];
		s.at += nl + 1;
		return true;
	}
	String keep = rest.tcopy();
	s.buf.clear();
	s.buf.append_string(keep);
	s.at = 0;
	return false;
}

// control_on_draw runs the commands waiting, against the frame just drawn.
// draw() calls it.
fn void control_on_draw(xray::Node* root, xray::ScreenBuffer* buf, sz repaint_ms) {
	if (!g_ctl.on || root == null) return;
	g_ctl.root = root;
	g_ctl.buf = buf;
	g_ctl.metrics = root.layout_metrics;
	if (g_ctl.owed) {
		if (g_program != null && g_program.send_head != g_program.send_tail) return;
		g_ctl.owed = false;
		ctl_last("ok");
		ctl_reply_end();
	}
	@pool() {
		foreach (k, &s : g_ctl.src) {
			// The pipe's commands wait to be allowed, and are refused after a no.
			bool refuse = k == 1 && !g_ctl.allowed;
			if (refuse && !g_ctl.refused) continue;
			String line;
			while (!g_ctl.owed && ctl_next_line(s, &line)) ctl_run(line, refuse);
			if (refuse) g_ctl.refused = false;
		}
	};
}

// ctl_run runs one line. ">PATH<tab>COMMAND" is from --cmd, answered on PATH.
fn void ctl_run(String line, bool refuse) @local {
	if (line.len > 0 && line[0] == '>') {
		sz tab = ctl_index(line, "\t");
		if (tab < 0) return;
		g_ctl.reply_fd = ctl_reply_open(line[1:tab - 1]);
		g_ctl.reply_piped = true;
		line = line[tab + 1..];
	}
	if (refuse) {
		ctl_err("remote control was refused");
	} else {
		ctl_handle(ctl_trim(line));
	}
	if (!g_ctl.owed) ctl_reply_end();
}

// ── Replies ────────────────────────────────────────────────────────────────

// What starts the last line of a reply to --cmd, so a line of the screen
// that reads "ok" does not end it.
const String REPLY_END @local = "\x1e";

// ctl_line writes one reply line in one write, so two writers' lines cannot
// mix.
fn void ctl_line(String s) @local {
	if (g_ctl.reply_fd >= 0) ctl_write(g_ctl.reply_fd, ctl_cat(s, "\n"));
}

fn void ctl_last(String s) @local => ctl_line(g_ctl.reply_piped ? ctl_cat(REPLY_END, s) : s);

fn void ctl_err(String s) @local {
	g_ctl.failed = true;
	ctl_last(ctl_cat("err ", s));
}

fn void ctl_reply_end() @local {
	if (!g_ctl.reply_piped) return;
	if (g_ctl.reply_fd >= 0) close(g_ctl.reply_fd);
	g_ctl.reply_fd = g_ctl.reply_default;
	g_ctl.reply_piped = false;
}

// ctl_write writes all of s, waiting a while for a reader that has fallen
// behind and giving up on one that has gone.
fn void ctl_write(int fd, String s) @local {
	for (int tries = 0; s.len > 0 && tries < 64; tries++) {
		sz n = write(fd, s.ptr, s.len);
		if (n > 0) {
			s = s[n..];
			continue;
		}
		PollFd p = { .fd = fd, .events = POLLOUT };
		if (poll(&p, 1, 1000) <= 0 || (p.revents & (POLLERR | POLLHUP)) != 0) return;
	}
}

// ── Commands ───────────────────────────────────────────────────────────────

alias CtlFn = fn void(String[] args, String line);

struct CtlCmd @local {
	String name;
	sz need;
	CtlFn run;
}

CtlCmd[*] g_ctl_cmds @local = {
	{ "tree", 0, &ctl_tree },
	{ "screen", 0, &ctl_screen },
	{ "click", 1, &ctl_click },
	{ "move", 1, &ctl_move },
	{ "drag", 2, &ctl_drag },
	{ "scroll", 2, &ctl_scroll },
	{ "key", 1, &ctl_key },
	{ "type", 1, &ctl_type },
	{ "quit", 0, &ctl_quit },
};

fn void ctl_handle(String line) @local {
	String[8] t;
	sz n = ctl_tokens(line, t[..]);
	if (n == 0) return;
	g_ctl.failed = false;
	foreach (&c : g_ctl_cmds) {
		if (c.name != t[0]) continue;
		if (n - 1 < c.need) {
			ctl_err(ctl_cat(c.name, ": missing argument"));
			return;
		}
		c.run(t[1:n - 1], line);
		if (!g_ctl.failed && !g_ctl.owed) ctl_last("ok");
		return;
	}
	ctl_err(ctl_cat("unknown command \"", t[0], "\": tree screen click move drag scroll key type quit"));
}

// ctl_tokens splits a line into words at spaces outside quotes. Returns how
// many, at most the array holds.
fn sz ctl_tokens(String s, String[] out) @local {
	sz n = 0;
	for (sz i = 0; i < s.len && n < out.len;) {
		if (s[i] == ' ') {
			i++;
			continue;
		}
		sz start = i;
		char q = 0;
		for (; i < s.len && (q != 0 || s[i] != ' '); i++) {
			if (q != 0) {
				if (s[i] == q) q = 0;
			} else if (s[i] == '"' || s[i] == '\'') {
				q = s[i];
			}
		}
		out[n++] = s[start:i - start];
	}
	return n;
}

fn void ctl_quit(String[] a, String line) @local {
	if (g_program != null) g_program.send({ .kind = MsgKind.QUIT });
}

// ── Reading the frame ──────────────────────────────────────────────────────

// The names roles go by, in xray::Role's order.
const String[*] ROLE_NAMES @local = {
	"", "group", "button", "link", "checkbox", "text", "text-field", "list", "list-item",
	"menu-bar", "menu", "menu-item", "dialog", "tab", "scrollbar", "status", "image",
};

// ctl_cells is a rect in layout units as the cells it covers.
fn xray::Rect ctl_cells(xray::Rect r) @local {
	sz uw = g_ctl.metrics.unit_w();
	sz uh = g_ctl.metrics.unit_h();
	return {
		.x = xray::floor_cell(r.x, uw), .y = xray::floor_cell(r.y, uh),
		.w = (r.w + uw - 1) / uw, .h = (r.h + uh - 1) / uh,
	};
}

// ctl_row is the text of cells x0 to x1 of row y, a blank cell a space and
// the right half of a wide character nothing.
fn String ctl_row(sz y, sz x0, sz x1) @local {
	xray::ScreenBuffer* b = g_ctl.buf;
	DString out = dstring::temp();
	if (y < 0 || y >= b.height) return "";
	bool wide = false;
	for (sz x = x0 < 0 ? 0 : x0; x < x1 && x < b.width; x++) {
		xray::Cell* c = &b.cells[y * b.width + x];
		out.append_string(c.content_len > 0 ? (String)c.content[:c.content_len] : wide ? "" : " ");
		wide = c.width == 2;
	}
	return out.str_view();
}

// ctl_text is what a node shows, its rows trimmed and joined by newlines.
fn String ctl_text(xray::Node* n) @local {
	xray::Rect r = ctl_cells(n.computed_rect);
	DString out = dstring::temp();
	for (sz y = r.y; y < r.y + r.h; y++) {
		if (y > r.y) out.append_char('\n');
		out.append_string(ctl_trim(ctl_row(y, r.x, r.x + r.w)));
	}
	return ctl_trim(out.str_view());
}

fn void ctl_screen(String[] a, String line) @local {
	for (sz y = 0; y < g_ctl.buf.height; y++) ctl_line(ctl_trim(ctl_row(y, 0, g_ctl.buf.width)));
}

fn void ctl_tree(String[] a, String line) @local => ctl_node(g_ctl.root, 0);

// ctl_node writes a node and what is inside it, one a line, indented by depth.
fn void ctl_node(xray::Node* n, sz depth) @local {
	if (n == null || n.alpha_value == 0) return;
	DString o = dstring::temp();
	for (sz i = 0; i < depth; i++) o.append_string("  ");
	if (n.id_str.len > 0) {
		o.append_string(n.id_str);
	} else if (n.role_value != NONE) {
		o.append_string(ROLE_NAMES[(int)n.role_value]);
	} else {
		o.append_string(n.type_name.len > 0 ? n.type_name : "*");
	}
	if (n.key_str.len > 0) {
		bool q = ctl_index(n.key_str, " ") >= 0;
		o.append_string(ctl_cat(q ? " key=\"" : " key=", n.key_str, q ? "\"" : ""));
	}
	xray::Rect r = ctl_cells(n.computed_rect);
	o.append_string(ctl_cat(" @", num::str(r.x), ",", num::str(r.y), " ", num::str(r.w), "x", num::str(r.h)));
	if (n.on_click_fn != null) o.append_string(" clickable");
	if (n.has_keyboard_focus()) o.append_string(" focused");
	if (n.child_count == 0) {
		String t = ctl_text(n);
		if (t.len > 0 && ctl_index(t, "\n") < 0) o.append_string(ctl_cat(" \"", t, "\""));
	}
	ctl_line(o.str_view());
	for (sz i = 0; i < n.child_count; i++) ctl_node(n.children[i], depth + 1);
}

// ── Targets ────────────────────────────────────────────────────────────────

// CtlFind is what a target asks of a node, and the last node, in paint order
// the topmost, that has it.
struct CtlFind @local {
	String word;
	String text;
	xray::Node* found;
}

fn void ctl_find(CtlFind* f, xray::Node* n) @local {
	if (n == null || n.alpha_value == 0) return;
	String w = f.word;
	bool ok = w.len == 0 || w == n.id_str || w == n.key_str || w == n.type_name || w == ROLE_NAMES[(int)n.role_value];
	if (ok && (f.text.len == 0 || ctl_index(ctl_text(n), f.text) >= 0)) f.found = n;
	for (sz i = 0; i < n.child_count; i++) ctl_find(f, n.children[i]);
}

fn String ctl_unquote(String s) @local {
	if (s.len >= 2 && (s[0] == '"' || s[0] == '\'') && s[^1] == s[0]) return s[1:s.len - 2];
	return s;
}

// ctl_target is where a target points, in layout units. When it points
// nowhere it says so, and returns false.
fn bool ctl_target(String t, sz* x, sz* y) @local {
	sz uw = g_ctl.metrics.unit_w();
	sz uh = g_ctl.metrics.unit_h();
	if (t.len > 1 && t[0] == '@') {
		sz comma = ctl_index(t, ",");
		sz col = comma > 1 ? ctl_int(t[1:comma - 1]) : NO_NUM;
		sz row = comma > 1 ? ctl_int(t[comma + 1..]) : NO_NUM;
		if (col == NO_NUM || row == NO_NUM) {
			ctl_err(ctl_cat("bad cell ", t, ", not @col,row"));
			return false;
		}
		// A negative cell is outside the program.
		*x = col < 0 ? -1 : col * uw + uw / 2;
		*y = row < 0 ? -1 : row * uh + uh / 2;
		return true;
	}
	CtlFind f;
	if (t[0] == '"' || t[0] == '\'') {
		f.text = ctl_unquote(t);
	} else {
		f.word = t;
	}
	ctl_find(&f, g_ctl.root);
	// A word that names no node may be text one shows.
	if (f.found == null && f.word.len > 0) {
		f.text = f.word;
		f.word = "";
		ctl_find(&f, g_ctl.root);
	}
	if (f.found == null) {
		ctl_err(ctl_cat("nothing matches ", t, "; see tree"));
		return false;
	}
	xray::Rect r = f.found.computed_rect;
	*x = r.x + r.w / 2;
	*y = r.y + r.h / 2;
	return true;
}

// ── Input ──────────────────────────────────────────────────────────────────

fn void ctl_inject(MouseAction action, sz x, sz y) @local {
	g_ctl.owed = true;
	if (action != MOUSE_MOTION) g_ctl.pressed = action == MOUSE_PRESS;
	if (g_ctl.hooks.pointer) {
		g_ctl.hooks.pointer(action, x, y);
		return;
	}
	if (g_program == null) return;
	MouseMsg m = {
		.action = action,
		.button = action == MOUSE_MOTION && !g_ctl.pressed ? MOUSE_NONE : MOUSE_LEFT,
		.col = xray::floor_cell(x, g_ctl.metrics.unit_w()),
		.row = xray::floor_cell(y, g_ctl.metrics.unit_h()),
	};
	g_program.send({ .kind = MsgKind.MOUSE, .mouse = m });
}

// ctl_pointer finds its targets, then runs steps at them: m moves to the
// first, M to the last, p presses at the first, r releases at the first and
// R at the last.
fn void ctl_pointer(String[] a, String steps) @local {
	sz[2] x;
	sz[2] y;
	for (sz i = 0; i < 2; i++) {
		if (!ctl_target(a[i < a.len ? i : 0], &x[i], &y[i])) return;
	}
	foreach (st : steps) {
		sz i = st == 'M' || st == 'R' ? 1 : 0;
		char s = st | 0x20;
		ctl_inject(s == 'm' ? MOUSE_MOTION : s == 'p' ? MOUSE_PRESS : MOUSE_RELEASE, x[i], y[i]);
	}
}

fn void ctl_click(String[] a, String line) @local => ctl_pointer(a, "mpr");
fn void ctl_move(String[] a, String line) @local => ctl_pointer(a, "m");
fn void ctl_drag(String[] a, String line) @local => ctl_pointer(a, "mpMR");

fn void ctl_scroll(String[] a, String line) @local {
	sz x;
	sz y;
	if (!ctl_target(a[0], &x, &y)) return;
	sz rows = ctl_int(a[1]);
	if (rows == NO_NUM) {
		ctl_err("scroll: how many rows?");
		return;
	}
	g_ctl.owed = true;
	if (g_ctl.hooks.scroll) {
		g_ctl.hooks.scroll(x, y, 0, (double)rows);
		return;
	}
	MouseMsg m = {
		.action = MOUSE_PRESS, .button = rows < 0 ? MOUSE_WHEEL_UP : MOUSE_WHEEL_DOWN,
		.col = xray::floor_cell(x, g_ctl.metrics.unit_w()), .row = xray::floor_cell(y, g_ctl.metrics.unit_h()),
	};
	for (sz i = 0; g_program != null && i < (rows < 0 ? -rows : rows); i++) {
		g_program.send({ .kind = MsgKind.MOUSE, .mouse = m });
	}
}

fn void ctl_send_key(KeyMsg k) @local {
	g_ctl.owed = true;
	if (g_program != null) g_program.send({ .kind = MsgKind.KEY, .key = k });
}

fn void ctl_key(String[] a, String line) @local {
	KeyMsg[8] ks;
	foreach (i, spec : a) {
		KeyMsg? k = parse_key_spec(spec);
		if (catch k) {
			ctl_err(ctl_cat("unknown key \"", spec, "\""));
			return;
		}
		ks[i] = k;
	}
	foreach (k : ks[:a.len]) ctl_send_key(k);
}

// ctl_type sends the rest of the line as keys, without the quotes around it
// if it is quoted.
fn void ctl_type(String[] a, String line) @local {
	String text = ctl_unquote(ctl_trim(line[4..]));
	for (sz i = 0; i < text.len;) {
		uint r;
		i += utf8::decode(text[i..], &r);
		ctl_send_key({ .code = RUNE, .rune = r });
	}
}

// The names keys go by, in KeyCode's order. CTRL_C is "c" with ctrl.
const String[*] KEY_NAMES @local = {
	"", "", "enter", "backspace", "esc", "tab", "up", "down", "left", "right", "home", "end",
	"delete", "pageup", "pagedown", "insert", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8",
	"f9", "f10", "f11", "f12",
};

// ctl_ieq: a and b are equal, ASCII letters in either case.
fn bool ctl_ieq(String a, String b) @local {
	if (a.len != b.len) return false;
	foreach (i, x : a) {
		char l = x | 0x20;
		if (x != b[i] && (l != (b[i] | 0x20) || l < 'a' || l > 'z')) return false;
	}
	return true;
}

// parse_key_spec reads modifiers, each ending in +, then a key's name or the
// character it types: "ctrl+b", "shift+tab", "ctrl++".
fn KeyMsg? parse_key_spec(String spec) @local {
	KeyMsg k = { .code = RUNE };
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
		} else if (ctl_ieq(m, "alt") || ctl_ieq(m, "opt")) {
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
	if (ctl_ieq(name, "space")) name = " ";
	if (name.len > 1) {
		foreach (c, kn : KEY_NAMES) {
			if (c < 2 || !ctl_ieq(name, kn)) continue;
			k.code = (KeyCode)c;
			return k;
		}
	}
	uint r;
	if (name.len == 0 || utf8::decode(name, &r) != name.len) return NOT_FOUND~;
	if (k.ctrl && r >= 'A' && r <= 'Z') r += 32;
	k.rune = r;
	if (k.ctrl && r == 'c' && !k.alt && !k.shift && !k.super) {
		k.code = CTRL_C;
		k.rune = 0;
	}
	return k;
}

// ── Strings ────────────────────────────────────────────────────────────────

extern fn char* memmem(void* hay, usz hay_len, void* needle, usz needle_len) @local;

// ctl_index is where needle first starts in s, or -1, by the C library's
// search, which every program links already.
fn sz ctl_index(String s, String needle) @local {
	if (needle.len == 0) return 0;
	char* at = memmem(s.ptr, s.len, needle.ptr, needle.len);
	return at == null ? -1 : at - s.ptr;
}

// ctl_cat joins strings, on tmem: what the formatter would do, without
// bringing it into every program.
fn String ctl_cat(String... parts) @local {
	DString out = dstring::temp();
	foreach (p : parts) out.append_string(p);
	return out.str_view();
}

fn String ctl_trim(String s) @local {
	sz a = 0;
	sz e = s.len;
	while (a < e && s[a] <= ' ') a++;
	while (e > a && s[e - 1] <= ' ') e--;
	return s[a:e - a];
}

// ctl_int reads a whole number, perhaps with a leading -, or gives NO_NUM.
const sz NO_NUM @local = sz::min;
fn sz ctl_int(String s) @local {
	sz i = s.len > 0 && s[0] == '-' ? 1 : 0;
	if (i >= s.len) return NO_NUM;
	sz v = 0;
	for (; i < s.len; i++) {
		if (!s[i].is_digit()) return NO_NUM;
		v = v * 10 + (sz)(s[i] - '0');
	}
	return s[0] == '-' ? -v : v;
}

// ── Allowing remote control ────────────────────────────────────────────────

// The first command from the pipe of a program not started with
// MILKTEA_CONTROL=1 brings up, over whatever it draws,
//
//     Allow remote control?  [yes]  [no]
//
// and waits. Left, right or tab choose, enter answers, esc says no, and so
// does the mouse. "no" is chosen to begin with and letters answer nothing, so
// someone typing when it comes up cannot say yes by accident. On "no" the
// commands waiting are refused, and the next one asks again. Once allowed, a
// white dot on red sits in the bottom left corner, and says "remote control
// on" under the pointer.

fn void ctl_answer(bool yes) @local {
	if (!g_ctl.asking) return;
	g_ctl.asking = false;
	g_ctl.allowed = yes;
	g_ctl.refused = !yes;
	request_redraw();
}

// control_remote_key gives a key to the dialog: all of them while it is up.
fn bool control_remote_key(KeyMsg k) {
	if (!g_ctl.asking) return false;
	if (k.action == KeyAction.KEY_RELEASE) return true;
	switch (k.code) {
		case LEFT:
		case RIGHT:
		case TAB:
			g_ctl.yes_chosen = !g_ctl.yes_chosen;
			request_redraw();
		case ENTER: ctl_answer(g_ctl.yes_chosen);
		case ESC: ctl_answer(false);
		default:
	}
	return true;
}

fn void ctl_yes(void* id, String id_str, sz col, sz row) @local => ctl_answer(true);
fn void ctl_no(void* id, String id_str, sz col, sz row) @local => ctl_answer(false);
fn void ctl_hover_in(void* id, String id_str, sz col, sz row) @local => g_ctl.hover = true;
fn void ctl_hover_out(void* id, String id_str, sz col, sz row) @local => g_ctl.hover = false;

// Colours as escape codes, which text draws as they are.
const String PANEL @local = "\e[38;2;255;255;255;48;2;43;43;43m";
const String BUTTON_INK @local = "\e[38;2;255;255;255;48;2;74;74;74m";
const String CHOSEN_INK @local = "\e[38;2;43;43;43;48;2;255;255;255m";
const String RED @local = "\e[38;2;255;255;255;48;2;208;32;32m";

fn Node* ctl_button(String label, bool chosen, xray::ClickFn on_click) @local {
	return text(ctl_cat(chosen ? CHOSEN_INK : BUTTON_INK, " ", label, " "))
		.role(BUTTON).key(label).on_click(on_click).pointer(HAND);
}

// control_overlay puts the dialog, or the dot, over the frame's tree. draw
// calls it.
fn Node* control_overlay(Node* tree) @private {
	if (tree == null || (!g_ctl.asking && !g_ctl.allowed)) return tree;
	Node* over = xray::root();
	over.add(tree);
	if (g_ctl.asking) {
		Node* d = xray::hstack().role(DIALOG).block_pointer();
		d.add(text(PANEL +++ "  Allow remote control?  "));
		d.add(ctl_button("yes", g_ctl.yes_chosen, &ctl_yes));
		d.add(text(PANEL +++ "  "));
		d.add(ctl_button("no", !g_ctl.yes_chosen, &ctl_no));
		d.add(text(PANEL +++ "  "));
		over.add(d.place(JUSTIFY_CENTER, ALIGN_END).offset(0, -1));
	} else {
		String dot = g_ctl.hover ? RED +++ " ● " +++ PANEL +++ " remote control on " : RED +++ " ● ";
		over.add(text(dot).role(STATUS).on_hover_in(&ctl_hover_in).on_hover_out(&ctl_hover_out)
			.place(JUSTIFY_START, ALIGN_END).offset(1, -1));
	}
	return over;
}

// ── The command pipe ───────────────────────────────────────────────────────

// Everything lives in a directory only the user can enter,
// <tmp>/milktea-<uid>/:
//
//   <name>.pid      a link to the pid of the most recently started <name>,
//                   which --cmd drives unless MILKTEA_PID names another
//   <name>.<pid>    that program's command pipe
//   .reply.<pid>    a --cmd's pipe for its reply, named before the command

extern fn int mkfifo(char* path, uint mode) @local;
extern fn int mkdir(char* path, uint mode) @local;
extern fn int open(char* path, int flags, ...) @local;
extern fn int close(int fd) @local;
extern fn int symlink(char* target, char* link) @local;
extern fn sz readlink(char* path, char* buf, sz len) @local;
extern fn int unlink(char* path) @local;
extern fn uint getuid() @local;
extern fn int atexit(void* handler) @local;
extern fn void exit(int code) @local;

const int O_WRONLY @local = 1;
const int O_RDWR @local = 2;
const int O_NONBLOCK @local = env::LINUX ? 0x800 : 0x4;
const int SIGPIPE @local = 13;
const short POLLOUT @local = 4;
const short POLLERR @local = 8;
const short POLLHUP @local = 16;
// Writes to a pipe this short arrive whole, so two clients' lines never mix.
const sz PIPE_LINE_MAX @local = 512;
// How long --cmd waits for its answer, which may be a person allowing it.
const int CLIENT_WAIT_MS @local = 60000;

// A program's main() need not pass its arguments on, so they are read from
// the system.
extern fn char*** ns_get_argv() @cname("_NSGetArgv") @local;
extern fn int* ns_get_argc() @cname("_NSGetArgc") @local;

fn String[] program_args() @local {
	$switch:
	$case env::DARWIN:
		int argc = *ns_get_argc();
		char** argv = *ns_get_argv();
		String[] out = mem::talloc_array(String, argc);
		for (int i = 0; i < argc; i++) out[i] = ((ZString)argv[i]).str_view();
		return out;
	$case env::LINUX:
		int fd = open("/proc/self/cmdline", 0);
		if (fd < 0) return {};
		char[] buf = mem::talloc_array(char, 8192);
		sz n = read(fd, buf.ptr, buf.len);
		close(fd);
		String[] out = mem::talloc_array(String, 64);
		sz k = 0;
		for (sz i = 0, start = 0; i < n && k < out.len; i++) {
			if (buf[i] != 0) continue;
			out[k++] = (String)buf[start:i - start];
			start = i + 1;
		}
		return out[:k];
	$default:
		return {};
	$endswitch
}

// ctl_paths gives the directory, with a slash, and the program's name, on tmem.
fn String ctl_paths(String* name) @local {
	String[] args = program_args();
	String a0 = args.len > 0 ? args[0] : "";
	sz i = a0.len;
	while (i > 0 && a0[i - 1] != '/') i--;
	*name = a0[i..];
	String tmp = "/tmp";
	char* t = getenv("TMPDIR");
	if (t != null && ((ZString)t).len() > 0) tmp = ((ZString)t).str_view();
	while (tmp.len > 1 && tmp[^1] == '/') tmp = tmp[:^1];
	return ctl_cat(tmp, "/milktea-", num::str(getuid()), "/");
}

// control_announce opens the program's command pipe and points <name>.pid at
// it. Backends call it as they start. Returns whether the program listens.
fn bool control_announce() {
	if (g_ctl.pipe_open) return true;
	char* v = getenv("MILKTEA_CONTROL");
	String want = v == null ? "" : ((ZString)v).str_view();
	if (want == "0") return false;
	@pool() {
		String name;
		String dir = ctl_paths(&name);
		if (name.len == 0) return false;
		mkdir(dir.zstr_copy(tmem), 0o700);
		g_ctl.prefix = dir.copy(mem);
		g_ctl.target = num::str(getpid()).zstr_copy(mem);
		g_ctl.path = ctl_cat(dir, name, ".", g_ctl.target.str_view()).zstr_copy(mem);
		g_ctl.link = ctl_cat(dir, name, ".pid").zstr_copy(mem);
	};
	unlink(g_ctl.path);
	if (mkfifo(g_ctl.path, 0o600) != 0) return false;
	// Open for reading and writing, so the pipe never reads as ended when a
	// client goes away, and opening does not wait for one.
	int fd = open(g_ctl.path, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		unlink(g_ctl.path);
		return false;
	}
	unlink(g_ctl.link);
	symlink(g_ctl.target, g_ctl.link);
	// A client that goes away mid-reply must not take the program with it.
	signal(SIGPIPE, (void*)(uptr)1);
	atexit(&ctl_pipe_close);
	g_ctl.src[1].fd = fd;
	g_ctl.pipe_open = true;
	g_ctl.allowed = want.len > 0;
	return true;
}

// ctl_pipe_close removes what the program left. The link goes only if it
// still points here: a program started later may have taken it over.
fn void ctl_pipe_close() @local {
	if (!g_ctl.pipe_open) return;
	g_ctl.pipe_open = false;
	char[32] buf;
	sz n = readlink(g_ctl.link, &buf, buf.len);
	if (n > 0 && (String)buf[:n] == g_ctl.target.str_view()) unlink(g_ctl.link);
	unlink(g_ctl.path);
}

// ctl_reply_open opens the pipe a client named for its reply, or gives -1.
// It must be in the directory; the client holds it open, so this does not
// wait.
fn int ctl_reply_open(String path) @local {
	String p = g_ctl.prefix;
	if (!g_ctl.pipe_open || !path.starts_with(p) || ctl_index(path[p.len..], "/") >= 0) return -1;
	return open(path.zstr_copy(tmem), O_WRONLY | O_NONBLOCK);
}

// ── The client: <program> --cmd COMMAND ────────────────────────────────────

fn void ctl_say(String name, String what) @local {
	String s = ctl_cat(name, ": ", what, "\n");
	(void)write(2, s.ptr, s.len);
}

// control_client is the whole of a run given --cmd: it sends the rest of
// the command line to the running program as one command, prints the reply,
// and exits 0 on ok, 1 on err. Any other run returns from it at once. run()
// calls it before it touches the terminal.
fn void control_client() {
	@pool() {
		String[] args = program_args();
		sz at = 1;
		while (at < args.len && args[at] != "--cmd") at++;
		if (at >= args.len) return;
		String name;
		String dir = ctl_paths(&name);
		DString cmd = dstring::temp();
		foreach (w : args[at + 1..]) {
			if (cmd.len() > 0) cmd.append_char(' ');
			cmd.append_string(w);
		}
		// The program MILKTEA_PID names, else the most recently started.
		String pid;
		char* named = getenv("MILKTEA_PID");
		if (named != null) {
			pid = ((ZString)named).str_view();
		} else {
			char[] buf = mem::talloc_array(char, 32);
			sz n = readlink(ctl_cat(dir, name, ".pid").zstr_copy(tmem), buf.ptr, buf.len);
			if (n > 0) pid = (String)buf[:n];
		}
		ZString reply = ctl_cat(dir, ".reply.", num::str(getpid())).zstr_copy(tmem);
		String line = ctl_cat(">", reply.str_view(), "\t", cmd.str_view(), "\n");
		if (cmd.len() == 0 || line.len > PIPE_LINE_MAX) {
			ctl_say(name, "--cmd takes one command, such as tree");
			exit(2);
		}
		// Opening fails when nobody reads the pipe: the program is gone.
		int to = open(ctl_cat(dir, name, ".", pid).zstr_copy(tmem), O_WRONLY | O_NONBLOCK);
		unlink(reply);
		int from = mkfifo(reply, 0o600) == 0 ? open(reply, O_RDWR) : -1;
		if (to < 0 || from < 0) {
			ctl_say(name, "nothing is running that can be driven");
			unlink(reply);
			exit(1);
		}
		(void)write(to, line.ptr, line.len);
		close(to);
		exit(ctl_client_read(name, from, reply));
	};
}

// ctl_client_read prints the reply as it comes, and gives the exit code.
fn int ctl_client_read(String name, int from, ZString reply) @local {
	defer unlink(reply);
	DString got = dstring::temp();
	sz used = 0;
	for (int waited = 0; waited < CLIENT_WAIT_MS;) {
		PollFd p = { .fd = from, .events = POLLIN };
		if (poll(&p, 1, 1000) <= 0) {
			waited += 1000;
			if (waited == 1000) ctl_say(name, "waiting; it may be asking to be allowed");
			continue;
		}
		char[1024] chunk;
		sz n = read(from, &chunk, chunk.len);
		if (n > 0) got.append_bytes(chunk[:n]);
		for (sz nl; (nl = ctl_index(got.str_view()[used..], "\n")) >= 0; used += nl + 1) {
			String s = got.str_view()[used:nl + 1];
			if (s[0] == REPLY_END[0]) {
				(void)write(STDOUT_FILENO, s.ptr + 1, s.len - 1);
				return s.starts_with("\x1eerr") ? 1 : 0;
			}
			(void)write(STDOUT_FILENO, s.ptr, s.len);
		}
	}
	ctl_say(name, "no answer");
	return 1;
}
