module milktea;

import std::io;
import std::core::dstring;
import std::core::string;

// A running program takes commands from other processes through a named
// pipe, and the same binary is the client that sends them:
//
//   MILKTEA_CONTROL=1 ted         the running program listens
//   ted --cmd click save          another process sends it one command
//   ted --cmd screen              prints the reply, exits 0 on ok, 1 on err
//
// Listening is opt-in. The pipes live in a directory only the user can
// enter, <tmp>/milktea-<uid>/: <name>.<pid> is a program's command pipe and
// <name> a link to the most recently started one, which is where --cmd
// sends unless MILKTEA_PID names another. Each --cmd makes a pipe of its own
// for the reply and names it in front of the command, so any number can ask
// at once.

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

// Short writes to a pipe arrive whole, so two clients' lines never mix. This
// is the smallest such size any system promises.
const sz PIPE_LINE_MAX @local = 512;
// How long --cmd waits for its answer.
const int CLIENT_WAIT_MS @local = 5000;
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
	ZString path;
	ZString link;
	ZString target;
	// The directory and a slash: a reply pipe must be inside it.
	String prefix;
}

ControlPipe g_pipe @local;

// control_pipe_wanted says whether the program was asked to listen.
fn bool control_pipe_wanted() {
	char* v = getenv("MILKTEA_CONTROL");
	if (v == null) return false;
	String s = ((ZString)v).str_view();
	return s.len > 0 && s != "0";
}

// control_pipe_open makes the program's command pipe and points the link at
// it. Returns false, and the program runs on without one, when it cannot.
fn bool control_pipe_open() {
	if (g_pipe.open) return true;
	String[] args;
	String name;
	@pool() {
		args = program_args();
		if (args.len == 0) return false;
		name = base_name(args[0]);
		String dir = pipe_dir();
		mkdir(dir.zstr_tcopy(), 0o700);
		g_pipe.target = string::format(mem, "%s.%d", name, getpid()).zstr_copy(mem);
		g_pipe.path = string::format(mem, "%s/%s.%d", dir, name, getpid()).zstr_copy(mem);
		g_pipe.link = string::format(mem, "%s/%s", dir, name).zstr_copy(mem);
		g_pipe.prefix = string::format(mem, "%s/", dir);
		unlink(g_pipe.path);
		if (mkfifo(g_pipe.path, 0o600) != 0) return false;
		// Open for reading and writing, so the pipe never reads as ended when
		// a client goes away, and opening does not wait for one.
		g_pipe.fd = open(g_pipe.path, O_RDWR | O_NONBLOCK);
		if (g_pipe.fd < 0) {
			unlink(g_pipe.path);
			return false;
		}
		unlink(g_pipe.link);
		symlink(g_pipe.target, g_pipe.link);
		// A client that goes away mid-reply must not take the program with it.
		signal(SIGPIPE, (void*)(uptr)1);
		atexit(&control_pipe_close);
		g_pipe.open = true;
		return true;
	};
}

fn int control_pipe_fd() => g_pipe.open ? g_pipe.fd : -1;

// control_pipe_close removes the pipe, and the link if it still points here:
// a program started later has taken it over.
fn void control_pipe_close() {
	if (!g_pipe.open) return;
	g_pipe.open = false;
	char[256] buf;
	sz n = readlink(g_pipe.link, &buf, buf.len);
	if (n > 0 && (String)buf[:n] == g_pipe.target.str_view()) unlink(g_pipe.link);
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

// control_client is the whole of a run that was given --cmd: it sends the
// command to the running program, prints the reply and exits. Any other run
// returns from it at once. run() calls it before it touches the terminal.
fn void control_client() {
	@pool() {
		String[] args = program_args();
		sz at = -1;
		for (sz i = 1; i < args.len; i++) {
			if (args[i] == "--cmd") {
				at = i;
				break;
			}
		}
		if (at < 0) return;
		String name = base_name(args[0]);
		DString cmd = dstring::temp();
		for (sz i = at + 1; i < args.len; i++) {
			if (cmd.len() > 0) cmd.append_char(' ');
			cmd.append_string(args[i]);
		}
		if (cmd.len() == 0) {
			io::eprintfn("%s: --cmd needs a command", name);
			exit(2);
		}
		String dir = pipe_dir();
		String target = string::tformat("%s/%s", dir, name);
		char* pid = getenv("MILKTEA_PID");
		if (pid != null && ((ZString)pid).len() > 0) target = string::tformat("%s.%s", target, (ZString)pid);
		// With nobody reading the pipe this fails, so a program that has gone
		// and left its pipe behind is told apart from one that is running.
		int to = open(target.zstr_tcopy(), O_WRONLY | O_NONBLOCK);
		if (to < 0) {
			io::eprintfn("%s: no running %s is taking commands (start it with MILKTEA_CONTROL=1)", name, name);
			exit(1);
		}
		ZString reply = string::tformat("%s/.reply.%d", dir, getpid()).zstr_tcopy();
		unlink(reply);
		int from = mkfifo(reply, 0o600) == 0 ? open(reply, O_RDWR) : -1;
		if (from < 0) {
			io::eprintfn("%s: cannot make a pipe for the reply", name);
			exit(1);
		}
		String line = string::tformat(">%s\t%s\n", reply, cmd.str_view());
		if (line.len > PIPE_LINE_MAX) {
			unlink(reply);
			io::eprintfn("%s: command too long", name);
			exit(2);
		}
		(void)write(to, line.ptr, line.len);
		close(to);

		DString got = dstring::temp();
		for (;;) {
			PollFd p = { .fd = from, .events = POLLIN };
			if (poll(&p, 1, CLIENT_WAIT_MS) <= 0) {
				unlink(reply);
				io::eprintfn("%s: no answer", name);
				exit(1);
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
					(void)write(STDOUT_FILENO, s.ptr + 1, nl);
					unlink(reply);
					exit(s[1:nl - 1].starts_with("err") ? 1 : 0);
				}
				(void)write(STDOUT_FILENO, s.ptr, nl + 1);
				got.delete(0, nl + 1);
			}
		}
	};
}
