module milktea;

import std::io;
import glaze;
import std::core::dstring;
import std::core::string;

// A running program takes commands from other processes through a named
// pipe, and the same binary is the client that sends them:
//
//   MILKTEA_CONTROL=1 ted         the running program listens
//   ted --cmd click save          another process sends it one command
//   ted --cmd screen              prints the reply, exits 0 on ok, 1 on err
//
// A program not started that way can still be driven, once whoever is at it
// allows it: --cmd leaves a request, the program asks on screen (see
// control_remote.c3), and on "yes" opens its pipe. MILKTEA_CONTROL=0 makes a
// program that cannot be driven or asked.
//
// Everything lives in a directory only the user can enter,
// <tmp>/milktea-<uid>/:
//
//   <name>.pid        a link whose target is the pid of the most recently
//                     started <name>, which is where --cmd sends unless
//                     MILKTEA_PID names another
//   <name>.<pid>      that program's command pipe, once it listens
//   <name>.<pid>.ask  a request to be allowed, made by --cmd and removed
//                     by the program when it is answered
//
// Each --cmd makes a pipe of its own for the reply and names it in front of
// the command, so any number can ask at once.

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
extern fn int access(char* path, int mode) @local;

const int O_WRONLY @local = 1;
const int O_RDWR @local = 2;
const int O_NONBLOCK @local = env::LINUX ? 0x800 : 0x4;
const int O_CREAT @local = env::LINUX ? 0x40 : 0x200;
const int SIGPIPE @local = 13;
const short POLLOUT @local = 4;
const short POLLERR @local = 8;
const short POLLHUP @local = 16;

// Short writes to a pipe arrive whole, so two clients' lines never mix. This
// is the smallest such size any system promises.
const sz PIPE_LINE_MAX @local = 512;
// How long --cmd waits for its answer, and for a person to allow it.
const int CLIENT_WAIT_MS @local = 5000;
const int CLIENT_ASK_MS @local = 60000;
// What starts the last line of a reply to --cmd, so a line of the screen
// that reads "ok" does not end it.
const char REPLY_END = '\x1e';

// ── The program's own command line ─────────────────────────────────────────

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
		if (n <= 0) return {};
		sz count = 0;
		for (sz i = 0; i < n; i++) if (buf[i] == 0) count++;
		String[] out = mem::talloc_array(String, count);
		sz start = 0;
		sz k = 0;
		for (sz i = 0; i < n; i++) {
			if (buf[i] != 0) continue;
			out[k++] = (String)buf[start:i - start];
			start = i + 1;
		}
		return out;
	$default:
		return {};
	$endswitch
}

fn String base_name(String path) @local {
	for (sz i = path.len - 1; i >= 0; i--) {
		if (path[i] == '/') return path[i + 1..];
	}
	return path;
}

// pipe_dir is the directory the pipes live in, on tmem.
fn String pipe_dir() @local {
	String tmp = "/tmp";
	char* t = getenv("TMPDIR");
	if (t != null && ((ZString)t).len() > 0) tmp = ((ZString)t).str_view();
	while (tmp.len > 1 && tmp[^1] == '/') tmp = tmp[:^1];
	return string::tformat("%s/milktea-%d", tmp, getuid());
}

// ── The running program's side ─────────────────────────────────────────────

struct ControlPipe @local {
	int fd;
	bool open;
	// The program has said where it is, so it can be asked (control_announce).
	bool announced;
	ZString path;
	ZString link;
	ZString target;
	ZString ask;
	// The directory and a slash: a reply pipe must be inside it.
	String prefix;
}

ControlPipe g_pipe @local;

// control_pipe_wanted says whether the program was started to listen at
// once, and control_pipe_refused whether it was started never to.
fn bool control_pipe_wanted() {
	char* v = getenv("MILKTEA_CONTROL");
	if (v == null) return false;
	String s = ((ZString)v).str_view();
	return s.len > 0 && s != "0";
}

fn bool control_pipe_refused() @local {
	char* v = getenv("MILKTEA_CONTROL");
	return v != null && ((ZString)v).str_view() == "0";
}

// control_announce says where the program is, by pointing <name>.pid at it,
// so that --cmd can find it: to send to, or to ask. Backends call it as
// they start.
fn void control_announce() {
	if (g_pipe.announced || control_pipe_refused()) return;
	@pool() {
		String[] args = program_args();
		if (args.len == 0) return;
		String name = base_name(args[0]);
		String dir = pipe_dir();
		mkdir(dir.zstr_tcopy(), 0o700);
		g_pipe.target = string::format(mem, "%d", getpid()).zstr_copy(mem);
		g_pipe.path = string::format(mem, "%s/%s.%d", dir, name, getpid()).zstr_copy(mem);
		g_pipe.ask = string::format(mem, "%s/%s.%d.ask", dir, name, getpid()).zstr_copy(mem);
		g_pipe.link = string::format(mem, "%s/%s.pid", dir, name).zstr_copy(mem);
		g_pipe.prefix = string::format(mem, "%s/", dir);
		unlink(g_pipe.ask);
		unlink(g_pipe.link);
		if (symlink(g_pipe.target, g_pipe.link) != 0) return;
		atexit(&control_pipe_close);
		g_pipe.announced = true;
	};
}

// control_ask_possible: the program can be asked. control_ask_pending: it
// is being asked now. control_ask_done: the request has its answer, and
// going is how --cmd hears of it.
fn bool control_ask_possible() @private => g_pipe.announced;
fn bool control_ask_pending() @private => g_pipe.announced && access(g_pipe.ask, 0) == 0;
fn void control_ask_done() @private {
	if (g_pipe.announced) unlink(g_pipe.ask);
}

// control_pipe_open makes the program's command pipe. Returns false, and
// the program runs on without one, when it cannot.
fn bool control_pipe_open() {
	if (g_pipe.open) return true;
	if (!g_pipe.announced) return false;
	unlink(g_pipe.path);
	if (mkfifo(g_pipe.path, 0o600) != 0) return false;
	// Open for reading and writing, so the pipe never reads as ended when a
	// client goes away, and opening does not wait for one.
	g_pipe.fd = open(g_pipe.path, O_RDWR | O_NONBLOCK);
	if (g_pipe.fd < 0) {
		unlink(g_pipe.path);
		return false;
	}
	// A client that goes away mid-reply must not take the program with it.
	signal(SIGPIPE, (void*)(uptr)1);
	g_pipe.open = true;
	return true;
}

fn int control_pipe_fd() => g_pipe.open ? g_pipe.fd : -1;

// control_pipe_close removes what the program left in the directory. The
// link goes only if it still points here: a program started later has taken
// it over.
fn void control_pipe_close() {
	if (!g_pipe.announced) return;
	g_pipe.announced = false;
	char[32] buf;
	sz n = readlink(g_pipe.link, &buf, buf.len);
	if (n > 0 && (String)buf[:n] == g_pipe.target.str_view()) unlink(g_pipe.link);
	unlink(g_pipe.ask);
	if (!g_pipe.open) return;
	g_pipe.open = false;
	close(g_pipe.fd);
	unlink(g_pipe.path);
}

// control_reply_open opens the pipe a client named for its reply, or -1. The
// client holds it open before it asks, so this does not wait.
fn int control_reply_open(String path) @private {
	if (!g_pipe.open || !path.starts_with(g_pipe.prefix) || path[g_pipe.prefix.len..].contains("/")) return -1;
	@pool() {
		return open(path.zstr_tcopy(), O_WRONLY | O_NONBLOCK);
	};
}

fn void control_reply_close(int fd) @private {
	close(fd);
}

// control_write writes all of s, waiting a while for a reader that has
// fallen behind and giving up on one that has gone.
fn void control_write(int fd, String s) @private {
	sz off = 0;
	for (int tries = 0; off < s.len && tries < 64; tries++) {
		sz n = write(fd, s.ptr + off, s.len - off);
		if (n > 0) {
			off += n;
			continue;
		}
		PollFd p = { .fd = fd, .events = POLLOUT };
		if (poll(&p, 1, 1000) <= 0 || (p.revents & (POLLERR | POLLHUP)) != 0) return;
	}
}

// ── The client: <program> --cmd ... ────────────────────────────────────────

// A client prints in colour only in --repl on a terminal.
bool g_client_color @local;

struct ClientTarget @local {
	String name;
	String dir;
	ZString target;
}

// client_connect finds the program to drive and, when it is not taking
// commands yet, asks whoever is at it to allow that, waiting for the answer.
// It exits when there is no program or the answer is no.
fn ClientTarget client_connect(String name) @local {
	ClientTarget t = { .name = name, .dir = pipe_dir() };
	// Which program: the one MILKTEA_PID names, else the most recently
	// started, whose pid the link holds.
	String pid;
	char* named = getenv("MILKTEA_PID");
	if (named != null && ((ZString)named).len() > 0) {
		pid = ((ZString)named).str_view();
	} else {
		char[] buf = mem::talloc_array(char, 32);
		sz n = readlink(string::tformat("%s/%s.pid", t.dir, name).zstr_tcopy(), buf.ptr, buf.len);
		if (n > 0) pid = (String)buf[:n];
	}
	int pid_no = pid.to_int() ?? 0;
	if (pid_no <= 0 || kill(pid_no, 0) != 0) {
		io::eprintfn("%s: no %s is running that can be driven", name, name);
		exit(1);
	}
	t.target = string::tformat("%s/%s.%s", t.dir, name, pid).zstr_tcopy();
	// With nobody reading the pipe this fails, so a program that is not
	// listening is told apart from one that is.
	int to = open(t.target, O_WRONLY | O_NONBLOCK);
	if (to < 0) {
		// Not listening: ask. The request is a file the program removes when
		// it is answered, having opened its pipe first if the answer was yes.
		ZString ask = string::tformat("%s/%s.%s.ask", t.dir, name, pid).zstr_tcopy();
		int made = open(ask, O_CREAT | O_WRONLY, 0o600);
		if (made < 0) {
			io::eprintfn("%s: cannot ask %s to be driven", name, name);
			exit(1);
		}
		close(made);
		io::eprintfn("%s: asked for remote control; answer in the program", name);
		for (int waited = 0; to < 0; waited += 50) {
			if (waited >= CLIENT_ASK_MS || kill(pid_no, 0) != 0) {
				unlink(ask);
				io::eprintfn("%s: no answer", name);
				exit(1);
			}
			poll(null, 0, 50);
			to = open(t.target, O_WRONLY | O_NONBLOCK);
			if (to < 0 && access(ask, 0) != 0) {
				// Answered, and the pipe is opened before the request goes,
				// so one more look settles it.
				to = open(t.target, O_WRONLY | O_NONBLOCK);
				if (to >= 0) break;
				io::eprintfn("%s: remote control was refused", name);
				exit(1);
			}
		}
	}
	close(to);
	return t;
}

// client_last prints the line that ends a reply, green for ok, red for err.
fn void client_last(String line) @local {
	String out = line;
	if (g_client_color) out = glaze::style().with_fg(line.starts_with("err") ? "#ff5f5f" : "#5fd787").render(line);
	(void)write(STDOUT_FILENO, out.ptr, out.len);
	(void)write(STDOUT_FILENO, "\n", 1);
}

// client_send sends one command and prints the reply. Returns 0 for ok, 1
// for err or a failure to get an answer, 2 for a command too long.
fn int client_send(ClientTarget* t, String cmd) @local {
	int to = open(t.target, O_WRONLY | O_NONBLOCK);
	if (to < 0) {
		io::eprintfn("%s: no longer taking commands", t.name);
		return 1;
	}
	ZString reply = string::tformat("%s/.reply.%d", t.dir, getpid()).zstr_tcopy();
	unlink(reply);
	int from = mkfifo(reply, 0o600) == 0 ? open(reply, O_RDWR) : -1;
	if (from < 0) {
		close(to);
		io::eprintfn("%s: cannot make a pipe for the reply", t.name);
		return 1;
	}
	String line = string::tformat(">%s\t%s\n", reply, cmd);
	if (line.len > PIPE_LINE_MAX) {
		close(to);
		close(from);
		unlink(reply);
		io::eprintfn("%s: command too long", t.name);
		return 2;
	}
	(void)write(to, line.ptr, line.len);
	close(to);

	DString got = dstring::temp();
	int code = 1;
	for (bool done = false; !done;) {
		PollFd p = { .fd = from, .events = POLLIN };
		if (poll(&p, 1, CLIENT_WAIT_MS) <= 0) {
			io::eprintfn("%s: no answer", t.name);
			break;
		}
		char[1024] chunk;
		sz n = read(from, &chunk, chunk.len);
		if (n <= 0) continue;
		got.append_bytes(chunk[:n]);
		for (;;) {
			String s = got.str_view();
			sz? nl = s.index_of_char('\n');
			if (catch nl) break;
			if (s[0] == REPLY_END) {
				String last = s[1:nl - 1];
				client_last(last);
				code = last.starts_with("err") ? 1 : 0;
				done = true;
				break;
			}
			(void)write(STDOUT_FILENO, s.ptr, nl + 1);
			got.delete(0, nl + 1);
		}
	}
	close(from);
	unlink(reply);
	return code;
}

// client_repl reads commands a line at a time and sends each one. It asks
// to be allowed first, so the prompt appears once the program has said yes.
// It ends at the end of input, at "exit", or when the program is told to quit.
fn int client_repl(String name) @local {
	ClientTarget t = client_connect(name);
	bool tty = isatty(STDIN_FILENO) != 0;
	g_client_color = isatty(STDOUT_FILENO) != 0 && getenv("NO_COLOR") == null;
	String prompt = g_client_color ? glaze::style().with_fg("#5fd7ff").render("> ") : "> ";
	DString buf = dstring::temp();
	bool eof = false;
	for (;;) {
		if (tty) (void)write(STDOUT_FILENO, prompt.ptr, prompt.len);
		// Read until a whole line is in, or there is no more.
		sz at = -1;
		for (;;) {
			sz? nl = buf.str_view().index_of_char('\n');
			if (try found = nl) {
				at = found;
				break;
			}
			if (eof) break;
			char[1024] chunk;
			sz n = read(STDIN_FILENO, &chunk, chunk.len);
			if (n <= 0) {
				eof = true;
			} else {
				buf.append_bytes(chunk[:n]);
			}
		}
		String line;
		if (at >= 0) {
			line = buf.str_view()[:at].tcopy();
			buf.delete(0, at + 1);
		} else {
			// The end of input, with perhaps a last line that had no newline.
			line = buf.str_view().tcopy();
			buf.clear();
			if (line.trim().len == 0) return 0;
		}
		line = line.trim();
		if (line.len == 0) continue;
		if (line == "exit") return 0;
		client_send(&t, line);
		if (line == "quit") return 0;
	}
}

// control_client is the whole of a run that was given --cmd or --repl: it
// sends commands to the running program, prints the replies and exits. Any
// other run returns from it at once. run() calls it before it touches the
// terminal.
fn void control_client() {
	@pool() {
		String[] args = program_args();
		sz at = -1;
		bool repl = false;
		for (sz i = 1; i < args.len; i++) {
			if (args[i] == "--cmd" || args[i] == "--repl") {
				at = i;
				repl = args[i] == "--repl";
				break;
			}
		}
		if (at < 0) return;
		String name = base_name(args[0]);
		if (repl) exit(client_repl(name));
		DString cmd = dstring::temp();
		for (sz i = at + 1; i < args.len; i++) {
			if (cmd.len() > 0) cmd.append_char(' ');
			cmd.append_string(args[i]);
		}
		if (cmd.len() == 0) {
			io::eprintfn("%s: --cmd needs a command", name);
			exit(2);
		}
		ClientTarget t = client_connect(name);
		exit(client_send(&t, cmd.str_view()));
	};
}
