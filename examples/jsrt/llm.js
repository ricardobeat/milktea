import { getenv } from "os";

const API_KEY = getenv("MINIMAX_API_KEY") || "";
const API_URL = "https://api.minimax.io/v1/chat/completions";
const MODEL = "MiniMax-M2.7";

const SYSTEM_PROMPT =
  "You are an expert coding assistant. Be concise and precise. " +
  "Format code blocks with markdown fences. Prefer short explanations.";

export class LLM {
  constructor(push) {
    this._push = push;
    this.messages = [];
    this.loading = false;
    this.thinking = false;
    this.thinkStart = 0;
    this.thinkSecs = 0;
    this.responseContent = "";
    this._contentBuffer = "";
    this._inThinkTag = false;
  }

  get apiKeyMissing() {
    return !API_KEY;
  }

  send(prompt) {
    this.messages.push({ role: "user", content: prompt });
    this._push("", "normal");
    this._push(prompt, "user");
    this._push("", "normal");
    this.loading = true;
    this.thinking = false;
    this.responseContent = "";

    const msgs = [{ role: "system", content: SYSTEM_PROMPT }, ...this.messages];

    (async () => {
      try {
        const response = await fetch(API_URL, {
          method: "POST",
          headers: {
            Authorization: "Bearer " + API_KEY,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ model: MODEL, messages: msgs, max_completion_tokens: 2048, stream: true }),
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
  }

  _onChunk(rawChunk) {
    let data;
    try {
      data = JSON.parse(rawChunk);
    } catch {
      return;
    }

    const delta = data?.choices?.[0]?.delta;
    if (!delta) return;

    const thinking_delta = delta.reasoning_content || "";
    const content_delta = delta.content || "";

    if (thinking_delta) {
      if (!this.thinking) {
        this.thinking = true;
        this.thinkStart = Date.now();
      }
      for (const part of thinking_delta.split("\n")) {
        if (part.trim()) this._push(part, "thinking");
      }
    }

    if (content_delta) {
      if (this.thinking && !this._inThinkTag) this._endThinking();
      this._contentBuffer += content_delta;
      this._flushContent();
    }
  }

  _flushContent() {
    while (this._contentBuffer.length > 0) {
      if (this._inThinkTag) {
        const idx = this._contentBuffer.indexOf("</think>");
        if (idx === -1) break;
        const chunk = this._contentBuffer.slice(0, idx);
        this._contentBuffer = this._contentBuffer.slice(idx + 8);
        this._inThinkTag = false;
        if (chunk.trim()) this._outputLines(chunk, "thinking");
        this._endThinking();
      } else {
        const idx = this._contentBuffer.indexOf("<think>");
        if (idx === -1) {
          this._outputLines(this._contentBuffer, "normal");
          this._contentBuffer = "";
          break;
        }
        const before = this._contentBuffer.slice(0, idx);
        this._contentBuffer = this._contentBuffer.slice(idx + 6);
        if (before) this._outputLines(before, "normal");
        this._inThinkTag = true;
        if (!this.thinking) {
          this.thinking = true;
          this.thinkStart = Date.now();
        }
      }
    }
  }

  _endThinking() {
    this.thinking = false;
    this.thinkSecs = Math.round((Date.now() - this.thinkStart) / 1000);
    this._push("", "thought_end");
  }

  _outputLines(text, style) {
    // trim leading blank lines from the very first normal output (models often start with \n\n)
    const isFirstNormal = style === "normal" && !this.responseContent;
    const trimmed = isFirstNormal ? text.replace(/^\n+/, "") : text;
    if (style === "normal") this.responseContent += trimmed;
    for (const line of trimmed.split("\n")) {
      this._push(line, style);
    }
  }

  _finishStream() {
    if (this._inThinkTag) {
      const chunk = this._contentBuffer;
      if (chunk.trim()) this._outputLines(chunk, "thinking");
      this._endThinking();
      this._contentBuffer = "";
      this._inThinkTag = false;
    } else if (this.thinking) {
      this._endThinking();
    }
    if (this.responseContent.trim()) this.messages.push({ role: "assistant", content: this.responseContent.trim() });
    this._push("", "normal");
    this.loading = false;
  }
}
