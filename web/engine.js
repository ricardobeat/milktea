// A small Canvas2D host for the C3 cell grid. No terminal emulator or bundler.
import {drawLegacyGlyph} from './glyphs.js';
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const modules = new Map();
export async function loadMilkteaModule(url) {
  const key = new URL(url, globalThis.document?.baseURI ?? import.meta.url).href;
  if (!modules.has(key)) {
    const pending = (async () => {
      const response = await fetch(key, {cache: 'no-cache'});
      if (!response.ok) throw new Error(`Could not load ${key}: HTTP ${response.status}`);
      return WebAssembly.compile(await response.arrayBuffer());
    })();
    modules.set(key, pending);
    pending.catch(() => { if (modules.get(key) === pending) modules.delete(key); });
  }
  return modules.get(key);
}
const ANSI = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
  '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff'];
const KEYS = {Enter: 2, Backspace: 3, Escape: 4, Tab: 5, ArrowUp: 6, ArrowDown: 7,
  ArrowLeft: 8, ArrowRight: 9, Home: 10, End: 11, Delete: 12, PageUp: 13, PageDown: 14, Insert: 15};
for (let i = 1; i <= 12; i++) KEYS[`F${i}`] = 15 + i;
export function translateKey(event) {
  if (event.isComposing || event.key === 'Dead' || event.metaKey) return null;
  const mods = (event.ctrlKey ? 1 : 0) | (event.altKey ? 2 : 0) | (event.shiftKey ? 4 : 0);
  if (event.ctrlKey && event.key.toLowerCase() === 'c') return [28, 0, mods];
  if (KEYS[event.key]) return [KEYS[event.key], 0, mods];
  if ([...event.key].length === 1) return [1, event.key.codePointAt(0), mods];
  return null;
}

export function createRandom(seed = 1) {
  let state = seed >>> 0;
  return () => {
    // Mulberry32 mixes the output bits before returning a nonnegative C int.
    // Consumers use rand() % n, so short cycles in low bits are visible.
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), state | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return (value ^ (value >>> 14)) >>> 1;
  };
}

export async function instantiateMilktea(bytes, {now, wall = Date.now, log = console.log, callbacks = {}} = {}) {
  const start = performance.now();
  let instance;
  let random = createRandom();
  const imports = {
    milktea_js: callbacks,
    milktea: {math_sin: Math.sin, math_cos: Math.cos, now: now ?? (() => performance.now() - start), wall,
      log: (ptr, len) => log(decoder.decode(new Uint8Array(instance.exports.memory.buffer, ptr, len)))},
    env: {pow: Math.pow, powf: (x, y) => Math.fround(Math.pow(x, y)),
      fminf: Math.min, fmaxf: Math.max, c3_sin: Math.sin, c3_cos: Math.cos,
      c3_time_ms_long: () => BigInt(Math.floor(wall())),
      srand: seed => { random = createRandom(seed); },
      rand: () => random(),
      // The component viewer's filesystem tab sees an empty directory.
      c3_list_dir: () => 0,
      // c3c 0.8.5's wasm32 stdlib links these Emscripten hooks; nothing calls
      // them in the cell renderer, so they are no-ops.
      emscripten_run_script: () => {}, emscripten_set_canvas_element_size: () => 0,
      emscripten_request_pointerlock: () => 0, emscripten_exit_pointerlock: () => 0},
  };
  const module = bytes instanceof WebAssembly.Module ? bytes : await WebAssembly.compile(bytes);
  for (const {module: mod, name, kind} of WebAssembly.Module.imports(module)) {
    if (kind !== 'function' || typeof imports[mod]?.[name] !== 'function') {
      throw new Error(`Unsupported browser import: ${mod}.${name}`);
    }
  }
  instance = await WebAssembly.instantiate(module, imports);
  instance.exports._initialize();
  return instance.exports;
}

export function readGrid(wasm) {
  // Memory may have grown in update/view. Acquire a fresh view each frame.
  const bytes = new Uint8Array(wasm.memory.buffer);
  return {bytes, ptr: wasm.mt_cells(), cols: wasm.mt_width(), rows: wasm.mt_height(),
    stride: wasm.mt_cell_size(), style: wasm.mt_style_offset(),
    attrs: wasm.mt_attrs_offset(), colorSize: wasm.mt_color_size()};
}
export function gridText(wasm) {
  const g = readGrid(wasm);
  return Array.from({length: g.rows}, (_, y) => Array.from({length: g.cols}, (_, x) => {
    const p = g.ptr + (y * g.cols + x) * g.stride;
    return decoder.decode(g.bytes.subarray(p, p + g.bytes[p + 8]));
  }).join('')).join('\n');
}
function palette(index) {
  if (index < 16) return ANSI[index];
  if (index >= 232) { const v = 8 + (index - 232) * 10; return `rgb(${v},${v},${v})`; }
  const n = index - 16, levels = [0, 95, 135, 175, 215, 255];
  return `rgb(${levels[Math.floor(n / 36)]},${levels[Math.floor(n / 6) % 6]},${levels[n % 6]})`;
}
export function cellColor(bytes, p, fallback) {
  const kind = bytes[p];
  if (kind === 1 || kind === 2) return palette(bytes[p + 1]);
  if (kind === 3) return `rgba(${bytes[p + 2]},${bytes[p + 3]},${bytes[p + 4]},${(bytes[p + 5] || 255) / 255})`;
  return fallback;
}
// Block glyphs are geometry so half-block games have no font gaps.
function block(ctx, cp, x, y, w, h, fillRect) {
  if (cp === 0x2580) fillRect(x, y, w, h / 2);
  else if (cp >= 0x2581 && cp <= 0x2588) { const size = (cp - 0x2580) / 8; fillRect(x, y + h * (1 - size), w, h * size); }
  else if (cp >= 0x2589 && cp <= 0x258f) fillRect(x, y, w * (0x2590 - cp) / 8, h);
  else if (cp === 0x2590) fillRect(x + w / 2, y, w / 2, h);
  else if (cp === 0x2594) fillRect(x, y, w, h / 8);
  else if (cp === 0x2595) fillRect(x + w * 7 / 8, y, w / 8, h);
  else if (cp >= 0x2591 && cp <= 0x2593) {
    ctx.globalAlpha *= (cp - 0x2590) / 4; fillRect(x, y, w, h);
  } else if (cp >= 0x2596 && cp <= 0x259f) {
    const masks = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];
    const mask = masks[cp - 0x2596];
    for (let i = 0; i < 4; i++) if (mask & (1 << i)) fillRect(x + (i % 2) * w / 2, y + Math.floor(i / 2) * h / 2, w / 2, h / 2);
  } else if (cp >= 0x2800 && cp <= 0x28ff) {
    const bits = cp - 0x2800;
    const dots = [[0,0],[0,1],[0,2],[1,0],[1,1],[1,2],[0,3],[1,3]];
    dots.forEach(([col,row], i) => { if (bits & (1 << i)) {
      ctx.beginPath(); ctx.ellipse(x + w * (col ? .72 : .28), y + h * (row + .5) / 4, w * .12, h * .07, 0, 0, Math.PI * 2); ctx.fill();
    }});
  } else return false;
  return true;
}

export function canvasOptions(options = {}) {
  const result = {fontSize: 16, scale: 1, cols: null, rows: null, fit: 'contain',
    font: 'ui-monospace, "SFMono-Regular", Consolas, "Liberation Mono", monospace',
    foreground: '#e5e5e5', background: '#111318', onQuit: () => {}, onError: console.error, ...options};
  result.cellWidth ??= result.fontSize * .625;
  result.cellHeight ??= result.fontSize * 1.25;
  for (const key of ['fontSize', 'cellWidth', 'cellHeight', 'scale']) {
    if (!Number.isFinite(result[key]) || result[key] <= 0) throw new RangeError(`${key} must be positive and finite`);
  }
  if ((result.cols == null) !== (result.rows == null)) throw new RangeError('Set both cols and rows, or neither');
  if (result.cols != null) {
    for (const [key, limit] of [['cols', 512], ['rows', 256]]) {
      if (!Number.isInteger(result[key]) || result[key] < 1 || result[key] > limit) throw new RangeError(`${key} must be an integer from 1 to ${limit}`);
    }
  }
  if (!['contain', 'cover', 'stretch', 'none'].includes(result.fit)) throw new RangeError('fit must be contain, cover, stretch, or none');
  return result;
}

export function canvasViewport(width, height, options) {
  const {cellWidth: cw, cellHeight: ch, scale, fit} = options;
  const fixed = options.cols != null;
  const cols = fixed ? options.cols : Math.max(1, Math.min(512, Math.floor(width / (cw * scale))));
  const rows = fixed ? options.rows : Math.max(1, Math.min(256, Math.floor(height / (ch * scale))));
  const logicalWidth = cols * cw, logicalHeight = rows * ch;
  let scaleX = scale, scaleY = scale;
  if (fixed && width > 0 && height > 0) {
    const sx = width / logicalWidth, sy = height / logicalHeight;
    if (fit === 'stretch') { scaleX *= sx; scaleY *= sy; }
    else if (fit !== 'none') {
      const fitted = fit === 'cover' ? Math.max(sx, sy) : Math.min(sx, sy);
      scaleX *= fitted; scaleY *= fitted;
    }
  }
  return {width, height, cols, rows, scaleX, scaleY,
    offsetX: fixed ? (width - logicalWidth * scaleX) / 2 : 0,
    offsetY: fixed ? (height - logicalHeight * scaleY) / 2 : 0};
}

// Keep square pixels while expanding the grid to the fullscreen aspect ratio.
// Cells are 20% denser than simply fitting the original grid to the screen.
export function fullscreenGrid(width, height, cols, rows, cellWidth, cellHeight) {
  const fit = Math.min(width / (cols * cellWidth), height / (rows * cellHeight));
  if (!(fit > 0)) return {cols, rows};
  const scale = fit / 1.2;
  return {
    cols: Math.max(1, Math.min(512, Math.round(width / (cellWidth * scale)))),
    rows: Math.max(1, Math.min(256, Math.round(height / (cellHeight * scale)))),
  };
}

export function canvasPointer(rect, viewport, event, cw, ch) {
  // Normalize against the displayed rect as well: CSS transforms may scale it.
  const x = (event.clientX - rect.left) * viewport.width / rect.width;
  const y = (event.clientY - rect.top) * viewport.height / rect.height;
  const px = Math.floor((x - viewport.offsetX) / viewport.scaleX);
  const py = Math.floor((y - viewport.offsetY) / viewport.scaleY);
  return {px, py, col: Math.floor(px / cw), row: Math.floor(py / ch)};
}

export class MilkteaCanvas {
  constructor(canvas, wasm, options = {}) {
    this.canvas = canvas; this.wasm = wasm; this.ctx = canvas.getContext('2d');
    this.options = {...options};
    this.settings = canvasOptions(this.options);
    const {cols, rows, ...rendering} = this.settings;
    Object.assign(this, rendering);
    this.events = new AbortController();
    this.stopped = false;
    this.blink = -1;
    canvas.tabIndex = 0;
    canvas.style.touchAction = 'none';
    this.listen();
    this.resize();
    wasm.mt_boot();
    this.observer = new ResizeObserver(() => this.resize());
    this.observer.observe(canvas);
    this.paused = true;
    if (options.autoStart !== false) this.resume();
  }
  static async load(canvas, url, options) {
    return new MilkteaCanvas(canvas, await instantiateMilktea(await loadMilkteaModule(url)), options);
  }
  setOptions(options) {
    const merged = {...this.options, ...options};
    const normalized = canvasOptions(merged);
    this.options = merged;
    this.settings = normalized;
    const {cols, rows, ...rendering} = normalized;
    Object.assign(this, rendering);
    this.repaint = true;
    this.resize();
    return this;
  }
  pause() {
    this.paused = true;
    cancelAnimationFrame(this.raf);
    this.raf = null;
  }
  resume() {
    if (this.stopped || this.paused === false) return;
    this.paused = false;
    this.raf = requestAnimationFrame(time => this.frame(time));
  }
  resize() {
    if (this.stopped) return;
    const width = this.canvas.clientWidth, height = this.canvas.clientHeight;
    this.viewport = canvasViewport(width, height, this.settings);
    const {cols, rows} = this.viewport;
    const dpr = window.devicePixelRatio || 1;
    const backingWidth = Math.round(width * dpr), backingHeight = Math.round(height * dpr);
    if (this.canvas.width !== backingWidth || this.canvas.height !== backingHeight) {
      this.canvas.width = backingWidth; this.canvas.height = backingHeight; this.repaint = true;
    }
    this.dpr = dpr;
    if (cols !== this.cols || rows !== this.rows || this.cellWidth !== this.lastCellWidth || this.cellHeight !== this.lastCellHeight) {
      this.cols = cols; this.rows = rows;
      this.lastCellWidth = this.cellWidth; this.lastCellHeight = this.cellHeight;
      this.wasm.mt_resize(cols, rows, Math.max(1, Math.round(this.cellWidth)), Math.max(1, Math.round(this.cellHeight)));
    }
    this.repaint = true;
  }
  listen() {
    const on = (name, handler, opts = {}) => this.canvas.addEventListener(name, handler, {...opts, signal: this.events.signal});
    on('keydown', e => {
      // Preserve browser paste. The paste event supplies the complete text.
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'v') return;
      const key = translateKey(e);
      if (key) { e.preventDefault(); this.wasm.mt_key(...key, e.repeat ? 1 : 0); }
    });
    on('keyup', e => { const key = translateKey(e); if (key) this.wasm.mt_key(...key, 2); });
    on('compositionend', e => {
      for (const ch of e.data) this.wasm.mt_key(1, ch.codePointAt(0), 0, 0);
    });
    on('paste', e => {
      e.preventDefault(); const bytes = encoder.encode(e.clipboardData.getData('text/plain'));
      if (!bytes.length) return;
      const ptr = this.wasm.mt_alloc(bytes.length);
      new Uint8Array(this.wasm.memory.buffer, ptr, bytes.length).set(bytes);
      this.wasm.mt_paste(ptr, bytes.length);
    });
    on('focus', () => this.wasm.mt_focus(1));
    on('blur', () => this.wasm.mt_focus(0));
    const pointer = (e, button, action) => {
      const r = this.canvas.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const {px, py, col, row} = canvasPointer(r, this.viewport, e, this.cellWidth, this.cellHeight);
      this.wasm.mt_mouse(button, action, col, row, px, py,
        (e.ctrlKey ? 1 : 0) | (e.altKey ? 2 : 0) | (e.shiftKey ? 4 : 0));
    };
    on('pointerdown', e => { this.canvas.focus(); this.canvas.setPointerCapture(e.pointerId); pointer(e, e.button, 0); });
    on('pointerup', e => { pointer(e, e.button, 1); if (this.canvas.hasPointerCapture(e.pointerId)) this.canvas.releasePointerCapture(e.pointerId); });
    on('pointercancel', e => pointer(e, 3, 1));
    on('pointermove', e => pointer(e, e.buttons & 1 ? 0 : e.buttons & 4 ? 1 : e.buttons & 2 ? 2 : 3, 2));
    on('wheel', e => {
      if (e.deltaY && this.canvas.getRootNode().activeElement === this.canvas) {
        e.preventDefault(); pointer(e, e.deltaY < 0 ? 4 : 5, 0);
      }
    }, {passive: false});
    on('contextmenu', e => e.preventDefault());
  }
  frame(time) {
    if (this.stopped || this.paused) return;
    try {
      if (this.dpr !== (window.devicePixelRatio || 1)) this.resize();
      const state = this.wasm.mt_frame();
      if (!state) { this.stop(); this.onQuit(); return; }
      const blink = Math.floor(time / 500) % 2;
      if (state === 2 || this.repaint || blink !== this.blink) this.paint(blink, true);
      this.blink = blink; this.repaint = false;
      this.raf = requestAnimationFrame(t => this.frame(t));
    } catch (error) { this.stop(); this.onError(error); }
  }
  paint(blink, incremental = false) {
    const g = readGrid(this.wasm), ctx = this.ctx, cw = this.cellWidth, ch = this.cellHeight;
    const v = this.viewport, dpr = this.dpr, total = g.cols * g.rows;
    const full = !incremental || this.repaint || !this.wasm.mt_dirty_cells || this.wasm.mt_full_redraw();
    let dirty = null;
    const cursorX = this.wasm.mt_cursor_x(), cursorY = this.wasm.mt_cursor_y();
    if (!full) {
      dirty = new Set(new Uint32Array(this.wasm.memory.buffer, this.wasm.mt_dirty_cells(), this.wasm.mt_dirty_count()));
      const include = i => {
        if (i < 0 || i >= total) return;
        dirty.add(i);
        const width = g.bytes[g.ptr + i * g.stride + 9];
        if (width === 0 && i % g.cols > 0) dirty.add(i - 1);
        if (width === 2 && i % g.cols + 1 < g.cols) dirty.add(i + 1);
      };
      // Restore the old cursor before drawing the new XOR cursor, even when
      // the cells beneath it did not change in the model.
      if (this.paintedCursor != null) include(this.paintedCursor);
      if (cursorX >= 0) include(cursorY * g.cols + cursorX);
      if (blink !== this.blink) {
        for (let i = 0; i < total; i++) {
          if (g.bytes[g.ptr + i * g.stride + g.style + g.attrs] & 16) include(i);
        }
      }
      dirty = [...dirty].sort((a, b) => a - b);
    }
    const count = full ? total : dirty.length;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.globalAlpha = 1; ctx.fillStyle = this.background;
    if (full) {
      ctx.clearRect(0, 0, v.width, v.height);
      ctx.fillRect(0, 0, v.width, v.height);
    }
    ctx.setTransform(dpr * v.scaleX, 0, 0, dpr * v.scaleY, dpr * v.offsetX, dpr * v.offsetY);
    // Fractional fit/zoom and DPR put cell edges between backing pixels.
    // Round shared edges identically so adjacent fills and clips tile without
    // antialiasing seams. Keep text and pointer coordinates in logical units.
    const sx = dpr * v.scaleX, sy = dpr * v.scaleY;
    const ox = dpr * v.offsetX, oy = dpr * v.offsetY;
    // Equivalent shared edges can differ by a few floating-point bits at
    // exactly half a pixel (e.g. 139 * 9.6 + 9.6 versus 140 * 9.6).
    // Resolve these ties consistently for both fills and glyph clips.
    const snap = value => Math.floor(value + 0.5 + 1e-7);
    const pixelRect = (x, y, w, h, clear = false) => {
      const left = snap(x * sx + ox), top = snap(y * sy + oy);
      if (clear) ctx.clearRect(left, top, snap((x + w) * sx + ox) - left, snap((y + h) * sy + oy) - top);
      else ctx.fillRect(left, top, snap((x + w) * sx + ox) - left, snap((y + h) * sy + oy) - top);
    };
    const fillRect = (x, y, w, h) => {
      // Draw directly in backing pixels to avoid transform-rounding seams.
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      pixelRect(x, y, w, h);
      ctx.setTransform(sx, 0, 0, sy, ox, oy);
    };
    // Backgrounds first: a continuation cell must not erase a wide glyph.
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    for (let n = 0; n < count; n++) {
      const i = full ? n : dirty[n];
      const p = g.ptr + i * g.stride, s = p + g.style, attrs = g.bytes[s + g.attrs];
      if (!full) {
        // A translucent background must be composited over the base color,
        // not repeatedly over the previous frame.
        pixelRect((i % g.cols) * cw, Math.floor(i / g.cols) * ch, cw, ch, true);
        ctx.fillStyle = this.background;
        pixelRect((i % g.cols) * cw, Math.floor(i / g.cols) * ch, cw, ch);
      }
      ctx.fillStyle = cellColor(g.bytes, s + (attrs & 32 ? 0 : g.colorSize), attrs & 32 ? this.foreground : this.background);
      pixelRect((i % g.cols) * cw, Math.floor(i / g.cols) * ch, cw, ch);
    }
    ctx.setTransform(sx, 0, 0, sy, ox, oy);
    ctx.textBaseline = 'middle';
    for (let n = 0; n < count; n++) {
      const i = full ? n : dirty[n];
      const p = g.ptr + i * g.stride, len = g.bytes[p + 8], width = g.bytes[p + 9];
      if (!width || !len) continue;
      const s = p + g.style, attrs = g.bytes[s + g.attrs];
      if ((attrs & 16) && blink) continue;
      const x = (i % g.cols) * cw, y = Math.floor(i / g.cols) * ch;
      // Fire and pixel canvases predominantly use ▀, ▄ and █. These shapes
      // stay inside their cell and need neither text decoding nor a clip/font.
      const last = g.bytes[p + 2];
      if (!(attrs & (8 | 64)) && len === 3 && g.bytes[p] === 0xe2 &&
          g.bytes[p + 1] === 0x96 && (last === 0x80 || last === 0x84 || last === 0x88)) {
        ctx.globalAlpha = attrs & 2 ? .5 : 1;
        ctx.fillStyle = cellColor(g.bytes, s + (attrs & 32 ? g.colorSize : 0), attrs & 32 ? this.background : this.foreground);
        fillRect(x, y + (last === 0x84 ? ch / 2 : 0), cw * width, last === 0x88 ? ch : ch / 2);
        ctx.globalAlpha = 1;
        continue;
      }
      const text = decoder.decode(g.bytes.subarray(p, p + len));
      ctx.save(); ctx.beginPath();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      const left = snap(x * sx + ox), top = snap(y * sy + oy);
      ctx.rect(left, top, snap((x + cw * width) * sx + ox) - left, snap((y + ch) * sy + oy) - top);
      ctx.clip();
      ctx.setTransform(sx, 0, 0, sy, ox, oy);
      ctx.globalAlpha = attrs & 2 ? .5 : 1;
      ctx.fillStyle = cellColor(g.bytes, s + (attrs & 32 ? g.colorSize : 0), attrs & 32 ? this.background : this.foreground);
      ctx.font = `${attrs & 4 ? 'italic ' : ''}${attrs & 1 ? 'bold ' : ''}${this.fontSize}px ${this.font}`;
      const cp = text.codePointAt(0);
      if (cp >= 0x1fb00 && cp <= 0x1fb6f) {
        // Legacy polygons/sextants share the same integer cell boundaries as
        // backgrounds and clips. Logical-coordinate edges leave hairline gaps.
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        drawLegacyGlyph(ctx, cp, left, top, snap((x + cw * width) * sx + ox) - left,
          snap((y + ch) * sy + oy) - top, snap);
        ctx.setTransform(sx, 0, 0, sy, ox, oy);
      } else if (!block(ctx, cp, x, y, cw * width, ch, fillRect)) ctx.fillText(text, x, y + ch / 2, cw * width);
      if (attrs & 8) ctx.fillRect(x, y + ch - 2, cw * width, 1);
      if (attrs & 64) ctx.fillRect(x, y + ch / 2, cw * width, 1);
      ctx.restore();
    }
    const x = cursorX, y = cursorY;
    if (x >= 0 && (!this.wasm.mt_cursor_blink() || !blink)) {
      const shape = this.wasm.mt_cursor_shape();
      ctx.save(); ctx.globalCompositeOperation = 'difference'; ctx.fillStyle = '#ffffff';
      fillRect(x * cw, y * ch + (shape === 1 ? ch - 2 : 0), shape === 2 ? 2 : cw, shape === 1 ? 2 : ch);
      ctx.restore();
    }
    this.paintedCursor = x >= 0 ? y * g.cols + x : null;
    const cursor = decoder.decode(g.bytes.subarray(this.wasm.mt_mouse_cursor(), this.wasm.mt_mouse_cursor() + this.wasm.mt_mouse_cursor_len()));
    this.canvas.style.cursor = cursor || 'default';
  }
  stop() {
    if (this.stopped) return;
    this.stopped = true;
    cancelAnimationFrame(this.raf); this.observer?.disconnect(); this.events.abort();
    this.wasm.mt_stop();
  }
}
