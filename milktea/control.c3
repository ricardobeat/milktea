module milktea;

import xray;
import std::io;
import std::math;
import std::net::os;
import std::encoding::json;
import std::collections::object;
import std::collections::list;
import std::encoding::experimental::regex;
import std::core::dstring;
import std::core::string;
import std::os::env;
import libc;

// The control socket lets another process drive a running program: read the
// tree it last drew, send it input, wait for it to settle, and follow the
// input it gets. It is off unless MILKTEA_CONTROL names a socket path:
//
//   MILKTEA_CONTROL=/tmp/app.sock ./app
//
// The socket is a Unix stream socket only this user can open. Each request
// is one JSON object on a line and each reply one line back, echoing the
// request's "id" when it has one. Requests are handled between frames, on the
// program's own thread, and input goes through the same dispatch real input
// takes. A program's main can hand `app ctl ...` to control_client, so the
// binary is its own client.
//
// Nodes are picked by selector, matched against the last drawn frame:
//
//   word          a node whose id, role (button, list-item, ...) or content
//                 type (View) is word; * is any node
//   [key="v"]     its key, id, role, type or on-screen text: = is equal,
//                 *= contains, ^= starts with
//   :focused      it has keyboard focus; :clickable, it takes clicks
//   :nth(n)       the nth match, from 0, of the whole selector
//   a b           b inside a
//
// Requests ("cmd"):
//
//   ping
//   tree       {target?, depth?}       the tree, from the root or each match
//   find       {target}                the matches, as a flat list
//   click      {target | at, cell?}    move there, press and release
//   press, release, move {target | at, cell?}
//   drag       {from, to}              each a {target | at, cell?}
//   scroll     {target | at?, dy, dx?} rows, positive towards the end
//   key        {key}                   "ctrl+b", "enter", "shift+tab", "a"
//   type       {text}
//   select     {target, text | match, nth?}  drag across text on screen
//   wait       {frames | idle | target, timeout_ms?}
//   subscribe  {events}                "input", "frame"; then events arrive
//                                      as {"event": ...} lines
//   unsubscribe
//
// `target` is a selector; the first node it matches is the target. `at` is
// [col, row] in cells. `cell` is [col, row] within the target's content. A
// target that matches nothing falls back to `at` when there is one.
//
// An input event is the request that repeats it, with "event" for "cmd":
// {"event":"press","target":...,"cell":[c,r],"at":[c,r]}. Its selector finds
// the node again, so another program can replay it on its own copy of the
// tree, however differently laid out.

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

struct CtlClient @local {
	os::NativeSocket fd;
	DString in;
	DString out;
	bool input_events;
	bool frame_events;
	bool closed;
}

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

enum CtlWaitKind : char @local {
	FRAMES,
	IDLE,
	TARGET,
}

struct CtlWait @local {
	CtlClient* client;
	String id;
	CtlWaitKind kind;
	sz frames;
	String target;
	sz since_ms;
	sz deadline_ms;
}

struct Control @local {
	bool started;
	bool on;
	os::NativeSocket listen_fd;
	String path;
	List{CtlClient*} clients;
	List{CtlWait} waits;
	ControlHooks hooks;
	bool pressed;
	// The snapshot of the last drawn frame.
	List{CtlNode} nodes;
	DString strs;
	xray::ScreenBuffer* buf;
	xray::LayoutMetrics metrics;
	sz frame;
	sz repaint_ms;
	// The last pointer position reported to subscribers, in layout units.
	sz event_x;
	sz event_y;
}

Control g_ctl @local;

// control_active reports whether the control socket is open, so a loop
// that would sleep for long wakes often enough to serve it.
fn bool control_active() => g_ctl.on;

// ── Socket ─────────────────────────────────────────────────────────────────

struct CtlAddr @local @feat(DARWIN) {
	char len;
	char family;
	char[104] path;
}

struct CtlAddr @local @feat(!DARWIN) {
	ushort family;
	char[108] path;
}

extern fn CInt unlink(ZString path) @local;
extern fn CInt chmod(ZString path, ushort mode) @local;

fn bool ctl_addr(CtlAddr* a, String path) @local {
	*a = {};
	if (path.len >= a.path.len) return false;
	$if env::DARWIN:
		a.len = (char)CtlAddr::size;
	$endif
	a.family = (char)os::AF_UNIX;
	a.path[:path.len] = path[..];
	return true;
}

fn void ctl_nonblocking(os::NativeSocket fd) @local {
	(void)fd.set_non_blocking(true);
}

fn void control_start() @local {
	g_ctl.started = true;
	String? path = env::tget_var("MILKTEA_CONTROL");
	if (catch path) return;
	if (path.len == 0) return;
	CtlAddr a;
	if (!ctl_addr(&a, path)) {
		ctl_complain("milktea: control socket path too long: %s", path);
		return;
	}
	os::NativeSocket fd = os::socket(os::AF_UNIX, os::SOCK_STREAM, (os::AIProtocol)0);
	if ((CInt)fd < 0) return;
	(void)unlink(path.zstr_tcopy());
	if (os::bind(fd, (os::SockAddrPtr)&a, (os::Socklen_t)CtlAddr::size) != 0 || os::listen(fd, 8) != 0) {
		ctl_complain("milktea: cannot listen on %s: %s", path, libc::strerror(libc::errno()));
		(void)libc::close((CInt)fd);
		return;
	}
	(void)chmod(path.zstr_tcopy(), 0o600);
	ctl_nonblocking(fd);
	g_ctl.listen_fd = fd;
	g_ctl.path = path.copy(mem);
	g_ctl.on = true;
	g_ctl.strs.init(mem);
	g_ctl.nodes.init(mem);
	g_ctl.clients.init(mem);
	g_ctl.waits.init(mem);
}

fn void ctl_write(CtlClient* c, String s) @local {
	if (c.closed) return;
	c.out.append_string(s);
	c.out.append_char('\n');
}

fn void ctl_flush(CtlClient* c) @local {
	while (!c.closed && c.out.len() > 0) {
		String pending = c.out.str_view();
		sz n = libc::write((Fd)c.fd, pending.ptr, pending.len);
		if (n <= 0) {
			if (n < 0 && libc::errno() == EAGAIN) return;
			c.closed = true;
			return;
		}
		c.out.delete(0, (sz)n);
	}
}

// control_poll serves the socket: new connections, requests, and replies
// waiting on time. Backends call it once a pass of their loop.
fn void control_poll() {
	if (!g_ctl.started) control_start();
	if (!g_ctl.on) return;
	@pool() {
		for (;;) {
			os::NativeSocket fd = os::accept(g_ctl.listen_fd, (os::SockAddrPtr)null, null);
			if ((CInt)fd < 0) break;
			ctl_nonblocking(fd);
			CtlClient* c = mem::new(CtlClient);
			c.fd = fd;
			c.in.init(mem);
			c.out.init(mem);
			g_ctl.clients.push(c);
		}
		foreach (c : g_ctl.clients) ctl_read(c);
		ctl_check_waits();
		for (sz i = 0; i < g_ctl.clients.len(); ) {
			CtlClient* c = g_ctl.clients[i];
			ctl_flush(c);
			if (!c.closed) {
				i++;
				continue;
			}
			ctl_drop_waits(c);
			(void)libc::close((CInt)c.fd);
			c.in.free();
			c.out.free();
			mem::free(c);
			g_ctl.clients.remove_at(i);
		}
	};
}

fn void ctl_read(CtlClient* c) @local {
	char[4096] chunk;
	for (;;) {
		sz n = libc::read((Fd)c.fd, &chunk, chunk.len);
		if (n == 0) {
			c.closed = true;
			break;
		}
		if (n < 0) {
			if (libc::errno() != EAGAIN) c.closed = true;
			break;
		}
		c.in.append_bytes(chunk[:n]);
	}
	for (;;) {
		// A request waits for the input before it to be handled and drawn:
		// where it points is worked out against the frame on screen, and a
		// terminal handles input later, from a queue.
		if (ctl_queued()) break;
		String s = c.in.str_view();
		sz? nl = s.index_of_char('\n');
		if (catch nl) break;
		String line = s[:nl].tcopy();
		c.in.delete(0, nl + 1);
		if (line.trim().len > 0) ctl_handle(c, line);
	}
}

fn void ctl_drop_waits(CtlClient* c) @local {
	for (sz i = 0; i < g_ctl.waits.len(); ) {
		if (g_ctl.waits[i].client != c) {
			i++;
			continue;
		}
		ctl_free_wait(&g_ctl.waits[i]);
		g_ctl.waits.remove_at(i);
	}
}

fn void ctl_free_wait(CtlWait* w) @local {
	w.id.free(mem);
	w.target.free(mem);
}

// ctl_complain writes a line to stderr in one write, so the lines of two
// programs writing at once, as both ends of a pipe of ctl clients may, do
// not come out interleaved.
fn void ctl_complain(String fmt, args...) @local {
	@pool() {
		String line = string::tformat(fmt, ...args);
		line = line.tconcat("\n");
		(void)libc::write((Fd)2, line.ptr, line.len);
	};
}

// ── Replies ────────────────────────────────────────────────────────────────

fn void json_string(DString* out, String s) @local {
	out.append_char('"');
	foreach (ch : s) {
		switch (ch) {
			case '"': out.append_string("\\\"");
			case '\\': out.append_string("\\\\");
			case '\n': out.append_string("\\n");
			case '\r': out.append_string("\\r");
			case '\t': out.append_string("\\t");
			default:
				if (ch < 0x20) {
					out.appendf("\\u%04x", ch);
				} else {
					out.append_char(ch);
				}
		}
	}
	out.append_char('"');
}

// ctl_reply starts a reply line, {"id":...,"ok":true, and leaves it open for
// more fields; the caller ends it with ctl_send.
fn DString ctl_reply(String id, bool ok = true) @local {
	DString out = dstring::temp();
	out.append_char('{');
	if (id.len > 0) out.appendf("\"id\":%s,", id);
	out.appendf("\"ok\":%s", ok ? "true" : "false");
	return out;
}

fn void ctl_send(CtlClient* c, DString* out) @local {
	out.append_char('}');
	ctl_write(c, out.str_view());
}

fn void ctl_error(CtlClient* c, String id, String message) @local {
	DString out = ctl_reply(id, false);
	out.append_string(",\"error\":");
	json_string(&out, message);
	ctl_send(c, &out);
}

fn void ctl_ok(CtlClient* c, String id) @local {
	DString out = ctl_reply(id);
	ctl_send(c, &out);
}

// ── Requests ───────────────────────────────────────────────────────────────

fn String? obj_string(Object* o, String key) @local {
	if (!o.has_key(key)) return NOT_FOUND~;
	Object* v = o.get(key)!;
	if (!v.is_string()) return NOT_FOUND~;
	return v.s;
}

fn double? obj_number(Object* o, String key) @local {
	if (!o.has_key(key)) return NOT_FOUND~;
	Object* v = o.get(key)!;
	if (v.is_int()) return (double)v.i;
	if (v.is_float()) return v.f;
	return NOT_FOUND~;
}

fn bool? obj_pair(Object* o, String key, sz* a, sz* b) @local {
	if (!o.has_key(key)) return false;
	Object* v = o.get(key)!;
	if (!v.is_array() || v.get_len() != 2) return false;
	Object* x = v.get_at(0);
	Object* y = v.get_at(1);
	if (!x.is_int() || !y.is_int()) return false;
	*a = (sz)x.i;
	*b = (sz)y.i;
	return true;
}

fn void ctl_handle(CtlClient* c, String line) @local {
	Object*? req = line.tparse_json();
	if (catch req) {
		ctl_error(c, "", "not JSON");
		return;
	}
	if (!req.is_map()) {
		ctl_error(c, "", "a request is a JSON object");
		return;
	}
	String id = "";
	if (req.has_key("id")) {
		Object* v = req.get("id")!!;
		if (v.is_int()) id = string::tformat("%d", v.i);
		if (v.is_string()) {
			DString q = dstring::temp();
			json_string(&q, v.s);
			id = q.str_view();
		}
	}
	// An input event is also the request that repeats it, so the events
	// one program sends can be piped into another's socket as they are.
	// Lines that are not requests are passed over: replies, and the
	// events no request repeats.
	String cmd;
	if (try name = obj_string(req, "cmd")) {
		cmd = name;
	} else if (try name = obj_string(req, "event")) {
		if (name == "frame") return;
		cmd = name;
	} else {
		if (!req.has_key("ok")) ctl_error(c, id, "no \"cmd\"");
		return;
	}
	switch (cmd) {
		case "ping": ctl_ok(c, id);
		case "tree": ctl_tree(c, id, req, true);
		case "find": ctl_tree(c, id, req, false);
		case "click":
		case "press":
		case "release":
		case "move": ctl_pointer(c, id, req, cmd);
		case "drag": ctl_drag(c, id, req);
		case "scroll": ctl_scroll(c, id, req);
		case "key": ctl_key(c, id, req);
		case "type": ctl_type(c, id, req);
		case "select": ctl_select_text(c, id, req);
		case "wait": ctl_wait(c, id, req);
		case "subscribe": ctl_subscribe(c, id, req, true);
		case "unsubscribe": ctl_subscribe(c, id, req, false);
		default: ctl_error(c, id, string::tformat("unknown cmd \"%s\"", cmd));
	}
}

// ── Snapshot ───────────────────────────────────────────────────────────────

fn CtlSpan ctl_span(String s) @local {
	CtlSpan sp = { .at = g_ctl.strs.len(), .len = s.len };
	g_ctl.strs.append_string(s);
	return sp;
}

fn String ctl_str(CtlSpan sp) @local => sp.len == 0 ? "" : g_ctl.strs.str_view()[sp.at:sp.len];

// control_on_draw records the frame just drawn, for selectors, and answers
// what was waiting on a frame. draw() calls it.
fn void control_on_draw(xray::Node* root, xray::ScreenBuffer* buf, sz repaint_ms) {
	if (!g_ctl.started) control_start();
	if (!g_ctl.on) return;
	g_ctl.nodes.clear();
	g_ctl.strs.clear();
	g_ctl.buf = buf;
	g_ctl.metrics = root.layout_metrics;
	g_ctl.repaint_ms = repaint_ms;
	g_ctl.frame++;
	ctl_record(root, -1);
	// A wait for frames needs frames drawn.
	foreach (&w : g_ctl.waits) {
		if (w.kind == FRAMES) frames_until(frame_ms() + 50);
	}
	foreach (c : g_ctl.clients) {
		if (!c.frame_events) continue;
		ctl_write(c, string::tformat("{\"event\":\"frame\",\"n\":%d}", g_ctl.frame));
	}
	@pool() {
		ctl_check_waits();
	};
}

fn void ctl_record(xray::Node* n, sz parent) @local {
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
	sz me = (sz)g_ctl.nodes.len();
	g_ctl.nodes.push(cn);
	for (sz i = 0; i < n.child_count; i++) ctl_record(n.children[i], me);
}

fn sz ctl_uw() @local => g_ctl.metrics.unit_w();
fn sz ctl_uh() @local => g_ctl.metrics.unit_h();

// ctl_cells is a rect in layout units as the cells its content is drawn
// on. In a window a node can start partway into a cell; its text is still
// drawn from the cell it starts in (see xray's content_cell_rect), so that
// is where the rect starts, and it is as many cells as its size rounds up
// to.
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
		// Trim the row's end.
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
	List{CtlAttr} attrs;
	bool focused;
	bool clickable;
	sz nth;
}

faultdef CTL_BAD_SELECTOR;

fn bool sel_word_char(char ch) @local {
	return ch.is_alnum() || ch == '_' || ch == '-' || ch == '.' || ch == '*';
}

// sel_parse turns a selector into its compounds, outermost first, on tmem.
fn List{CtlCompound}? sel_parse(String s) @local {
	List{CtlCompound} out;
	out.init(tmem);
	sz i = 0;
	while (i < s.len) {
		while (i < s.len && s[i] == ' ') i++;
		if (i >= s.len) break;
		CtlCompound c = { .nth = -1 };
		c.attrs.init(tmem);
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
					return CTL_BAD_SELECTOR~;
				}
				if (i >= s.len || s[i] != '"') return CTL_BAD_SELECTOR~;
				i++;
				DString v = dstring::temp();
				while (i < s.len && s[i] != '"') {
					if (s[i] == '\\' && i + 1 < s.len) i++;
					v.append_char(s[i]);
					i++;
				}
				if (i + 1 >= s.len || s[i + 1] != ']') return CTL_BAD_SELECTOR~;
				i += 2;
				a.value = v.str_view();
				c.attrs.push(a);
			} else {
				i++;
				sz ns = i;
				while (i < s.len && sel_word_char(s[i])) i++;
				String p = s[ns:i - ns];
				switch (p) {
					case "focused": c.focused = true;
					case "clickable": c.clickable = true;
					case "nth":
						if (i >= s.len || s[i] != '(') return CTL_BAD_SELECTOR~;
						i++;
						sz ds = i;
						while (i < s.len && s[i].is_digit()) i++;
						if (i >= s.len || s[i] != ')' || i == ds) return CTL_BAD_SELECTOR~;
						c.nth = (sz)(s[ds:i - ds].to_int() ?? 0);
						i++;
					default: return CTL_BAD_SELECTOR~;
				}
			}
		}
		if (i < s.len && s[i] != ' ') return CTL_BAD_SELECTOR~;
		out.push(c);
	}
	if (out.len() == 0) return CTL_BAD_SELECTOR~;
	return out;
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
	foreach (a : c.attrs) {
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

// select finds the nodes a selector matches in the last frame, in paint order.
fn List{sz}? ctl_select(String s) @local {
	List{CtlCompound} cs = sel_parse(s)!;
	List{sz} out;
	out.init(tmem);
	for (sz i = 0; i < g_ctl.nodes.len(); i++) {
		if (sel_matches(i, cs.array_view())) out.push(i);
	}
	sz nth = cs[cs.len() - 1].nth;
	if (nth >= 0) {
		List{sz} one;
		one.init(tmem);
		if (nth < out.len()) one.push(out[nth]);
		return one;
	}
	return out;
}

fn void json_field(DString* out, bool* first, String name) @local {
	if (!*first) out.append_char(',');
	*first = false;
	out.appendf("\"%s\":", name);
}

// ── tree / find ────────────────────────────────────────────────────────────

fn void ctl_node_json(DString* out, sz i, bool children, sz depth) @local {
	CtlNode* n = &g_ctl.nodes[i];
	out.append_char('{');
	bool first = true;
	if (n.id.len > 0) {
		json_field(out, &first, "id");
		json_string(out, ctl_str(n.id));
	}
	if (n.key.len > 0) {
		json_field(out, &first, "key");
		json_string(out, ctl_str(n.key));
	}
	if (n.role != NONE) {
		json_field(out, &first, "role");
		json_string(out, role_name(n.role));
	}
	if (n.type.len > 0) {
		json_field(out, &first, "type");
		json_string(out, ctl_str(n.type));
	}
	xray::Rect r = ctl_cells(n.rect);
	json_field(out, &first, "rect");
	out.appendf("[%d,%d,%d,%d]", r.x, r.y, r.w, r.h);
	if (n.clickable) {
		json_field(out, &first, "clickable");
		out.append_string("true");
	}
	if (n.focusable) {
		json_field(out, &first, "focusable");
		out.append_string("true");
	}
	if (n.focused) {
		json_field(out, &first, "focused");
		out.append_string("true");
	}
	bool leaf = n.child_count == 0;
	if (leaf || !children) {
		String text = ctl_text(i);
		if (text.len > 0) {
			json_field(out, &first, "text");
			json_string(out, text);
		}
	}
	if (children && !leaf && depth != 0) {
		json_field(out, &first, "children");
		out.append_char('[');
		bool more = false;
		for (sz j = i + 1; j < g_ctl.nodes.len(); j++) {
			if (g_ctl.nodes[j].parent != i) continue;
			if (more) out.append_char(',');
			more = true;
			ctl_node_json(out, j, true, depth - 1);
		}
		out.append_char(']');
	}
	out.append_char('}');
}

fn void ctl_tree(CtlClient* c, String id, Object* req, bool tree) @local {
	if (g_ctl.nodes.len() == 0) {
		ctl_error(c, id, "nothing drawn yet");
		return;
	}
	sz depth = (sz)(obj_number(req, "depth") ?? -1);
	List{sz} roots = {};
	if (try sel = obj_string(req, "target")) {
		List{sz}? found = ctl_select(sel);
		if (catch found) {
			ctl_error(c, id, string::tformat("bad selector: %s", sel));
			return;
		}
		roots = found;
	} else if (!tree) {
		ctl_error(c, id, "find needs \"target\"");
		return;
	} else {
		roots.init(tmem);
		roots.push(0);
	}
	DString out = ctl_reply(id);
	out.append_string(",\"nodes\":[");
	foreach (k, i : roots) {
		if (k > 0) out.append_char(',');
		ctl_node_json(&out, i, tree, depth);
	}
	out.append_char(']');
	ctl_send(c, &out);
}

// ── Input ──────────────────────────────────────────────────────────────────

// ctl_place works out where a request points, in layout units: a selector's
// first match (its middle, or a cell of its content), else a cell of the
// screen. It returns the error to report, or "" when it found a place.
fn String ctl_place(Object* o, sz* x, sz* y) @local {
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	sz col;
	sz row;
	bool has_at = (obj_pair(o, "at", &col, &row) ?? false);
	if (try sel = obj_string(o, "target")) {
		List{sz}? found = ctl_select(sel);
		if (catch found) return string::tformat("bad selector: %s", sel);
		if (found.len() == 0 && !has_at) return string::tformat("nothing matches %s", sel);
		if (found.len() > 0) {
			CtlNode* n = &g_ctl.nodes[found[0]];
			sz cc;
			sz cr;
			if (try has = obj_pair(o, "cell", &cc, &cr) && has) {
				*x = n.inner.x + cc * uw + uw / 2;
				*y = n.inner.y + cr * uh + uh / 2;
			} else {
				*x = n.rect.x + n.rect.w / 2;
				*y = n.rect.y + n.rect.h / 2;
			}
			return "";
		}
	}
	if (has_at) {
		// A negative place is outside the program, where a pointer that
		// left it is.
		if (col < 0 || row < 0) {
			*x = -1;
			*y = -1;
			return "";
		}
		*x = col * uw + uw / 2;
		*y = row * uh + uh / 2;
		return "";
	}
	return "say where: \"target\" or \"at\"";
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

fn void ctl_pointer(CtlClient* c, String id, Object* req, String cmd) @local {
	sz x;
	sz y;
	String err = ctl_place(req, &x, &y);
	if (err.len > 0) {
		ctl_error(c, id, err);
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
	ctl_ok(c, id);
}

fn void ctl_drag(CtlClient* c, String id, Object* req) @local {
	Object*? from = req.get("from");
	Object*? to = req.get("to");
	if (catch from) {
		ctl_error(c, id, "drag needs \"from\" and \"to\"");
		return;
	}
	if (catch to) {
		ctl_error(c, id, "drag needs \"from\" and \"to\"");
		return;
	}
	sz x0;
	sz y0;
	sz x1;
	sz y1;
	String err = ctl_place(from, &x0, &y0);
	if (err.len == 0) err = ctl_place(to, &x1, &y1);
	if (err.len > 0) {
		ctl_error(c, id, err);
		return;
	}
	ctl_inject(MOUSE_MOTION, x0, y0);
	ctl_inject(MOUSE_PRESS, x0, y0);
	ctl_inject(MOUSE_MOTION, x1, y1);
	ctl_inject(MOUSE_RELEASE, x1, y1);
	ctl_ok(c, id);
}

fn void ctl_scroll(CtlClient* c, String id, Object* req) @local {
	sz x = 0;
	sz y = 0;
	if (req.has_key("target") || req.has_key("at")) {
		String err = ctl_place(req, &x, &y);
		if (err.len > 0) {
			ctl_error(c, id, err);
			return;
		}
	} else {
		x = g_ctl.event_x;
		y = g_ctl.event_y;
	}
	double dy = obj_number(req, "dy") ?? 0;
	double dx = obj_number(req, "dx") ?? 0;
	if (g_ctl.hooks.scroll) {
		g_ctl.hooks.scroll(x, y, dx, dy);
	} else if (g_program != null) {
		// The terminal: a wheel notch per row.
		sz col = xray::floor_cell(x, ctl_uw());
		sz row = xray::floor_cell(y, ctl_uh());
		sz n = (sz)(dy < 0 ? -dy : dy);
		for (sz i = 0; i < n; i++) {
			MouseMsg m = { .action = MOUSE_PRESS, .button = dy < 0 ? MOUSE_WHEEL_UP : MOUSE_WHEEL_DOWN,
				.col = col, .row = row };
			g_program.send({ .kind = MsgKind.MOUSE, .mouse = m });
		}
	}
	ctl_ok(c, id);
}

fn KeyMsg? parse_key_spec(String spec) @local {
	KeyMsg k = { .code = RUNE };
	String[] parts = spec.tsplit("+");
	if (parts.len == 0) return NOT_FOUND~;
	// A lone "+" splits into two empty parts.
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
			// A control letter is a lowercase rune with ctrl, the way a
			// window reports it; ctrl+c has a code of its own.
			if (k.ctrl && k.rune >= 'A' && k.rune <= 'Z') k.rune += 'a' - 'A';
			if (k.ctrl && k.rune == 'c' && !k.alt && !k.shift && !k.super) {
				k.code = CTRL_C;
				k.rune = 0;
			}
	}
	return k;
}

fn void ctl_key(CtlClient* c, String id, Object* req) @local {
	String? spec = obj_string(req, "key");
	if (catch spec) {
		ctl_error(c, id, "key needs \"key\"");
		return;
	}
	KeyMsg? k = parse_key_spec(spec);
	if (catch k) {
		ctl_error(c, id, string::tformat("unknown key \"%s\"", spec));
		return;
	}
	if (g_program != null) g_program.send({ .kind = MsgKind.KEY, .key = k });
	ctl_ok(c, id);
}

fn void ctl_type(CtlClient* c, String id, Object* req) @local {
	String? text = obj_string(req, "text");
	if (catch text) {
		ctl_error(c, id, "type needs \"text\"");
		return;
	}
	Char32[]? runes = text.to_temp_utf32();
	if (catch runes) {
		ctl_error(c, id, "text is not UTF-8");
		return;
	}
	if (g_program != null) {
		foreach (r : runes) {
			KeyMsg k = r == '\n' ? (KeyMsg){ .code = ENTER } : (KeyMsg){ .code = RUNE, .rune = r };
			g_program.send({ .kind = MsgKind.KEY, .key = k });
		}
	}
	ctl_ok(c, id);
}

// ctl_queued is whether input sent to the program is still waiting to be
// handled.
fn bool ctl_queued() @local {
	if (g_program == null) return false;
	g_program.send_mu.lock();
	bool queued = g_program.send_head != g_program.send_tail;
	g_program.send_mu.unlock();
	return queued;
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
// right half of a wide character is passed over.
fn CtlScreenText ctl_screen_text(sz i) @local {
	CtlScreenText st;
	xray::ScreenBuffer* b = g_ctl.buf;
	if (b == null) return st;
	xray::Rect r = ctl_cells(g_ctl.nodes[i].rect);
	DString out = dstring::temp();
	List{sz} cols;
	List{sz} rows;
	cols.init(tmem);
	rows.init(tmem);
	for (sz y = math::max(r.y, (sz)0); y < r.y + r.h && y < b.height; y++) {
		if (out.len() > 0) {
			out.append_char('\n');
			cols.push(r.x + r.w);
			rows.push(y - 1);
		}
		bool wide = false;
		for (sz x = math::max(r.x, (sz)0); x < r.x + r.w && x < b.width; x++) {
			xray::Cell* cell = &b.cells[y * b.width + x];
			String s = cell.content_len > 0 ? (String)cell.content[:cell.content_len] : (wide ? "" : " ");
			wide = cell.width == 2;
			out.append_string(s);
			for (sz k = 0; k < s.len; k++) {
				cols.push(x);
				rows.push(y);
			}
		}
	}
	st.text = out.str_view();
	st.col = cols.array_view();
	st.row = rows.array_view();
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
fn void ctl_select_text(CtlClient* c, String id, Object* req) @local {
	String? sel = obj_string(req, "target");
	if (catch sel) {
		ctl_error(c, id, "select needs \"target\"");
		return;
	}
	List{sz}? found = ctl_select(sel);
	if (catch found) {
		ctl_error(c, id, string::tformat("bad selector: %s", sel));
		return;
	}
	if (found.len() == 0) {
		ctl_error(c, id, string::tformat("nothing matches %s", sel));
		return;
	}
	CtlScreenText st = ctl_screen_text(found[0]);
	sz nth = (sz)(obj_number(req, "nth") ?? 0);
	sz start;
	sz end;
	if (try text = obj_string(req, "text")) {
		sz? at = ctl_occurrence(st.text, text, nth);
		if (catch at) {
			ctl_error(c, id, "no such text on screen");
			return;
		}
		start = at;
		end = at + text.len;
	} else if (try pattern = obj_string(req, "match")) {
		Regex? re = regex::compile(mem, pattern, EXTENDED | NEWLINE);
		if (catch re) {
			ctl_error(c, id, string::tformat("bad pattern: %s", pattern));
			return;
		}
		defer re.free();
		Match[] all = re.tfind_all(st.text) ?? {};
		// An empty match selects nothing.
		List{Match} some;
		some.init(tmem);
		foreach (m : all) if (m.end > m.start) some.push(m);
		if (nth < 0 || nth >= some.len()) {
			ctl_error(c, id, "no match on screen");
			return;
		}
		start = some[nth].start;
		end = some[nth].end;
	} else {
		ctl_error(c, id, "select needs \"text\" or \"match\"");
		return;
	}
	if (end <= start) {
		ctl_error(c, id, "nothing to select");
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
	DString out = ctl_reply(id);
	out.append_string(",\"text\":");
	json_string(&out, st.text[start:end - start]);
	ctl_send(c, &out);
}

// ── wait ───────────────────────────────────────────────────────────────────

fn void ctl_wait(CtlClient* c, String id, Object* req) @local {
	CtlWait w = { .client = c, .id = id.copy(mem), .frames = g_ctl.frame, .since_ms = time_ms() };
	sz timeout = (sz)(obj_number(req, "timeout_ms") ?? 5000);
	w.deadline_ms = time_ms() + timeout;
	if (try frames = obj_number(req, "frames")) {
		w.kind = FRAMES;
		w.frames = g_ctl.frame + (sz)frames;
	} else if (try sel = obj_string(req, "target")) {
		if (catch sel_parse(sel)) {
			ctl_error(c, id, string::tformat("bad selector: %s", sel));
			w.id.free(mem);
			return;
		}
		w.kind = TARGET;
		w.target = sel.copy(mem);
	} else {
		w.kind = IDLE;
	}
	g_ctl.waits.push(w);
	if (w.kind == FRAMES) frames_until(frame_ms() + 50);
}

// ctl_idle is whether the program has settled since w was asked for: no
// input waiting, no animation running (a caret's blink is not one), and a
// frame drawn since, unless there was nothing to draw.
fn bool ctl_idle(CtlWait* w) @local {
	if (g_program == null) return true;
	if (ctl_queued()) return false;
	if (g_ctl.repaint_ms > 0 && g_ctl.repaint_ms < 100) return false;
	if (g_program.frames_until_ms > time_ms()) return false;
	return g_ctl.frame > w.frames || time_ms() >= w.since_ms + 100;
}

fn void ctl_check_waits() @local {
	for (sz i = 0; i < g_ctl.waits.len(); ) {
		CtlWait* w = &g_ctl.waits[i];
		bool done = false;
		bool timed_out = time_ms() >= w.deadline_ms;
		switch (w.kind) {
			case FRAMES: done = g_ctl.frame >= w.frames;
			case IDLE: done = ctl_idle(w);
			case TARGET:
				if (try found = ctl_select(w.target)) done = found.len() > 0;
		}
		if (!done && !timed_out) {
			i++;
			continue;
		}
		if (done) {
			ctl_ok(w.client, w.id);
		} else {
			ctl_error(w.client, w.id, "timed out");
		}
		ctl_free_wait(w);
		g_ctl.waits.remove_at(i);
	}
}

// ── Events ─────────────────────────────────────────────────────────────────

fn void ctl_subscribe(CtlClient* c, String id, Object* req, bool on) @local {
	bool input = !on;
	bool frame = !on;
	if (req.has_key("events")) {
		Object* evs = req.get("events")!!;
		if (evs.is_array()) {
			for (sz i = 0; i < evs.get_len(); i++) {
				Object* e = evs.get_at(i);
				if (!e.is_string()) continue;
				if (e.s == "input") input = true;
				if (e.s == "frame") frame = true;
			}
		}
	} else {
		input = true;
		frame = !on;
	}
	if (input) c.input_events = on;
	if (frame) c.frame_events = on;
	ctl_ok(c, id);
}

fn bool ctl_listening() @local {
	if (!g_ctl.on) return false;
	foreach (c : g_ctl.clients) if (c.input_events && !c.closed) return true;
	return false;
}

// ctl_target is the node a pointer at (x, y) is over: the topmost one that
// reacts to the pointer, else -1.
fn sz ctl_target(sz x, sz y) @local {
	for (sz i = (sz)g_ctl.nodes.len() - 1; i >= 0; i--) {
		CtlNode* n = &g_ctl.nodes[i];
		if (n.interactive && n.rect.contains(x, y)) return i;
	}
	return -1;
}

// ctl_describe is a selector that finds node i again, in this frame or in
// another program's copy of the same tree: the node by id, role or type, its
// key, or failing those its text, inside its nearest named ancestor, with
// :nth when that still matches more than one.
fn String ctl_describe(sz i) @local {
	DString s = dstring::temp();
	sz p = g_ctl.nodes[i].parent;
	while (p >= 0 && g_ctl.nodes[p].id.len == 0) p = g_ctl.nodes[p].parent;
	if (p >= 0) {
		s.append_string(ctl_str(g_ctl.nodes[p].id));
		s.append_char(' ');
	}
	CtlNode* n = &g_ctl.nodes[i];
	if (n.id.len > 0) {
		s.append_string(ctl_str(n.id));
	} else if (n.role != NONE) {
		s.append_string(role_name(n.role));
	} else if (n.type.len > 0) {
		s.append_string(ctl_str(n.type));
	} else {
		s.append_char('*');
	}
	if (n.key.len > 0) {
		s.append_string("[key=");
		json_string(&s, ctl_str(n.key));
		s.append_char(']');
	} else if (n.id.len == 0) {
		String text = ctl_text(i).trim();
		if (text.len > 0 && text.len <= 60 && !text.contains("\n")) {
			s.append_string("[text=");
			json_string(&s, text);
			s.append_char(']');
		}
	}
	String sel = s.str_view();
	List{sz}? found = ctl_select(sel);
	if (try found && found.len() > 1) {
		foreach (k, j : found) {
			if (j == i) return string::tformat("%s:nth(%d)", sel, k);
		}
	}
	return sel;
}

fn void ctl_emit(String json) @local {
	foreach (c : g_ctl.clients) {
		if (c.input_events) ctl_write(c, json);
	}
}

// ctl_where adds an event's place, as a request takes it: the target the
// pointer is over and the cell within it, when there is one, and the cell
// of the screen, [-1, -1] outside the program.
fn void ctl_where(DString* out, sz x, sz y) @local {
	sz uw = ctl_uw();
	sz uh = ctl_uh();
	if (x < 0 || y < 0) {
		out.append_string(",\"at\":[-1,-1]");
		return;
	}
	sz t = ctl_target(x, y);
	if (t >= 0) {
		CtlNode* n = &g_ctl.nodes[t];
		out.append_string(",\"target\":");
		json_string(out, ctl_describe(t));
		sz lc = xray::floor_cell(x - n.inner.x, uw);
		sz lr = xray::floor_cell(y - n.inner.y, uh);
		out.appendf(",\"cell\":[%d,%d]", lc, lr);
	}
	out.appendf(",\"at\":[%d,%d]", xray::floor_cell(x, uw), xray::floor_cell(y, uh));
}

// control_pointer_event tells subscribers about pointer input: "press",
// "release" or "move", at (x, y) in layout units, (-2, -2) for where it last
// was. dispatch_click, end_drag and dispatch_hover call it, which both
// backends go through.
fn void control_pointer_event(String type, sz x, sz y) {
	if (!ctl_listening()) return;
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
		out.appendf("{\"event\":\"%s\"", type);
		ctl_where(&out, x, y);
		out.append_char('}');
		ctl_emit(out.str_view());
	};
}

// control_msg_event tells subscribers about the input that arrives as a
// message: keys, and the wheel. Both backends' dispatch call it.
fn void control_msg_event(Msg m) {
	if (!ctl_listening()) return;
	@pool() {
		DString out = dstring::temp();
		if (m.kind == MsgKind.KEY && m.key.action != KeyAction.KEY_RELEASE) {
			out.append_string("{\"event\":\"key\",\"key\":");
			json_string(&out, key_spec(m.key));
			out.append_char('}');
			ctl_emit(out.str_view());
			return;
		}
		if (m.kind != MsgKind.MOUSE || m.mouse.action != MOUSE_PRESS) return;
		int notch = m.mouse.button == MOUSE_WHEEL_DOWN ? 1 : m.mouse.button == MOUSE_WHEEL_UP ? -1 : 0;
		if (notch == 0) return;
		// Rows, positive towards the end: a window's real distance, else a
		// notch.
		double dy = notch;
		double dx = 0;
		if (m.mouse.scroll_dy != 0 || m.mouse.scroll_dx != 0) {
			dy = -(double)m.mouse.scroll_dy / (double)ctl_uh();
			dx = -(double)m.mouse.scroll_dx / (double)ctl_uw();
		}
		out.appendf("{\"event\":\"scroll\",\"dy\":%.2f", dy);
		if (dx != 0) out.appendf(",\"dx\":%.2f", dx);
		// In a terminal the message says where the wheel turned, in cells,
		// which are its layout units; a window has moved the pointer there
		// first.
		if (g_ctl.hooks.pointer) {
			ctl_where(&out, g_ctl.event_x, g_ctl.event_y);
		} else {
			ctl_where(&out, m.mouse.col, m.mouse.row);
		}
		out.append_char('}');
		ctl_emit(out.str_view());
	};
}

// key_spec writes a key the way parse_key reads it.
fn String key_spec(KeyMsg k) {
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

// ── Client ─────────────────────────────────────────────────────────────────

// control_client is a client for a program's control socket, for a main to
// run on `app ctl ...`. args are what follows "ctl":
//
//   ctl SOCK                      requests on stdin, a line each; replies and
//                                 events on stdout, until stdin ends
//   ctl SOCK REQUEST...           each request in turn, printing its reply
//
// A REQUEST is a JSON object, or a command and its arguments as words:
// `tree`, `find TARGET`, `click TARGET`, `key ctrl+b`, `type TEXT`,
// `select TARGET TEXT` (or `/PATTERN/`), `wait TARGET`, `wait idle`,
// `subscribe`. After a subscribe it prints events until the program ends.
// Returns the exit status: 1 if a request failed.
fn int control_client(String[] args) {
	if (args.len == 0) {
		ctl_complain("usage: ctl SOCKET [REQUEST...]");
		return 2;
	}
	CtlAddr a;
	if (!ctl_addr(&a, args[0])) {
		ctl_complain("ctl: socket path too long: %s", args[0]);
		return 2;
	}
	os::NativeSocket fd = os::socket(os::AF_UNIX, os::SOCK_STREAM, (os::AIProtocol)0);
	if ((CInt)fd < 0 || os::connect(fd, (os::SockAddrPtr)&a, (os::Socklen_t)CtlAddr::size) != 0) {
		ctl_complain("ctl: cannot connect to %s: %s", args[0], libc::strerror(libc::errno()));
		return 2;
	}
	defer (void)libc::close((CInt)fd);
	if (args.len == 1) return ctl_client_pipe(fd);
	int status = 0;
	DString pending;
	pending.init(mem);
	defer pending.free();
	for (sz i = 1; i < args.len; ) {
		@pool() {
			String req = args[i++];
			bool stream = req.contains("\"subscribe\"");
			if (!req.starts_with("{")) {
				String cmd = req;
				String arg = "";
				String arg2 = "";
				if (ctl_takes_arg(cmd) && i < args.len && !args[i].starts_with("{")) arg = args[i++];
				if (cmd == "select" && i < args.len) arg2 = args[i++];
				req = ctl_shorthand(cmd, arg, arg2);
				stream = cmd == "subscribe";
			}
			String reply = ctl_call(fd, &pending, req);
			if (reply.len == 0) {
				ctl_complain("ctl: the program closed the socket");
				status = 1;
				break;
			}
			io::printn(reply);
			if (reply.contains("\"ok\":false")) status = 1;
			// After a subscribe, the events, until the program ends.
			while (stream) {
				String? ev = ctl_read_line(fd, &pending);
				if (catch ev) break;
				io::printn(ev);
				(void)io::stdout().flush();
			}
		};
	}
	return status;
}

fn bool ctl_takes_arg(String cmd) @local {
	switch (cmd) {
		case "find":
		case "click":
		case "press":
		case "release":
		case "move":
		case "key":
		case "type":
		case "wait":
		case "scroll":
		case "select":
			return true;
		default:
			return false;
	}
}

// ctl_shorthand makes a request of a command and its argument, or for
// select its two: the target, and the text, or a pattern between slashes.
fn String ctl_shorthand(String cmd, String arg, String arg2) @local {
	DString s = dstring::temp();
	s.append_string("{\"cmd\":");
	json_string(&s, cmd);
	switch (cmd) {
		case "key":
			s.append_string(",\"key\":");
			json_string(&s, arg);
		case "type":
			s.append_string(",\"text\":");
			json_string(&s, arg);
		case "scroll":
			// A number of rows, or where: a selector, one row down.
			if (arg.len > 0 && (arg[0].is_digit() || arg[0] == '-')) {
				s.appendf(",\"dy\":%s", arg);
			} else {
				s.append_string(",\"dy\":1");
				if (arg.len > 0) {
					s.append_string(",\"target\":");
					json_string(&s, arg);
				}
			}
		case "select":
			s.append_string(",\"target\":");
			json_string(&s, arg);
			if (arg2.len >= 2 && arg2.starts_with("/") && arg2.ends_with("/")) {
				s.append_string(",\"match\":");
				json_string(&s, arg2[1:arg2.len - 2]);
			} else {
				s.append_string(",\"text\":");
				json_string(&s, arg2);
			}
		case "wait":
			if (arg == "idle" || arg.len == 0) break;
			if (arg[0].is_digit()) {
				s.appendf(",\"frames\":%s", arg);
			} else {
				s.append_string(",\"target\":");
				json_string(&s, arg);
			}
		default:
			if (arg.len == 0) break;
			s.append_string(",\"target\":");
			json_string(&s, arg);
	}
	s.append_char('}');
	return s.str_view();
}

// ctl_call sends a request, as request 1, and returns its reply, skipping
// events; "" when the socket closed.
fn String ctl_call(os::NativeSocket fd, DString* pending, String req) @local {
	Object*? o = req.tparse_json();
	if (catch o) return "{\"ok\":false,\"error\":\"not JSON\"}";
	if (!o.is_map()) return "{\"ok\":false,\"error\":\"a request is a JSON object\"}";
	// The id is set on the way out: the request without its last brace,
	// then the id.
	String body = req.trim();
	String line = string::tformat("%s%s\"id\":1}\n", body[:body.len - 1], o.get_len() > 0 ? "," : "");
	if (!ctl_write_all(fd, line)) return "";
	for (;;) {
		String? got = ctl_read_line(fd, pending);
		if (catch got) return "";
		if (got.starts_with("{\"event\"")) continue;
		return got;
	}
}

fn bool ctl_write_all(os::NativeSocket fd, String s) @local {
	while (s.len > 0) {
		sz n = libc::write((Fd)fd, s.ptr, s.len);
		if (n <= 0) return false;
		s = s[n..];
	}
	return true;
}

// ctl_read_line reads the next line from fd, on tmem.
fn String? ctl_read_line(os::NativeSocket fd, DString* pending) @local {
	for (;;) {
		String have = pending.str_view();
		if (try nl = have.index_of_char('\n')) {
			String line = have[:nl].tcopy();
			pending.delete(0, nl + 1);
			return line;
		}
		char[4096] chunk;
		sz n = libc::read((Fd)fd, &chunk, chunk.len);
		if (n <= 0) return io::EOF~;
		pending.append_bytes(chunk[:n]);
	}
}

// ctl_client_pipe copies stdin to the socket and the socket to stdout, a
// line at a time, until stdin ends and every request has its reply, or,
// after a subscribe, until the socket closes.
fn int ctl_client_pipe(os::NativeSocket fd) @local {
	os::Posix_pollfd[2] fds = { { .fd = 0, .events = os::POLLIN }, { .fd = (CInt)fd, .events = os::POLLIN } };
	bool stdin_open = true;
	bool subscribed = false;
	sz waiting = 0;
	char[4096] chunk;
	DString in;
	in.init(mem);
	defer in.free();
	for (;;) {
		if (!stdin_open && waiting <= 0 && !subscribed) return 0;
		fds[0].fd = stdin_open ? 0 : -1;
		if (os::poll(&fds, 2, -1) < 0) return 1;
		if (fds[1].revents != 0) {
			sz n = libc::read((Fd)fd, &chunk, chunk.len);
			if (n <= 0) return 0;
			io::stdout().write(chunk[:n])!!;
			(void)io::stdout().flush();
			// Each reply line that is not an event answers one request.
			foreach (ch : chunk[:n]) if (ch == '\n') waiting--;
			waiting += ctl_count_events(chunk[:n]);
		}
		if (stdin_open && fds[0].revents != 0) {
			sz n = libc::read(0, &chunk, chunk.len);
			if (n <= 0) {
				stdin_open = false;
				continue;
			}
			foreach (ch : chunk[:n]) if (ch == '\n') waiting++;
			if (((String)chunk[:n]).contains("\"subscribe\"")) subscribed = true;
			if (!ctl_write_all(fd, (String)chunk[:n])) return 1;
		}
	}
}

fn sz ctl_count_events(char[] s) @local {
	sz count = 0;
	String text = (String)s;
	while (try at = text.index_of("{\"event\"")) {
		count++;
		text = text[at + 1..];
	}
	return count;
}
