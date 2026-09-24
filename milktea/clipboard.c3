module milktea;

import std::os::process;
import std::encoding::base64;

// The system clipboard, whichever backend is running.
//
// A backend with a clipboard of its own — the GUI, through its windowing
// library — installs a reader and a writer. Without one, as in a terminal,
// writing sends the text to the terminal with OSC 52, which most modern
// terminals pass on to the system clipboard; on macOS it also goes through
// pbcopy, since Terminal.app ignores OSC 52. Reading is pbpaste on macOS and
// unavailable elsewhere: a terminal hands pasted text over by itself, as a
// PASTE message.

alias ClipboardWriteFn = fn void(String text);
alias ClipboardReadFn = fn String?();

ClipboardWriteFn clipboard_writer;
ClipboardReadFn clipboard_reader;

faultdef NO_CLIPBOARD;

fn void use_clipboard(ClipboardWriteFn write, ClipboardReadFn read) {
	clipboard_writer = write;
	clipboard_reader = read;
}

fn void set_clipboard(String text) {
	if (clipboard_writer) {
		clipboard_writer(text);
		return;
	}
	DString seq = dstring::temp();
	seq.append("\x1b]52;c;");
	seq.append(base64::tencode(text));
	seq.append("\x07");
	write_stdout((char[])seq.str_view());
	$if env::DARWIN:
		if (try p = process::spawn({ "/usr/bin/pbcopy" }, {}, {}, process::CAPTURE, process::DEFAULT, process::DEFAULT)) {
			(void)p.write_stdin(text);
			(void)p.join();
			(void)p.destroy();
		}
	$endif
}

// clipboard returns the clipboard's text, in temp memory.
fn String? clipboard() {
	if (clipboard_reader) return clipboard_reader();
	$if env::DARWIN:
		process::Process p = process::spawn({ "/usr/bin/pbpaste" }, {}, {}, process::DEFAULT, process::CAPTURE, process::DEFAULT)!;
		defer (void)p.destroy();
		DString out = dstring::temp();
		char[4096] buf;
		while (try n = p.read_stdout(&buf, buf.len)) {
			if (n == 0) break;
			out.append((String)buf[:n]);
		}
		(void)p.join();
		return out.str_view();
	$else
		return NO_CLIPBOARD~;
	$endif
}
