function h(type, props, ...children) {
  return { type, props: props || {}, children: children.flat().filter(c => c != null) };
}
globalThis.h = h;

globalThis.__taro_quit = false;

// ── Streaming body support ────────────────────────────────────────────────────
// Each streaming fetch gets a slot keyed by req_id.  The C drain loop calls
// __taro_push_chunk(req_id, text) for each SSE data line and
// __taro_stream_done(req_id, error_or_null) when the stream closes.
// response.body is an async iterable that yields each raw chunk string.
(function() {
  const _streams = {};  // req_id → { queue, resolve, done, error }

  globalThis.__taro_stream_alloc = function(req_id) {
    _streams[req_id] = { queue: [], resolve: null, done: false, error: null };
  };

  globalThis.__taro_push_chunk = function(req_id, text) {
    const s = _streams[req_id];
    if (!s) return;
    if (s.resolve) {
      const res = s.resolve;
      s.resolve = null;
      res({ value: text, done: false });
    } else {
      s.queue.push(text);
    }
  };

  globalThis.__taro_stream_done = function(req_id, error) {
    const s = _streams[req_id];
    if (!s) return;
    s.done = true;
    s.error = error || null;
    if (s.resolve) {
      const res = s.resolve;
      s.resolve = null;
      if (error) res(Promise.reject(new Error(error)));
      else       res({ value: undefined, done: true });
    }
  };

  // Build an async-iterable body object for a given req_id
  globalThis.__taro_make_stream_body = function(req_id) {
    return {
      [Symbol.asyncIterator]() {
        return {
          next() {
            const s = _streams[req_id];
            if (!s) return Promise.resolve({ value: undefined, done: true });
            if (s.queue.length > 0) {
              return Promise.resolve({ value: s.queue.shift(), done: false });
            }
            if (s.done) {
              delete _streams[req_id];
              if (s.error) return Promise.reject(new Error(s.error));
              return Promise.resolve({ value: undefined, done: true });
            }
            // No chunk yet — park a resolve callback
            return new Promise(resolve => { s.resolve = resolve; });
          },
          return() {
            delete _streams[req_id];
            return Promise.resolve({ value: undefined, done: true });
          }
        };
      }
    };
  };
})();

// Pre-compiled response factory used by the C fetch drain (batch path)
globalThis.__taro_make_response = function(r) {
  r.text = function() { return Promise.resolve(r._body); };
  r.json = function() { return Promise.resolve(JSON.parse(r._body)); };
  return r;
};

// Streaming response factory: body is the async iterable, text()/json() collect it
globalThis.__taro_make_stream_response = function(req_id, status) {
  const body = __taro_make_stream_body(req_id);
  const r = {
    ok:     status >= 200 && status < 300,
    status: status,
    body:   body,
    text() {
      return (async () => {
        let out = "";
        for await (const chunk of body) out += chunk;
        return out;
      })();
    },
    json() {
      return this.text().then(t => JSON.parse(t));
    },
  };
  return r;
};

// setInterval via recursive setTimeout
(function() {
  let _interval_id = 1000000; // start above setTimeout id range
  const _intervals = {};
  globalThis.setInterval = function(fn, delay) {
    const id = _interval_id++;
    function fire() {
      if (!_intervals[id]) return;
      fn();
      if (_intervals[id]) _intervals[id] = setTimeout(fire, delay);
    }
    _intervals[id] = setTimeout(fire, delay);
    return id;
  };
  globalThis.clearInterval = function(id) {
    if (_intervals[id]) { clearTimeout(_intervals[id]); delete _intervals[id]; }
  };
})();

globalThis.console = {
  log(...args) {
    const line = args.map(a => (typeof a === "object" ? JSON.stringify(a) : String(a))).join(" ");
    // Write to stderr so it appears even when stdout is captured
    // QuickJS doesn't have process.stderr, but print() goes to stdout
    // Use a C-backed __taro_log if available, otherwise best-effort
    if (typeof __taro_log === "function") {
      __taro_log(line);
    } else {
      print(line);
    }
  },
  error(...args) { this.log(...args); },
  warn(...args)  { this.log(...args); },
  info(...args)  { this.log(...args); },
};

globalThis.tea = {
  run(model) {
    globalThis.__taro_model = model;
  },

  quit() {
    globalThis.__taro_quit = true;
    return "quit";
  },

  tick(tag) {
    return { __cmd: "tick", tag };
  },

  keyName(msg) {
    if (msg.kind === "key" && msg.key && msg.key.code) {
      return msg.key.code;
    }
    return "";
  },

  isKey(msg, code) {
    return msg.kind === "key" && msg.key && msg.key.code === code;
  },

  batch(...cmds) {
    return { __cmd: "batch", cmds };
  },

  // Textarea API — backed by boba::Textarea on the C3 side
  // textareaUpdate(id, msg) forwards a key event to the textarea
  textareaUpdate(id, msg) {
    if (typeof textareaUpdate === "function") textareaUpdate(id, msg);
  },

  // textareaGetText(id) returns the current text content
  textareaGetText(id) {
    return typeof textareaGetText === "function" ? textareaGetText(id) : "";
  },

  // textareaClear(id) clears the textarea
  textareaClear(id) {
    if (typeof textareaClear === "function") textareaClear(id);
  },

  // textareaGetCursor(id) returns { row, col }
  textareaGetCursor(id) {
    return typeof textareaGetCursor === "function" ? textareaGetCursor(id) : { row: 0, col: 0 };
  },

  // Viewport API — backed by boba::Viewport on the C3 side
  viewportUpdate(id, msg) {
    if (typeof viewportUpdate === "function") viewportUpdate(id, msg);
  },
  viewportScrollToBottom(id) {
    if (typeof viewportScrollToBottom === "function") viewportScrollToBottom(id);
  },
  viewportScrollUp(id) {
    if (typeof viewportScrollUp === "function") viewportScrollUp(id);
  },
  viewportScrollDown(id) {
    if (typeof viewportScrollDown === "function") viewportScrollDown(id);
  },
  viewportPageUp(id) {
    if (typeof viewportPageUp === "function") viewportPageUp(id);
  },
  viewportPageDown(id) {
    if (typeof viewportPageDown === "function") viewportPageDown(id);
  },
};
