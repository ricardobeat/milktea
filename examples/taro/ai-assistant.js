// ai-assistant.js — AI coding assistant TUI using MiniMax API (streaming)
//
// Layout:
//   ┌─────────────────────────────┐
//   │  output (scrollable)        │
//   │  ...                        │
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
//
// Mouse:
//   Click output area — focus output (enables scroll keys)
//   Click input area  — focus input (enables typing)

import { tea, h } from "milktea";
import { getenv } from "os";

const API_KEY = getenv("MINIMAX_API_KEY") || "";
const API_URL = "https://api.minimax.io/v1/chat/completions";
const MODEL   = "MiniMax-M2.7";

const SYSTEM_PROMPT =
  "You are an expert coding assistant. Be concise and precise. " +
  "Format code blocks with markdown fences. Prefer short explanations.";

tea.run({
  init() {
    this.input      = "";
    this.messages   = [];
    this.output     = [];   // { text, style } — style: "normal" | "thinking" | "dim"
    this.scroll     = 0;
    this.loading    = false;
    this.width      = 80;
    this.height     = 24;
    this.focused    = "input"; // "input" | "output"

    this.thinking        = false;
    this.thinkStart      = 0;
    this.responseContent = "";

    if (!API_KEY) {
      this._push("⚠  MINIMAX_API_KEY is not set. Export it and restart.", "dim");
      this._push("", "normal");
      this._push("   export MINIMAX_API_KEY=your_key_here", "dim");
    } else {
      this._push("MiniMax AI Coding Assistant", "normal");
      this._push("─".repeat(40), "dim");
      this._push("Type a question and press Enter. Tab or click to switch focus.", "dim");
      this._push("", "normal");
    }
  },

  _push(text, style) {
    this.output.push({ text, style: style || "normal" });
  },

  _input_row() { return this.height - 3; },  // top row of input box

  update(msg) {
    if (msg.kind === "window_size") {
      this.width  = msg.width;
      this.height = msg.height;
      return;
    }

    if (msg.kind === "mouse" && msg.mouse.action === "press") {
      this.focused = msg.mouse.row >= this._input_row() ? "input" : "output";
      return;
    }

    if (msg.kind === "key") {
      const code = msg.code;
      const ph   = this._pane_h();

      // Tab cycles focus
      if (code === "tab") {
        this.focused = this.focused === "input" ? "output" : "input";
        return;
      }

      // Scroll always works regardless of focus
      if (code === "up")        { this.scroll = Math.min(this.scroll + 1, Math.max(0, this.output.length - ph)); return; }
      if (code === "down")      { this.scroll = Math.max(0, this.scroll - 1); return; }
      if (code === "page_up")   { this.scroll = Math.min(this.scroll + Math.floor(ph / 2), Math.max(0, this.output.length - ph)); return; }
      if (code === "page_down") { this.scroll = Math.max(0, this.scroll - Math.floor(ph / 2)); return; }

      if ((code === "c" && msg.ctrl) || (code === "q" && this.input === "")) return tea.quit();

      // Typing only when input is focused and not loading
      if (this.focused !== "input" || this.loading) return;

      if (code === "enter") {
        const prompt = this.input.trim();
        if (prompt) this._send(prompt);
        return;
      }
      if (code === "backspace") { this.input = this.input.slice(0, -1); return; }
      if (code.length === 1 && !msg.ctrl && !msg.alt) { this.input += code; return; }
    }
  },

  _pane_h() { return Math.max(1, this.height - 3); },

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
      const THINK_CLR = "\x1b[38;5;240m";
      const BORDER = `\x1b[38;2;60;60;70m▎\x1b[0m${THINK_CLR}`;
      const think_w = this.width - 4;
      for (const part of thinking_delta.split("\n")) {
        const trimmed = part.trim();
        if (!trimmed) continue;
        if (trimmed.length + 2 <= think_w) {
          this._push(BORDER + " " + trimmed, "thinking");
        } else {
          const inner_w = think_w - 2;
          const words = trimmed.split(" ");
          const lines = [];
          let line = "";
          for (const word of words) {
            if (line.length + word.length + 1 > inner_w && line) {
              lines.push(line);
              line = word;
            } else {
              line = line ? line + " " + word : word;
            }
          }
          if (line) lines.push(line);
          for (let i = 0; i < lines.length; i++) {
            this._push(i === 0 ? BORDER + " " + lines[i] : "  " + lines[i], "thinking");
          }
        }
      }
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
    const pane_h    = this._pane_h();
    const start     = Math.max(0, this.output.length - pane_h - this.scroll);
    const raw_lines = this.output.slice(start, start + pane_h);
    while (raw_lines.length < pane_h) raw_lines.push({ text: "", style: "normal" });

    const GRAY  = "\x1b[38;5;240m";
    const DIM   = "\x1b[38;5;246m";
    const RESET = "\x1b[0m";

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

    // Border colours: yellow = focused, gray = unfocused, gray = loading
    const output_fg = output_focused ? "#ffff00" : "#555555";
    const input_fg  = this.loading   ? "#888888"
                    : input_focused  ? "#ffff00"
                    :                  "#555555";

    const input_box = this.loading
      ? h("box", { border: "rounded", fg: input_fg, height: 3, pad_x: 1 },
          h("stack", { horizontal: true, align: "center" },
            h("spinner", { fg: "#888888", width: 1 }),
            h("text",    { fg: "#888888" }, " thinking…"),
          ))
      : h("box", { border: "rounded", fg: input_fg, height: 3, pad_x: 1 },
          "> " + this.input + (input_focused ? "▌" : ""));

    return h("stack", {},
      h("box", { border: "rounded", fg: output_fg, pad_x: 1 }, lines.join("\n")),
      input_box,
    );
  },
});
