// doom-fire.js — Doom fire using only <draw> with animate
//
// Classic doom fire: bottom row always white-hot, heat spreads upward
// with random drift. Two fire rows → one terminal cell via ▀ (upper half
// block) with fg (top pixel) and bg (bottom pixel) colors.
//
// Keys: q/esc = quit

import { tea, h } from "milktea";

const FIRE_COLORS = [
  [7,7,7],[31,7,7],[47,15,7],[71,15,7],[87,23,7],[103,31,7],[119,31,7],
  [143,39,7],[159,47,7],[175,63,7],[191,71,7],[199,71,7],[223,79,7],
  [223,87,7],[223,87,7],[215,95,7],[215,95,7],[215,103,15],[207,111,15],
  [207,119,15],[207,127,15],[207,135,23],[199,135,23],[199,143,23],
  [199,151,31],[191,159,31],[191,159,31],[191,167,39],[191,167,39],
  [191,175,47],[183,175,47],[183,183,47],[183,183,55],[207,207,111],
  [223,223,159],[239,239,199],[255,255,255],
];

function prng(s) {
  s = Math.imul(s, 1103515245) + 12345;
  return [s | 0, (s >>> 16) & 3];
}

tea.run({
  init() {
    this.w = 80;
    this.h = 48;
    this.seed = (Date.now() & 0x7fffffff) | 1;
    this.fire = new Int32Array(this.w * this.h);
    for (let x = 0; x < this.w; x++)
      this.fire[(this.h - 1) * this.w + x] = 36;
    this.frame = 0;
  },

  update(msg) {
    if (msg.kind === "window_size") {
      const W = Math.max(4, Math.min(msg.width, 200));
      const H = Math.max(4, Math.min(msg.height * 2, 200));
      this.w = W; this.h = H;
      this.fire = new Int32Array(W * H);
      for (let x = 0; x < W; x++)
        this.fire[(H - 1) * W + x] = 36;
      return;
    }
    if (msg.kind === "key") {
      if (msg.code === "q" || msg.code === "esc" || (msg.code === "c" && msg.ctrl))
        return tea.quit();
    }
  },

  _spread() {
    const f = this.fire, w = this.w, h = this.h;
    let s = this.seed;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const idx = y * w + x;
        if (idx < w) continue;
        const p = f[idx];
        if (p === 0) { f[idx - w] = 0; continue; }
        let r; [s, r] = prng(s);
        const dst = idx - r + 1;
        if (dst - w >= 0) {
          const v = p - (r & 1);
          f[dst - w] = v < 0 ? 0 : v;
        }
      }
    }
    this.seed = s;
  },

  view() {
    const self = this;
    const vh = this.h >> 1;
    this.frame++;

    return h("draw", { animate: 60, fn: (cw, ri) => {
      // Spread once per render (ri=0 = first row call)
      if (ri === 0) self._spread();

      const fy  = ri * 2;
      const fy2 = fy + 1;
      const cols = Math.min(cw, self.w);
      const f = self.fire, w = self.w;
      let out = "";
      for (let x = 0; x < cols; x++) {
        const t = FIRE_COLORS[f[fy * w + x] || 0];
        const b = FIRE_COLORS[f[fy2 * w + x] || 0];
        out += `\x1b[38;2;${t[0]};${t[1]};${t[2]};48;2;${b[0]};${b[1]};${b[2]}m▀`;
      }
      return out + "\x1b[0m";
    }});
  },
});
