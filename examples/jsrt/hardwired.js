// hardwired.js — AI coding assistant TUI
//
// Layout:
//   ┌─────────────────────────────┐
//   │  HARDWIRED  (header)        │
//   ├─────────────────────────────┤
//   │  output (scrollable)        │
//   ├─────────────────────────────┤
//   │  > input box                │
//   └─────────────────────────────┘
//
// Keys:
//   Enter       — send prompt
//   Backspace   — delete last char
//   Tab         — cycle focus between output and input
//   ↑/↓         — scroll output
//   PgUp/PgDn   — scroll output fast
//   Ctrl+C / q  — quit (only when input is empty)

import { tea, h } from "tea";
import { getenv } from "os";

const API_KEY = getenv("MINIMAX_API_KEY") || "";
const API_URL = "https://api.minimax.io/v1/chat/completions";
const MODEL   = "MiniMax-M2.7";

const SYSTEM_PROMPT =
  "You are an expert coding assistant. Be concise and precise. " +
  "Format code blocks with markdown fences. Prefer short explanations.";

// ── Header art ───────────────────────────────────────────────────────────────
//
// Half-block pixel art for "HARDWIRED".
// Each letter is 5px wide × 6px tall. 1px gap between letters.
// 2 pixel rows → 1 terminal row → 3 terminal rows total.
// 9 letters × 5 + 8 gaps = 53 pixels wide.

// prettier-ignore
const FONT = {
  H: ["X...X","X...X","XXXXX","X...X","X...X","....."],
  A: [".XXX.","X...X","XXXXX","X...X","X...X","....."],
  R: ["XXXX.","X...X","XXXX.","X.X..","X..XX","....."],
  D: ["XXXX.","X...X","X...X","X...X","XXXX.","....."],
  W: ["X...X","X...X","X.X.X","XX.XX","X...X","....."],
  I: ["XXXXX","..X..","..X..","..X..","XXXXX","....."],
  E: ["XXXXX","X....","XXXX.","X....","XXXXX","....."],
};

const LOGO_TEXT = "HARDWIRED";

function make_logo_rows() {
  // Returns 6 pixel rows, each a string of '.' and 'X'
  const rows = ["","","","","",""];
  for (let ci = 0; ci < LOGO_TEXT.length; ci++) {
    if (ci > 0) { for (let r = 0; r < 6; r++) rows[r] += "."; }
    const ch = LOGO_TEXT[ci];
    const glyphs = FONT[ch] || FONT["I"];
    for (let r = 0; r < 6; r++) rows[r] += glyphs[r];
  }
  return rows;
}

const LOGO_ROWS = make_logo_rows();

// Returns the terminal rows for the logo (array of { upper, lower })
function logo_terminal_rows() {
  const pairs = [];
  for (let i = 0; i < LOGO_ROWS.length; i += 2) {
    pairs.push({ upper: LOGO_ROWS[i], lower: LOGO_ROWS[i + 1] || "." });
  }
  return pairs;
}

// Build the gradient color array for the logo width
function make_gradient(n_cols, from_hex, to_hex) {
  const colors = [];
  for (let i = 0; i < n_cols; i++) {
    const t = n_cols <= 1 ? 0 : i / (n_cols - 1);
    colors.push(blendLuv(from_hex, to_hex, t));
  }
  return colors;
}

// Render one terminal row of the logo as an ANSI string.
// upper_row and lower_row are strings of '.' and 'X'.
// gradient is array of hex color strings, one per column.
function render_logo_row(upper_row, lower_row, gradient, bg_hex) {
  const RESET = "\x1b[0m";
  let out = "";
  const len = Math.max(upper_row.length, lower_row.length);
  for (let i = 0; i < len; i++) {
    const u = upper_row[i] === "X";
    const d = i < lower_row.length ? lower_row[i] === "X" : false;
    const fg = gradient[Math.min(i, gradient.length - 1)];

    const fg_seq = `\x1b[38;2;${hex_to_rgb(fg)}m\x1b[48;2;${hex_to_rgb(bg_hex)}m`;
    const bg_seq = `\x1b[38;2;${hex_to_rgb(bg_hex)}m\x1b[48;2;${hex_to_rgb(bg_hex)}m`;
    if (u && d) {
      out += fg_seq + "█";
    } else if (u) {
      out += fg_seq + "▀";
    } else if (d) {
      out += fg_seq + "▄";
    } else {
      out += bg_seq + " ";
    }
  }
  out += RESET;
  return out;
}

function hex_to_rgb(hex) {
  // returns "r;g;b" (no trailing 'm') for embedding in ANSI sequences
  if (!hex || hex.length < 7) return "128;128;128";
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r};${g};${b}`;
}

// Render the background pattern for a row, width w
// Pattern cycles through: ╲╲  ╱╱  ╲╲  …  (dim)
const BG_PATTERNS = ["╲", "╲", " ", "╱", "╱", " "];

function render_bg_row(w, row_offset, dim_hex, bg_hex) {
  const RESET = "\x1b[0m";
  let out = `\x1b[38;2;${hex_to_rgb(dim_hex)}m\x1b[48;2;${hex_to_rgb(bg_hex)}m`;
  for (let i = 0; i < w; i++) {
    out += BG_PATTERNS[(i + row_offset * 2) % BG_PATTERNS.length];
  }
  out += RESET;
  return out;
}

// ── Main model ───────────────────────────────────────────────────────────────

tea.run({
  init() {
    this.input      = "";
    this.messages   = [];
    this.output     = [];   // { text, style } — style: "normal" | "thinking" | "dim"
    this.scroll     = 0;
    this.loading    = false;
    this.width      = 80;
    this.height     = 24;
    this.focused    = "input"; // "input" | "output" | "none"

    this.thinking        = false;
    this.thinkStart      = 0;
    this.responseContent = "";

    // Precomputed gradient (recomputed on resize)
    this._logo_gradient  = null;
    this._logo_width     = 0;

    if (!API_KEY) {
      this._push("⚠  MINIMAX_API_KEY is not set. Export it and restart.", "dim");
      this._push("", "normal");
      this._push("   export MINIMAX_API_KEY=your_key_here", "dim");
    }
  },

  _push(text, style) {
    this.output.push({ text, style: style || "normal" });
  },

  _header_rows() { return 3; },
  _pane_h()      { return Math.max(1, this.height - this._header_rows() - 4); }, // 3 input + 1 help estimate
  _input_row()   { return this._header_rows() + this._pane_h(); },

  _logo_w() {
    return LOGO_ROWS[0].length;
  },

  _ensure_gradient() {
    const w = this._logo_w();
    if (this._logo_gradient && this._logo_width === w) return;
    this._logo_width = w;
    this._logo_gradient = make_gradient(w, "#ff5500", "#ffcc00");
  },

  update(msg) {
    if (msg.kind === "window_size") {
      this.width  = msg.width;
      this.height = msg.height;
      this._logo_gradient = null; // recompute
      return;
    }

    if (msg.kind === "mouse" && msg.mouse.action === "press") {
      this.focused = msg.mouse.row >= this._input_row() ? "input" : "output";
      return;
    }

    if (msg.kind === "key") {
      const code = msg.code;
      const ph   = this._pane_h();

      if (code === "esc") {
        if (this.focused === "none") return tea.quit();
        this.focused = "none";
        return;
      }

      if (code === "tab") {
        this.focused = this.focused === "input" ? "output" : "input";
        return;
      }

      if (code === "up")        { this.scroll = Math.min(this.scroll + 1, Math.max(0, this.output.length - ph)); return; }
      if (code === "down")      { this.scroll = Math.max(0, this.scroll - 1); return; }
      if (code === "page_up")   { this.scroll = Math.min(this.scroll + Math.floor(ph / 2), Math.max(0, this.output.length - ph)); return; }
      if (code === "page_down") { this.scroll = Math.max(0, this.scroll - Math.floor(ph / 2)); return; }

      if (code === "c" && msg.ctrl) return tea.quit();

      if (this.loading) return;

      if (code === "enter") {
        const prompt = this.input.trim();
        if (prompt) this._send(prompt);
        return;
      }
      if (code === "backspace") { this.input = this.input.slice(0, -1); this.focused = "input"; return; }
      if (code.length === 1 && !msg.ctrl && !msg.alt) {
        this.input += code;
        this.focused = "input";
        return;
      }
    }
  },

  _send(prompt) {
    this.messages.push({ role: "user", content: prompt });
    this._push("", "normal");
    this._push("You: " + prompt, "normal");
    this._push("", "normal");
    this.input           = "";
    this.loading         = true;
    this.thinking        = false;
    this.responseContent = "";
    this.scroll          = 0;

    const msgs = [{ role: "system", content: SYSTEM_PROMPT }, ...this.messages];

    (async () => {
      try {
        const response = await fetch(API_URL, {
          method:  "POST",
          headers: {
            "Authorization": "Bearer " + API_KEY,
            "Content-Type":  "application/json",
          },
          body:   JSON.stringify({ model: MODEL, messages: msgs, max_completion_tokens: 2048, stream: true }),
          stream: true,
        });

        for await (const rawChunk of response.body) {
          this._onChunk(rawChunk);
        }

        this._finishStream();
      } catch (err) {
        this._push("Error: " + String(err), "dim");
        this._push("", "normal");
        this.loading = false;
      }
    })();
  },

  _onChunk(rawChunk) {
    let data;
    try { data = JSON.parse(rawChunk); } catch { return; }

    const delta = data?.choices?.[0]?.delta;
    if (!delta) return;

    const thinking_delta = delta.reasoning_content || "";
    const content_delta  = delta.content || "";

    if (thinking_delta) {
      if (!this.thinking) {
        this.thinking   = true;
        this.thinkStart = Date.now();
      }
      for (const part of thinking_delta.split("\n"))
        if (part.trim()) this._push("  " + part, "thinking");
      this.scroll = 0;
    }

    if (content_delta) {
      if (this.thinking) {
        this.thinking = false;
        const secs = Math.round((Date.now() - this.thinkStart) / 1000);
        this._push("", "normal");
        this._push("Thought for " + secs + " second" + (secs === 1 ? "" : "s"), "dim");
        this._push("", "normal");
        this._push("Assistant:", "normal");
      } else if (!this.responseContent) {
        this._push("Assistant:", "normal");
      }
      this.responseContent += content_delta;
      const max_w = this.width - 4;
      for (const raw_line of content_delta.split("\n")) {
        if (raw_line.length <= max_w) {
          this._push(raw_line, "normal");
        } else {
          let line = "";
          for (const word of raw_line.split(" ")) {
            if (line.length + word.length + 1 > max_w) { this._push(line, "normal"); line = word; }
            else line = line ? line + " " + word : word;
          }
          if (line) this._push(line, "normal");
        }
      }
      this.scroll = 0;
    }
  },

  _finishStream() {
    if (this.thinking) {
      this.thinking = false;
      const secs = Math.round((Date.now() - this.thinkStart) / 1000);
      this._push("", "normal");
      this._push("Thought for " + secs + " second" + (secs === 1 ? "" : "s"), "dim");
    }
    if (this.responseContent.trim())
      this.messages.push({ role: "assistant", content: this.responseContent.trim() });
    this._push("", "normal");
    this.loading = false;
    this.scroll  = 0;
  },

  view() {
    this._ensure_gradient();
    const pairs = logo_terminal_rows();
    const grad  = this._logo_gradient;
    const bg    = "#0a0a0f";
    const dim   = "#1a1a2a";

    // Build header lines: background pattern with logo overlaid on the left
    const logo_w = this._logo_w();
    const pad_cols = 2;   // left margin before logo
    const header_lines = [];
    for (let i = 0; i < pairs.length; i++) {
      const { upper, lower } = pairs[i];
      const logo_row = render_logo_row(upper, lower, grad, bg);
      // Fill remainder of terminal width with the bg pattern
      const after = Math.max(0, this.width - logo_w - pad_cols);
      const after_row = render_bg_row(after, i, dim, bg);
      const left_pad = render_bg_row(pad_cols, i, dim, bg);
      header_lines.push(left_pad + logo_row + after_row);
    }

    const GRAY  = "\x1b[38;5;240m";
    const DIM   = "\x1b[38;5;246m";
    const RESET = "\x1b[0m";

    const pane_h    = this._pane_h();
    const start     = Math.max(0, this.output.length - pane_h - this.scroll);
    const raw_lines = this.output.slice(start, start + pane_h);
    while (raw_lines.length < pane_h) raw_lines.push({ text: "", style: "normal" });

    const lines = raw_lines.map(l => {
      if (l.style === "thinking") return GRAY + l.text + RESET;
      if (l.style === "dim")      return DIM  + l.text + RESET;
      return l.text;
    });

    if (this.loading) {
      const label = DIM + (this.thinking ? " Thinking…" : " Waiting…") + RESET;
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i] || lines[i] === "") { lines[i] = label; break; }
      }
    }

    const input_focused  = this.focused === "input";
    const output_focused = this.focused === "output";
    const unfocused      = this.focused === "none";

    const output_fg = output_focused ? "#ffff00" : "#555555";
    const input_fg  = this.loading   ? "#888888"
                    : input_focused  ? "#ffff00"
                    :                  "#555555";

    const cursor = input_focused ? "█" : "";

    const input_box = this.loading
      ? h("box", { border: "rounded", fg: input_fg, height: 3, pad_x: 1 },
          h("stack", { horizontal: true, align: "center" },
            h("spinner", { fg: "#888888", width: 1 }),
            h("text",    { fg: "#888888" }, " thinking…"),
          ))
      : h("box", { border: "rounded", fg: input_fg, pad_x: 1, fit: true },
          "> " + this.input + cursor);

    // Header as a raw text box (ANSI strings rendered directly)
    const header_box = h("box", { height: this._header_rows(), bg: bg }, header_lines.join("\n"));

    const help_line = unfocused
      ? h("text", { fg: "#444444", fit: true }, `${GRAY}[esc]${RESET} quit  ${GRAY}[tab]${RESET} focus`)
      : h("text", { fg: "#444444", fit: true }, `${GRAY}[tab]${RESET} focus`);

    return h("stack", {},
      header_box,
      h("box", { border: "rounded", fg: output_fg, pad_x: 1 }, lines.join("\n")),
      input_box,
      help_line,
    );
  },
});
