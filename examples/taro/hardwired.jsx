// @jsx h
// hardwired.jsx — AI coding assistant TUI
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
//   Enter         — send prompt (Shift+Enter for newline)
//   Backspace     — delete char before cursor
//   Delete        — delete char at cursor
//   ←/→           — move cursor
//   Home/End      — jump to start/end of line
//   Tab           — cycle focus between output and input
//   ↑/↓           — scroll output (or move cursor in input)
//   PgUp/PgDn     — scroll output fast
//   Ctrl+A / E    — jump to start/end of input
//   Ctrl+C / q    — quit (only when input is empty)

import { tea, h } from "tea";
import { LLM } from "./llm.js";

// ── Markdown renderer ─────────────────────────────────────────────────────────

const MD_BOLD = "\x1b[1m";
const MD_ITALIC = "\x1b[3m";
const MD_RESET = "\x1b[0m";

function md_inline(text) {
  // bold+italic ***...*** or ___...___
  text = text.replace(/\*\*\*(.*?)\*\*\*/g, `${MD_BOLD}${MD_ITALIC}$1${MD_RESET}`);
  text = text.replace(/___(.*?)___/g, `${MD_BOLD}${MD_ITALIC}$1${MD_RESET}`);
  // bold **...** or __...__
  text = text.replace(/\*\*(.*?)\*\*/g, `${MD_BOLD}$1${MD_RESET}`);
  text = text.replace(/__(.*?)__/g, `${MD_BOLD}$1${MD_RESET}`);
  // italic *...* or _..._
  text = text.replace(/\*(.*?)\*/g, `${MD_ITALIC}$1${MD_RESET}`);
  text = text.replace(/_(.*?)_/g, `${MD_ITALIC}$1${MD_RESET}`);
  // inline code `...`
  text = text.replace(/`([^`]+)`/g, `\x1b[38;2;255;140;0m\x1b[48;2;35;35;40m$1${MD_RESET}`);
  return text;
}

function md_line(line, base_style) {
  // blockquote: > text — gray, indented
  if (/^>\s?/.test(line)) {
    const content = md_inline(line.replace(/^>\s?/, ""));
    return `  \x1b[38;2;90;90;100m${content}${MD_RESET}`;
  }
  return base_style + md_inline(line) + (base_style ? MD_RESET : "");
}

// ── Fire animation ────────────────────────────────────────────────────────────

// Fire palette: dark bg → deep red → orange → yellow → white tip
const FIRE_COLORS = [
  [10, 5, 2],
  [80, 10, 0],
  [160, 30, 0],
  [220, 80, 0],
  [255, 140, 0],
  [255, 200, 20],
  [255, 240, 120],
  [255, 255, 220],
];

function fire_color(t) {
  // t in [0,1]: 0=base (dark), 1=tip (white)
  const scaled = t * (FIRE_COLORS.length - 1);
  const i = Math.min(Math.floor(scaled), FIRE_COLORS.length - 2);
  const f = scaled - i;
  const a = FIRE_COLORS[i],
    b = FIRE_COLORS[i + 1];
  const r = Math.round(a[0] + (b[0] - a[0]) * f);
  const g = Math.round(a[1] + (b[1] - a[1]) * f);
  const bl = Math.round(a[2] + (b[2] - a[2]) * f);
  return `\x1b[38;2;${r};${g};${bl}m`;
}

// Fast hash for per-column flicker — no Math.random() so it's deterministic per frame
function fire_hash(col, t) {
  let x = (col * 374761393 + t * 668265263) | 0;
  x = ((x ^ (x >>> 13)) * 1274126177) | 0;
  return ((x ^ (x >>> 16)) >>> 0) / 0xffffffff;
}

// Eighth-block chars: smooth vertical fill from empty to full
const FIRE_CHARS = ["▖", "▗", "▘", "▙", "▛", "▜", "▝", "▞", "▟"];

function render_fire(w) {
  const t = Math.floor(Date.now() / 80);
  const RESET = "\x1b[0m";
  let out = "";
  const offset = t % FIRE_CHARS.length;
  for (let col = 0; col < w; col++) {
    const progress = col / Math.max(w - 1, 1);
    // Fade at both edges with a smooth bell curve
    const edge = Math.sin(progress * Math.PI);
    // Slow rightward drift: fire front advances over time
    const drift = (t * 0.15) % 1;
    const shifted = (progress + drift) % 1;
    // Core flame shape: two overlapping humps for irregular look
    const shape = Math.max(Math.exp(-((shifted - 0.4) ** 2) / 0.08), Math.exp(-((shifted - 0.75) ** 2) / 0.05) * 0.7);
    const noise = fire_hash(col, t) * 0.4 - 0.15;
    const heat = Math.max(0, Math.min(1, shape * edge + noise * edge));
    // const char_idx = Math.round(heat * (FIRE_CHARS.length - 1));
    const char_idx = (offset + col) % FIRE_CHARS.length;
    out += fire_color(heat) + FIRE_CHARS[char_idx];
  }
  return out + RESET;
}

const LOGO_ROWS = [
  "█   █ ▄▀▀▀▄ █▀▀▀▄ █▀▀▀▄ █   █ ▀▀█▀▀ █▀▀▀▄ █▀▀▀▀ █▀▀▀▄",
  "█▀▀▀█ █▀▀▀█ █▀█▀  █   █ █▄▀▄█   █   █▀█▀  █▀▀▀  █   █",
  "▀   ▀ ▀   ▀ ▀  ▀▀ ▀▀▀▀  ▀   ▀ ▀▀▀▀▀ ▀  ▀▀ ▀▀▀▀▀ ▀▀▀▀",
];

const COMPACT_LOGO_TEXT = "╱╱ HARDWIRED v0.1";

function hex_to_rgb(hex) {
  if (!hex || hex.length < 7) return "128;128;128";
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r};${g};${b}`;
}

// Build per-column gradient colors
function make_gradient(n_cols, from_hex, to_hex) {
  const colors = [];
  for (let i = 0; i < n_cols; i++) {
    const t = n_cols <= 1 ? 0 : i / (n_cols - 1);
    colors.push(blendLuv(from_hex, to_hex, t));
  }
  return colors;
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
    this.output = []; // { text, style } — style: "normal" | "thinking" | "dim"
    this.width = 80;
    this.height = 24;
    this.focused = "input"; // "input" | "output" | "none"

    this.llm = new LLM((text, style) => {
      if (style === "thought_end") {
        const secs = this.llm.thinkSecs;
        if (secs > 0)
          this.output.push({ text: "Thought for " + secs + " second" + (secs === 1 ? "" : "s"), style: "dim" });
        this.output.push({ text: "", style: "normal" });
        return;
      }
      this.output.push({ text, style: style || "normal" });
      tea.viewportScrollToBottom("output");
    });

    if (this.llm.apiKeyMissing) {
      this.llm._push("⚠  MINIMAX_API_KEY is not set. Export it and restart.", "dim");
      this.llm._push("", "normal");
      this.llm._push("   export MINIMAX_API_KEY=your_key_here", "dim");
    }
  },

  _compact() {
    return this.llm.messages.length > 0;
  },

  update(msg) {
    if (msg.kind === "window_size") {
      this.width = msg.width;
      this.height = msg.height;
      return;
    }

    if (msg.kind === "key") {
      const code = msg.code;

      if (code === "esc") {
        if (this.focused === "none") return tea.quit();
        this.focused = "none";
        return;
      }

      if (code === "tab") {
        this.focused = this.focused === "input" ? "output" : "input";
        return;
      }

      if (code === "c" && msg.ctrl) return tea.quit();

      // Forward scroll keys to viewport
      if (this.focused !== "input") {
        tea.viewportUpdate("output", {
          code,
          ctrl: msg.ctrl || false,
          alt: msg.alt || false,
          shift: msg.shift || false,
        });
        return;
      }

      if (this.llm.loading) return;

      if (this.focused === "input") {
        if (code === "enter" && !msg.shift) {
          const prompt = tea.textareaGetText("input").trim();
          if (prompt) {
            tea.textareaClear("input");
            this.llm.send(prompt);
          }
          return;
        }
        tea.textareaUpdate("input", {
          code,
          ctrl: msg.ctrl || false,
          alt: msg.alt || false,
          shift: msg.shift || false,
        });
        return;
      }
    }
  },

  view() {
    const GRAY = "\x1b[38;5;240m";
    const DIM = "\x1b[38;5;246m";
    const WHITE = "\x1b[38;5;255m";
    const RESET = "\x1b[0m";

    const input_focused = this.focused === "input";
    const output_focused = this.focused === "output";
    const unfocused = this.focused === "none";

    const output_fg = output_focused ? "#ff6600" : "#555555";
    const input_fg = this.llm.loading ? "#888888" : input_focused ? "#ff6600" : "#555555";

    const content_lines = this.output.map((l) => {
      if (l.style === "thinking") return md_line(l.text, `\x1b[38;2;80;80;90m`);
      if (l.style === "dim") return DIM + l.text + RESET;
      if (l.style === "user") return `\x1b[48;2;40;40;48m\x1b[38;2;200;200;210m ${l.text} ${RESET}`;
      return md_line(l.text, "");
    });

    return (
      <stack>
        <col height={this._compact() ? 1 : LOGO_ROWS.length}>{Header({ compact: this._compact() })}</col>
        <box border="rounded" borderColor={output_fg} pad={2}>
          <viewport id="output">
            {content_lines.join("\n") + "\n"}
            {this.llm.loading ? <draw width={24} fn={(w) => render_fire(w)} /> : null}
          </viewport>
        </box>
        <textarea
          id="input"
          border="rounded"
          borderColor={input_focused ? "#cc8822" : "#666666"}
          fg={input_fg}
          height={1}
          prompt="> "
          focused={input_focused}
        />
        {unfocused ? (
          <text fg="#444444" fit={true}>{`${GRAY}[esc]${RESET} quit  ${GRAY}[tab]${RESET} focus`}</text>
        ) : (
          <text fg="#444444" fit={true}>{`${GRAY}[tab]${RESET} focus`}</text>
        )}
      </stack>
    );
  },
});

const gradient = make_gradient([...LOGO_ROWS[0]].length, "#ff5500", "#ffcc00");
const bg = "#0a0a0f";
const dim = "#1a1a2a";

// Render one logo row with per-character gradient coloring.
// Spaces get background color as both fg and bg (invisible).
function render_logo_row(row, gradient, bg_hex) {
  const RESET = "\x1b[0m";
  // Use [...row] to split by Unicode codepoint (block chars are single codepoints)
  const chars = [...row];
  let out = `\x1b[48;2;${hex_to_rgb(bg_hex)}m`;
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    const fg = gradient[Math.min(i, gradient.length - 1)];
    if (ch === " ") {
      out += " ";
    } else {
      out += `\x1b[38;2;${hex_to_rgb(fg)}m${ch}`;
    }
  }
  out += RESET;
  return out;
}

function Header({ compact }) {
  return compact
    ? [
        <row height={1}>
          <draw width={4} fn={(width, index) => render_bg_row(width, index, dim, bg)} />
          <draw width={COMPACT_LOGO_TEXT.length} fn={() => render_logo_row(COMPACT_LOGO_TEXT, gradient, bg)} />
          <draw fn={(cw, ri) => render_bg_row(cw, ri, dim, bg)} />
        </row>,
      ]
    : LOGO_ROWS.map((row, i) => (
        <row height={1}>
          <draw width={4} fn={(cw, ri) => render_bg_row(cw, ri, dim, bg)} />
          <draw width={LOGO_ROWS[0].length} fn={() => render_logo_row(row, gradient, bg)} />
          <draw fn={(cw, ri) => render_bg_row(cw, ri, dim, bg)} />
        </row>
      ));
}
