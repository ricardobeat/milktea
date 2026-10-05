// Talking to the API: key lookup, the JSON history the request is built from,
// and the callbacks the llm worker thread calls back on.
module ai_harness;

import milktea;
import glaze;
import std::core::dstring;
import std::core::mem;
import std::thread::channel;
import llm;

extern fn char* getenv(char* name);

// Tags for the messages the worker thread posts back to the UI thread. The
// payload type differs per tag, so they are documented together here — a
// wrong cast on the receiving side is otherwise silent.
const int MSG_STREAM = 1; // user = DString*    (delta text)
const int MSG_DONE   = 2; // user = llm::Result*
const int MSG_TOOL   = 3; // user = DString*    (tool description)
const int MSG_BASH   = 4; // user = BashReq*

struct BashReq {
	DString cmd;
	channel::OneShotChannel{int}* ack;
}

// ── Callbacks (run on the background thread) ───────────────────────────────
//
// These are the only code here that does not run on the UI thread. They may
// not touch the Model: everything is handed over as a heap payload on a
// milktea message, and update() owns it from there.

fn void post_string(int tag, String s) @local {
	DString* ds = mem::new(DString);
	*ds = dstring::new(mem);
	ds.append_string(s);
	milktea::g_program.send({ .kind = milktea::MsgKind.USER, .tag = tag, .user = (void*)ds });
}

fn int cb_stream(void* ctx, String delta) {
	post_string(MSG_STREAM, delta);
	return 0;
}

fn void cb_tool(void* ctx, String description) {
	post_string(MSG_TOOL, description);
}

// cb_bash blocks this thread until the UI answers, which is what makes the
// approval prompt synchronous from the tool's point of view.
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

// ── History ────────────────────────────────────────────────────────────────

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

fn void Session.add_message(&self, String role, String content) {
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

// read_api_key loads the key from the environment. Returns false when it is
// unset, which the caller reports before quitting.
fn bool Session.read_api_key(&self) {
	char* val = getenv("XIAOMI_TOKEN_PLAN_KEY");
	if (val == null) return false;
	sz len = 0;
	while (val[len] != 0) len++;
	if (len > API_KEY_SIZE - 1) len = API_KEY_SIZE - 1;
	mem::copy(&self.api_key[0], val, len);
	self.api_key[len] = 0;
	self.api_key_len = (int)len;
	return true;
}

// ── Kickoff ────────────────────────────────────────────────────────────────

// kickoff hands the history to the llm worker and starts the spinner tick.
fn milktea::Cmd Model.kickoff(&self) {
	self.request.started_ms = milktea::time_ms();
	self.request.loading = true;
	self.request.cancel.store(0);

	llm::Config config = {};
	mem::copy(&config.url[0], &API_URL[0], (sz)API_URL.len + 1);
	mem::copy(&config.api_key[0], &self.session.api_key[0], (sz)self.session.api_key_len + 1);
	mem::copy(&config.model[0], &DEFAULT_MODEL[0], (sz)DEFAULT_MODEL.len + 1);
	config.timeout_ms = HTTP_TIMEOUT_MS;

	llm::start(config, &self.session.history[0], self.session.history_count, &self.request.cancel,
		&cb_stream, &cb_tool, &cb_bash, &cb_done, (void*)self);

	return milktea::tick(80);
}
