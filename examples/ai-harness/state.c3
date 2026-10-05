module ai_harness;

import milktea;
import glaze;
import boba;
import std::core::dstring;
import std::core::mem;
import std::atomic;
import std::thread::channel;
import llm;

const int INPUT_BUF_SIZE = 4096;
const int MAX_HISTORY = 64;
const int MAX_LOG = 64;
// Cap on request rows built for the sidebar. Rows past the pane's height are
// solved to zero and never painted, so this only bounds the work.
const int MAX_SIDEBAR_ROWS = 64;
const int BASH_BUF_SIZE = 4096;
const int MODAL_MSG_SIZE = 1024;
const int API_KEY_SIZE = 512;

const String API_URL = "https://token-plan-ams.xiaomimimo.com/v1/chat/completions";
const String DEFAULT_MODEL = "mimo-v2.5";
const int HTTP_TIMEOUT_MS = 120000;

// Editor is the prompt line: a byte buffer plus a caret into it. The buffer is
// UTF-8, and cursor is a byte offset, so it only ever lands on a rune boundary
// because insert and delete move it by whole runes.
struct Editor {
	char[INPUT_BUF_SIZE] buf;
	sz len;
	sz cursor;
	// Blink phase for the block caret, toggled by the idle tick.
	bool caret_on;
}

fn String Editor.text(&self) => (String)self.buf[:self.len];

fn void Editor.clear(&self) {
	self.len = 0;
	self.cursor = 0;
}

// insert puts a rune at the caret, shifting the tail right. A rune that would
// overflow the buffer is dropped.
fn void Editor.insert(&self, uint rune) {
	char[4] enc;
	sz n = milktea::utf8_encode(rune, enc[..]);
	if (self.len + n >= INPUT_BUF_SIZE) return;
	for (sz i = self.len; i > self.cursor; i--) {
		self.buf[i + n - 1] = self.buf[i - 1];
	}
	for (sz i = 0; i < n; i++) self.buf[self.cursor + i] = enc[i];
	self.len += n;
	self.cursor += n;
}

// prev_boundary returns the offset of the rune that ends at the caret, found
// by walking back over UTF-8 continuation bytes (10xxxxxx). A malformed run
// of them cannot walk past the start, so this always terminates.
fn sz Editor.prev_boundary(&self) {
	if (self.cursor == 0) return 0;
	sz i = self.cursor - 1;
	while (i > 0 && (self.buf[i] & 0xc0) == 0x80) i--;
	return i;
}

// backspace deletes the whole rune before the caret, not one byte of it.
fn void Editor.backspace(&self) {
	if (self.cursor == 0) return;
	sz start = self.prev_boundary();
	sz n = self.cursor - start;
	for (sz i = self.cursor; i < self.len; i++) {
		self.buf[i - n] = self.buf[i];
	}
	self.len -= n;
	self.cursor = start;
}

// left and right move by whole runes, so the caret never lands inside a
// multi-byte sequence — which would split it when the next insert shifts the
// tail, and mis-measure the prompt's width.
fn void Editor.left(&self) {
	self.cursor = self.prev_boundary();
}

fn void Editor.right(&self) {
	if (self.cursor >= self.len) return;
	self.cursor += glaze::utf8_sequence_len(self.text(), self.cursor);
	if (self.cursor > self.len) self.cursor = self.len;
}

// Transcript is the scrolling log: the accumulated ANSI text and the viewport
// over it. follow keeps the newest output in sight until the user scrolls up.
struct Transcript {
	DString text;
	boba::Viewport view;
	bool follow;
}

fn void Transcript.line(&self, String s) {
	self.text.append_string(s);
	self.text.append_char('\n');
}

// Request is one in-flight completion: whether it is running, when it
// started, how long the last one took, and the cancel flag the worker polls.
struct Request {
	bool loading;
	boba::Spinner spinner;
	sz started_ms;
	// Seconds the last completion took, or -1 before the first one.
	double last_sec;
	Atomic{int} cancel;
}

fn void Request.finish(&self) {
	self.last_sec = ((double)(milktea::time_ms() - self.started_ms)) / 1000.0;
	self.loading = false;
}

// BashPrompt is a pending bash approval.
//
// The worker thread is parked on ack until someone pushes to it, so an
// unanswered prompt hangs that thread forever. pending is therefore derived
// from ack rather than tracked separately: a prompt is outstanding exactly
// while there is a channel to answer, and resolve() is the only way to clear
// it. Dropping the prompt without answering is not expressible.
struct BashPrompt {
	char[BASH_BUF_SIZE] cmd;
	int cmd_len;
	channel::OneShotChannel{int}* ack;
}

fn bool BashPrompt.pending(&self) => self.ack != null;

fn String BashPrompt.command(&self) => (String)self.cmd[:self.cmd_len];

fn void BashPrompt.set(&self, String command, channel::OneShotChannel{int}* ack) {
	int n = command.len < BASH_BUF_SIZE - 1 ? (int)command.len : BASH_BUF_SIZE - 1;
	mem::copy(&self.cmd[0], command.ptr, (sz)n);
	self.cmd[n] = 0;
	self.cmd_len = n;
	self.ack = ack;
}

// resolve answers the waiting worker and clears the prompt. Clearing ack
// first means a second call is a no-op rather than a double push.
fn void BashPrompt.resolve(&self, bool approved) {
	if (self.ack == null) return;
	channel::OneShotChannel{int}* ack = self.ack;
	self.ack = null;
	ack.push(approved ? 1 : 0)!!;
}

// Dialog is the error modal. Any key dismisses it.
struct Dialog {
	bool showing;
	char[MODAL_MSG_SIZE] msg;
	int msg_len;
}

fn String Dialog.text(&self) => (String)self.msg[:self.msg_len];

fn void Dialog.show(&self, String title, String body) {
	DString buf = dstring::temp();
	buf.append_string(title);
	buf.append_string("\n\n");
	buf.append_string(body);
	String s = buf.str_view();
	sz n = s.len < MODAL_MSG_SIZE - 1 ? s.len : MODAL_MSG_SIZE - 1;
	mem::copy(&self.msg[0], s.ptr, n);
	self.msg[n] = 0;
	self.msg_len = (int)n;
	self.showing = true;
}

// RequestLog is the sidebar's list of response codes, newest last.
struct RequestLog {
	bool open;
	int[MAX_LOG] status;
	int count;
}

fn void RequestLog.add(&self, int status) {
	if (self.count >= MAX_LOG) return;
	self.status[self.count] = status;
	self.count++;
}

fn String status_label(int code) {
	if (code < 300) return "ok";
	if (code < 400) return "redirect";
	return "error";
}

// Session is the conversation sent to the API: the key and the accumulated
// message history.
struct Session {
	char[API_KEY_SIZE] api_key;
	int api_key_len;
	llm::HistoryEntry[MAX_HISTORY] history;
	int history_count;
	// Whether to show the model's reasoning text in the transcript.
	bool show_thinking;
}

fn bool Session.has_key(&self) => self.api_key_len > 0;

struct Model {
	Editor input;
	Transcript log;
	Request request;
	BashPrompt bash;
	Dialog dialog;
	RequestLog requests;
	Session session;
	// Set by the first q press, cleared by any other key.
	bool confirm_quit;
}
