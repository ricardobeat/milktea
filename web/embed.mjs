import {MilkteaCanvas, instantiateMilktea, loadMilkteaModule, canvasOptions, canvasViewport} from './engine.mjs';

// Import this module once, then place <milktea-view src="…wasm"> in any page.
export class MilkteaView extends HTMLElement {
  static observedAttributes = ['src', 'loading', 'cols', 'rows', 'font-size', 'cell-width', 'cell-height', 'scale', 'fit', 'font', 'foreground', 'background', 'label', 'expandable'];
  constructor() {
    super();
    this.attachShadow({mode: 'open'}).innerHTML = `
      <style>
        :host { display: inline-block; position: relative; width: 100%; height: 240px; vertical-align: middle; background: #111318; }
        :host([hidden]) { display: none; }
        :host(:fullscreen) { width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important; margin: 0 !important; border: 0 !important; border-radius: 0 !important; }
        .frame { position: relative; width: 100%; height: 100%; overflow: hidden; background: inherit; }
        canvas { display: block; position: absolute; inset: 0; width: 100%; height: 100%; padding: 0; border: 0; outline: none; }
        canvas:focus-visible { outline: 1px solid #9b7eaa; outline-offset: -2px; }
        .status { position: absolute; inset: 0; display: grid; place-items: center; color: #aaa; font: 13px system-ui, sans-serif; pointer-events: none; padding: 16px; text-align: center; }
        .status[hidden], button[hidden] { display: none; }
        button { position: absolute; bottom: 8px; right: 8px; width: 30px; height: 30px; display: grid; place-items: center; background: #161a22d9; color: #eee; border: 1px solid #ffffff30; border-radius: 6px; cursor: pointer; }
        button:hover { background: #353047; } button:focus-visible { outline: 2px solid #e4b2d6; }
        svg { width: 16px; height: 16px; pointer-events: none; }
      </style>
      <div class="frame" part="frame">
        <canvas part="canvas"></canvas>
        <div class="status" part="status" role="status">Ready when you scroll into view</div>
        <button part="expand-button" type="button" aria-label="Enter fullscreen" title="Enter fullscreen" aria-expanded="false">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/></svg>
        </button>
      </div>`;
    this.canvas = this.shadowRoot.querySelector('canvas');
    this.status = this.shadowRoot.querySelector('.status');
    this.button = this.shadowRoot.querySelector('button');
    this.generation = 0;
    this.visibilityChanged = () => this.updatePlayback();
    this.button.addEventListener('click', () => this.toggleFullscreen().catch(error => this.reportError(error)));
    // Do not deliver Escape as QUIT to the example when leaving fullscreen.
    this.shadowRoot.addEventListener('keydown', event => {
      if (event.key === 'Escape' && this.expanded) {
        event.preventDefault(); event.stopPropagation();
        this.ownerDocument.exitFullscreen().catch(error => this.reportError(error));
      }
    }, {capture: true});
    this.fullscreenChanged = () => {
      if (!this.expanded) this.fullscreenViewport = null;
      const label = this.expanded ? 'Exit fullscreen' : 'Enter fullscreen';
      this.button.setAttribute('aria-label', label); this.button.title = label;
      this.button.setAttribute('aria-expanded', String(this.expanded));
      this.applyOptions();
      this.updatePlayback();
      if (this.expanded) this.canvas.focus();
    };
  }
  get expanded() { return this.ownerDocument.fullscreenElement === this; }
  get engine() { return this.app ?? null; }
  restart() {
    this.release();
    if (this.isConnected && (this.visible || this.expanded || this.getAttribute('loading') === 'eager')) {
      void this.ensureLoaded();
    }
  }
  connectedCallback() {
    this.ownerDocument.addEventListener('fullscreenchange', this.fullscreenChanged);
    this.ownerDocument.addEventListener('visibilitychange', this.visibilityChanged);
    this.visible = false;
    this.observer = new IntersectionObserver(entries => {
      const entry = entries.at(-1);
      this.visible = entry.isIntersecting && entry.intersectionRect.width > 0 && entry.intersectionRect.height > 0;
      if (this.visible || this.expanded) void this.ensureLoaded();
      this.updatePlayback();
    });
    this.observer.observe(this);
    this.applyOptions();
    if (this.getAttribute('loading') === 'eager') void this.ensureLoaded();
  }
  disconnectedCallback() {
    this.observer?.disconnect();
    this.ownerDocument.removeEventListener('fullscreenchange', this.fullscreenChanged);
    this.ownerDocument.removeEventListener('visibilitychange', this.visibilityChanged);
    this.release();
  }
  attributeChangedCallback(name, oldValue, newValue) {
    if (oldValue === newValue || !this.isConnected) return;
    if (name === 'src') {
      this.release();
      if (this.visible || this.expanded || this.getAttribute('loading') === 'eager') void this.ensureLoaded();
    } else if (name === 'loading') {
      if (newValue === 'eager') void this.ensureLoaded();
    } else {
      // Batch attribute edits, e.g. removing cols and rows together.
      if (!this.optionsPending) {
        this.optionsPending = true;
        queueMicrotask(() => {
          this.optionsPending = false;
          if (!this.isConnected) return;
          try { this.applyOptions(); } catch (error) { this.reportError(error); }
        });
      }
    }
  }
  options() {
    const options = {};
    for (const [attribute, key] of [['cols','cols'], ['rows','rows'], ['font-size','fontSize'],
      ['cell-width','cellWidth'], ['cell-height','cellHeight'], ['scale','scale']]) {
      if (this.hasAttribute(attribute)) options[key] = Number(this.getAttribute(attribute));
    }
    for (const key of ['fit', 'font', 'foreground', 'background']) {
      if (this.hasAttribute(key)) options[key] = this.getAttribute(key);
    }
    // Fullscreen fits the same logical grid to retain the running model.
    if (this.expanded && this.fullscreenViewport) Object.assign(options, this.fullscreenViewport, {fit: 'contain', scale: 1});
    return options;
  }
  applyOptions() {
    this.canvas.setAttribute('aria-label', this.getAttribute('label') || 'Interactive milktea example');
    this.button.hidden = this.getAttribute('expandable') === 'false';
    const options = this.options();
    canvasOptions(options); // Validate before loading a module.
    if (this.app) {
      // Replace the options so removing attributes restores automatic sizing.
      this.app.options = {};
      this.app.setOptions({...options, onQuit: this.app.onQuit, onError: this.app.onError});
      if (!this.app.stopped) this.status.hidden = true;
    }
  }
  async ensureLoaded() {
    if (this.app || this.pending || !this.isConnected) return;
    const src = this.getAttribute('src');
    if (!src) return;
    const generation = this.generation;
    this.pending = true;
    this.status.hidden = false; this.status.textContent = 'Loading…';
    try {
      canvasOptions(this.options());
      const module = await loadMilkteaModule(new URL(src, this.ownerDocument.baseURI));
      if (generation !== this.generation || !this.isConnected) return;
      const wasm = await instantiateMilktea(module);
      if (generation !== this.generation || !this.isConnected) return;
      this.app = new MilkteaCanvas(this.canvas, wasm, {...this.options(), autoStart: false,
        onQuit: () => { this.status.hidden = false; this.status.textContent = 'Stopped'; this.dispatchEvent(new Event('quit')); },
        onError: error => this.reportError(error)});
      this.status.hidden = true;
      this.updatePlayback();
      this.dispatchEvent(new Event('ready'));
    } catch (error) {
      if (generation === this.generation) this.reportError(error);
    } finally {
      if (generation === this.generation) this.pending = false;
    }
  }
  updatePlayback() {
    if (!this.app) return;
    const doc = this.ownerDocument;
    const fullscreen = doc.fullscreenElement;
    const shown = this.isConnected && !doc.hidden && (this.visible || this.expanded) &&
      (!fullscreen || fullscreen === this || fullscreen.contains(this));
    if (shown) this.app.resume(); else this.app.pause();
  }
  async toggleFullscreen() {
    if (this.expanded) return this.ownerDocument.exitFullscreen();
    if (!this.requestFullscreen) throw new Error('Fullscreen is unavailable in this browser');
    const v = this.app ?? canvasViewport(this.canvas.clientWidth, this.canvas.clientHeight, canvasOptions(this.options()));
    this.fullscreenViewport = {cols: v.cols, rows: v.rows};
    // requestFullscreen must occur directly inside the button's user gesture.
    const entering = this.requestFullscreen();
    void this.ensureLoaded();
    try { await entering; } catch (error) { this.fullscreenViewport = null; throw error; }
  }
  release() {
    this.generation++;
    this.pending = false;
    this.app?.stop(); this.app = null;
    this.status.hidden = false;
    this.status.textContent = 'Ready when you scroll into view';
  }
  reportError(error) {
    this.status.hidden = false; this.status.textContent = error.message;
    this.dispatchEvent(new CustomEvent('error', {detail: error}));
  }
}

if (!customElements.get('milktea-view')) customElements.define('milktea-view', MilkteaView);
