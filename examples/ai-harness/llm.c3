module llm;

import std::core::dstring;
import std::core::mem;
import std::thread;
import std::atomic;
import std::encoding::json;
import std::collections::object;
import std::io;
import std::io::file;
import http_shim;

// ── Types ──────────────────────────────────────────────────────────────────

struct Result {
	int status;
	int ok;        // 1 = assistant content, 0 = error
	DString body;  // assistant content or error message
	DString reasoning; // thinking traces (may be empty)
}

struct Config {
	char[512] url;
	char[512] api_key;
	char[512] model;
	int timeout_ms;
}

struct HistoryEntry {
	DString json;
}

// Callback types — all invoked from the background thread.
// StreamCb: called for each content delta. Return non-zero to cancel.
alias StreamCb = fn int(void* ctx, String delta);
// ToolCb: called after a tool action executes (for logging).
alias ToolCb   = fn void(void* ctx, String description);
// BashCb: called to request bash approval. Must block until answered.
// Return 1 to approve, 0 to deny.
alias BashCb   = fn int(void* ctx, String command);
// DoneCb: called when the full agent loop finishes. Caller owns result fields.
alias DoneCb   = fn void(void* ctx, Result* result);

// ── Internal ───────────────────────────────────────────────────────────────

struct Job {
	Config config;
	HistoryEntry* history;
	int history_count;
	Atomic{int}* cancel;
	StreamCb on_stream;
	ToolCb on_tool;
	BashCb on_bash;
	DoneCb on_done;
	void* ctx;
}

struct StreamCtx {
	DString accumulated;
	DString line_buf;
	Atomic{int}* cancel;
	StreamCb on_stream;
	void* ctx;
}

// ── Constants ──────────────────────────────────────────────────────────────

const int MAX_ROUNDS = 10;
const int RESP_BUF_SIZE = 65536;

const String SYSTEM_PROMPT =
	"You are a helpful AI assistant. You can use the bash, view_file, and edit_file "
	"tools, but ONLY call them when the user explicitly asks you to run a command "
	"or read/write a file. For greetings and general questions, answer directly "
	"in plain text and never invoke any tool. Keep responses concise.";

const String TOOLS_JSON =
	"[{\"type\":\"function\",\"function\":{\"name\":\"view_file\","
	"\"description\":\"Read the contents of a file at the given path\","
	"\"parameters\":{\"type\":\"object\","
	"\"properties\":{\"path\":{\"type\":\"string\","
	"\"description\":\"File path to read\"}},"
	"\"required\":[\"path\"]}}},"
	"{\"type\":\"function\",\"function\":{\"name\":\"edit_file\","
	"\"description\":\"Replace an exact, unique old_string in a file with new_string. old_string must appear exactly once and match the file bytes exactly (include enough surrounding context to make it unique).\","
	"\"parameters\":{\"type\":\"object\","
	"\"properties\":{\"path\":{\"type\":\"string\","
	"\"description\":\"File path to edit\"},"
	"\"old_string\":{\"type\":\"string\","
	"\"description\":\"Exact text in the file to find and replace\"},"
	"\"new_string\":{\"type\":\"string\","
	"\"description\":\"Text to insert in place of old_string\"}},"
	"\"required\":[\"path\",\"old_string\",\"new_string\"]}}},"
	"{\"type\":\"function\",\"function\":{\"name\":\"bash\","
	"\"description\":\"Run a shell command and return its output\","
	"\"parameters\":{\"type\":\"object\","
	"\"properties\":{\"command\":{\"type\":\"string\","
	"\"description\":\"Shell command to execute\"}},"
	"\"required\":[\"command\"]}}}]";

// ── Helpers ────────────────────────────────────────────────────────────────

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

fn sz cbuf_len(char* s) {
	sz n = 0;
	while (s[n] != 0) n++;
	return n;
}

fn String cbuf_str(char* buf) {
	return (String)buf[:cbuf_len(buf)];
}

fn DString build_request_body(String model, DString* local_msgs, int local_count) {
	DString body = dstring::new(mem);
	body.append_string("{\"model\":\"");
	body.append_string(model);
	body.append_string("\",\"messages\":[");
	for (int i = 0; i < local_count; i++) {
		if (i > 0) body.append_char(',');
		body.append_string(local_msgs[i].str_view());
	}
	body.append_string("],\"tools\":");
	body.append_string(TOOLS_JSON);
	body.append_string(",\"stream\":true}");
	return body;
}

fn int count_substring(String haystack, String needle) {
	if (needle.len == 0 || needle.len > haystack.len) return 0;
	int count = 0;
	for (sz i = 0; i <= haystack.len - needle.len; i++) {
		bool match = true;
		for (sz j = 0; j < needle.len; j++) {
			if (haystack[i + j] != needle[j]) { match = false; break; }
		}
		if (match) { count++; i += needle.len - 1; }
	}
	return count;
}

fn sz find_substring(String haystack, String needle) {
	if (needle.len == 0 || needle.len > haystack.len) return ~(sz)0;
	for (sz i = 0; i <= haystack.len - needle.len; i++) {
		bool match = true;
		for (sz j = 0; j < needle.len; j++) {
			if (haystack[i + j] != needle[j]) { match = false; break; }
		}
		if (match) return i;
	}
	return ~(sz)0;
}

// ── Tool execution ─────────────────────────────────────────────────────────

fn String run_view_file(String path) {
	if (file::exists(path)) {
		char[]? file_data = file::load(mem, path);
		if (try c = file_data) {
			return (String)c;
		} else {
			return string::tformat("Error reading %s", path);
		}
	} else {
		return string::tformat("Error: file not found: %s", path);
	}
}

fn String run_edit_file(String path, String old_string, String new_string) {
	if (!file::exists(path)) {
		return string::tformat("Error: file not found: %s", path);
	}
	char[]? file_data = file::load(mem, path);
	if (try content = file_data) {
		String content_str = (String)content;

		int count = count_substring(content_str, old_string);
		if (count == 0) {
			return string::tformat("Error: old_string not found in %s", path);
		}
		if (count > 1) {
			return string::tformat("Error: old_string appears %d times in %s (must be unique)", count, path);
		}

		sz pos = find_substring(content_str, old_string);

		DString new_content = dstring::new(mem);
		new_content.append_string((String)content_str[:pos]);
		new_content.append_string(new_string);
		new_content.append_string((String)content_str[pos + old_string.len:content_str.len]);

		(void)file::save(path, new_content.str_view());
		new_content.free();
		return string::tformat("File %s edited successfully.", path);
	}
	return string::tformat("Error: could not read %s", path);
}

fn String run_bash_exec(String cmd) {
	char[RESP_BUF_SIZE] out;
	int exit_code = -1;
	int ok = http_shim::mimo_run_command((char*)cmd.ptr, &out[0], RESP_BUF_SIZE, &exit_code);
	if (!ok) {
		return string::tformat("Failed to run command: %s", cmd);
	}
	String o = cbuf_str(&out[0]);
	sz olen = o.len;
	if (olen > 4000) olen = 4000;
	return string::tformat("exit=%d\n%s", exit_code, (String)o[:olen]);
}

// ── Tool call parsing ──────────────────────────────────────────────────────

fn bool parse_tool_calls(char* resp_body, int resp_len,
	DString* local_msgs, int* local_count, Job* job,
	DString* out_content, DString* out_reasoning, DString* out_err) {

	Object* doc = null;
	if (try d = json::parse(mem, (String)resp_body[:resp_len])) {
		doc = d;
	} else {
		*out_err = dstring::new(mem);
		out_err.append_string("JSON parse failed");
		return false;
	}

	Object* err = doc.get("error") ?? null;
	if (err) {
		*out_err = dstring::new(mem);
		out_err.append_string("API error: ");
		out_err.append_string(err.get_string("message") ?? "unknown error");
		return false;
	}

	Object* choices = doc.get("choices") ?? null;
	if (!choices || choices.len() == 0) {
		*out_err = dstring::new(mem);
		out_err.append_string("No choices in response");
		return false;
	}
	Object* message = choices.get_at(0).get("message") ?? null;
	if (!message) {
		*out_err = dstring::new(mem);
		out_err.append_string("No message in response");
		return false;
	}

	String content = message.get_string("content") ?? "";
	String reasoning = message.get_string("reasoning_content") ?? "";

	Object* tool_calls = message.get("tool_calls") ?? null;
	int tc_count = (tool_calls != null && tool_calls.is_array()) ? (int)tool_calls.len() : 0;

	if (tc_count == 0) {
		*out_content = dstring::new(mem);
		out_content.append_string(content);
		*out_reasoning = dstring::new(mem);
		out_reasoning.append_string(reasoning);
		return false;
	}

	DString assistant_json = dstring::new(mem);
	assistant_json.append_string("{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[");
	for (int i = 0; i < tc_count; i++) {
		if (i > 0) assistant_json.append_char(',');
		Object* tc = tool_calls.get_at(i);
		String tc_id = tc.get_string("id") ?? "call_0";
		Object* func = tc.get("function") ?? null;
		String func_name = func ? (func.get_string("name") ?? "unknown") : "unknown";
		String func_args = func ? (func.get_string("arguments") ?? "{}") : "{}";

		assistant_json.append_string("{\"type\":\"function\",\"id\":\"");
		assistant_json.append_string(tc_id);
		assistant_json.append_string("\",\"function\":{\"name\":\"");
		assistant_json.append_string(func_name);
		assistant_json.append_string("\",\"arguments\":\"");
		json_escape(&assistant_json, func_args);
		assistant_json.append_string("\"}}");
	}
	assistant_json.append_string("]}");

	local_msgs[*local_count] = assistant_json;
	*local_count += 1;

	for (int i = 0; i < tc_count; i++) {
		Object* tc = tool_calls.get_at(i);
		String tc_id = tc.get_string("id") ?? "call_0";
		Object* func = tc.get("function") ?? null;
		String fn_name = func ? (func.get_string("name") ?? "unknown") : "unknown";
		String func_args = func ? (func.get_string("arguments") ?? "{}") : "{}";

		String result;
		Object* args = null;
		if (func_args.len > 0) {
			if (try a = json::parse(mem, func_args)) {
				args = a;
			} else {
				args = null;
			}
		}

		if (fn_name == "view_file") {
			String path_str = args ? (args.get_string("path") ?? "") : "";
			result = run_view_file(path_str);
			job.on_tool(job.ctx, string::tformat("view_file: %s", path_str));
		} else if (fn_name == "edit_file") {
			String path_str = args ? (args.get_string("path") ?? "") : "";
			String old_str = args ? (args.get_string("old_string") ?? "") : "";
			String new_str = args ? (args.get_string("new_string") ?? "") : "";
			result = run_edit_file(path_str, old_str, new_str);
			job.on_tool(job.ctx, string::tformat("edit_file: %s", path_str));
		} else if (fn_name == "bash") {
			String cmd = args ? (args.get_string("command") ?? "") : "";
			int approved = job.on_bash(job.ctx, cmd);
			if (approved) {
				result = run_bash_exec(cmd);
				job.on_tool(job.ctx, string::tformat("$ %s", cmd));
			} else {
				result = string::tformat("Command denied by user: %s", cmd);
				job.on_tool(job.ctx, string::tformat("[denied] $ %s", cmd));
			}
		} else {
			result = string::tformat("Unknown function: %s", fn_name);
		}

		DString tool_msg = dstring::new(mem);
		tool_msg.append_string("{\"role\":\"tool\",\"tool_call_id\":\"");
		tool_msg.append_string(tc_id);
		tool_msg.append_string("\",\"content\":\"");
		json_escape(&tool_msg, result);
		tool_msg.append_string("\"}");

		local_msgs[*local_count] = tool_msg;
		*local_count += 1;
	}

	return true;
}

// ── Streaming callback ─────────────────────────────────────────────────────

fn void emit_sse_line(StreamCtx* sctx, String line) {
	if (!line.starts_with("data: ")) return;
	String payload = line.strip_prefix("data: ");
	if (payload == "[DONE]") return;
	sctx.accumulated.append_string(payload);
	@pool() {
		if (try obj = json::parse(tmem, payload)) {
			Object* choices = obj.get("choices") ?? null;
			if (choices && choices.len() > 0) {
				Object* delta = choices.get_at(0).get("delta") ?? null;
				if (delta) {
					String dc = delta.get_string("content") ?? "";
					if (dc.len > 0) {
						sctx.on_stream(sctx.ctx, dc);
					}
				}
			}
		}
	};
}

// Raw byte callback from libcurl. Chunk boundaries fall anywhere -- mid-line,
// mid-UTF-8 -- so bytes are buffered and only complete lines are parsed. The
// data pointer belongs to curl and is valid only for this call, so it is
// copied into line_buf before anything else touches it.
//
// Returns 0 to continue, non-zero to cancel the transfer.
fn int stream_raw_cb(char* data, int len, void* user) {
	StreamCtx* sctx = (StreamCtx*)user;
	if (len > 0) sctx.line_buf.append_string((String)data[:len]);

	// Drain every complete line, leaving any trailing partial in the buffer.
	while (true) {
		String buf = sctx.line_buf.str_view();
		usz nl = buf.len;
		for (usz i = 0; i < buf.len; i++) {
			if (buf[i] == '\n') { nl = i; break; }
		}
		if (nl == buf.len) break;

		String line = buf[:nl];
		// Tolerate CRLF: SSE allows either terminator.
		if (line.len > 0 && line[line.len - 1] == '\r') line = line[:line.len - 1];
		if (line.len > 0) emit_sse_line(sctx, line);

		// Consume the line and its newline.
		String rest = buf[nl + 1..];
		DString next = dstring::new(mem);
		next.append_string(rest);
		sctx.line_buf.free();
		sctx.line_buf = next;
	}

	return sctx.cancel.load() != 0 ? 1 : 0;
}

// ── Agent loop ─────────────────────────────────────────────────────────────

// agent_loop is the direct-call entry used by tests; the detached thread
// goes through agent_loop_trampoline below so the thread entry frame stays
// tiny (the 128-message array lives one call down, not on the new stack).
fn int agent_loop(void* arg) {
	Job* job = (Job*)arg;
	agent_loop_real(job);
	mem::free(job);
	return 0;
}

fn void agent_loop_real(Job* job) {
	DString* local_msgs = mem::new_array(DString, 128);
	int local_count = 0;

	for (int i = 0; i < job.history_count && i < 128; i++) {
		local_msgs[i] = dstring::new(mem);
		local_msgs[i].append_string(job.history[i].json.str_view());
		local_count++;
	}

	DString final_content = {};
	DString final_reasoning = {};
	DString err_text = {};
	int last_status = 0;

	for (int round = 0; round < MAX_ROUNDS; round++) {
		if (job.cancel.load() != 0) break;

		DString body_str = build_request_body(
			cbuf_str(&job.config.model[0]), &local_msgs[0], local_count);

		StreamCtx sctx = {};
		sctx.accumulated = dstring::new(mem);
		sctx.line_buf = dstring::new(mem);
		sctx.cancel = job.cancel;
		sctx.on_stream = job.on_stream;
		sctx.ctx = job.ctx;

		int status = 0;
		int ok = http_shim::mimo_http_post_stream(
			((ZString)&job.config.url[0]).str_view().zstr_copy(mem),
			((ZString)&job.config.api_key[0]).str_view().zstr_copy(mem),
			body_str.zstr_view(),
			job.config.timeout_ms,
			&stream_raw_cb, &sctx, &status);
		body_str.free();
		// Any trailing partial line is incomplete; drop it with the buffer.
		sctx.line_buf.free();

		if (!ok) {
			last_status = -1;
			err_text = dstring::new(mem);
			err_text.append_string("Network request failed");
			sctx.accumulated.free();
			break;
		}

		last_status = status;
		if (status < 200 || status >= 300) {
			err_text = dstring::new(mem);
			String acc = sctx.accumulated.str_view();
			if (acc.len > 0) {
				err_text.append_string(acc);
			} else {
				err_text.append_string(string::tformat("HTTP %d", status));
			}
			sctx.accumulated.free();
			break;
		}

		String acc = sctx.accumulated.str_view();
		bool needs_round = parse_tool_calls(
			(char*)acc.ptr, (int)acc.len, &local_msgs[0], &local_count, job,
			&final_content, &final_reasoning, &err_text);
		sctx.accumulated.free();

		if (!needs_round) break;
	}

	for (int i = 0; i < local_count; i++) {
		local_msgs[i].free();
	}
	mem::free(local_msgs);

	Result* result = mem::new(Result);
	result.status = last_status;
	if (err_text.len() > 0) {
		result.ok = 0;
		result.body = err_text;
		result.reasoning = dstring::new(mem);
	} else if (final_content.len() > 0) {
		result.ok = 1;
		result.body = final_content;
		result.reasoning = final_reasoning;
	} else {
		result.ok = 0;
		result.body = dstring::new(mem);
		result.body.append_string("No response");
		result.reasoning = dstring::new(mem);
	}

	job.on_done(job.ctx, result);
}

// ── Public API ─────────────────────────────────────────────────────────────

fn void start(Config config, HistoryEntry* history, int history_count,
	Atomic{int}* cancel,
	StreamCb on_stream, ToolCb on_tool, BashCb on_bash, DoneCb on_done,
	void* ctx) {

	Job* job = mem::new(Job);
	job.config = config;
	job.history = history;
	job.history_count = history_count;
	job.cancel = cancel;
	job.on_stream = on_stream;
	job.on_tool = on_tool;
	job.on_bash = on_bash;
	job.on_done = on_done;
	job.ctx = ctx;

	// Heap-box the thread handle. NativeThread.create passes `thread` itself
	// as the pthread arg (thread_posix.c3: callback reads thread_fn/arg out
	// of it), so a stack-local Thread is a use-after-return the moment
	// start() returns on a detached thread. The milktea reader thread gets
	// away with it only because Program outlives the thread.
	thread::Thread* t = mem::new(thread::Thread);
	thread::Thread.create(t, &agent_loop_trampoline, job)!!;
	t.detach()!!;
	return;
}

// agent_loop_trampoline is the thread entry. It must stay tiny: it runs on
// the new thread's stack, so the heavy body (128 DStrings of stack frame)
// lives one call down in agent_loop.
fn int agent_loop_trampoline(void* arg) @export {
	Job* job = (Job*)arg;
	agent_loop_real(job);
	mem::free(job);
	return 0;
}
