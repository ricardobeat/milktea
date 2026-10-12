import './embed.mjs';

// Canvas does not repaint automatically when a web font finishes loading.
Promise.all([document.fonts.load('12px "Geist Mono"'), document.fonts.load('bold 12px "Geist Mono"')])
  .then(() => {
    for (const view of document.querySelectorAll('milktea-view')) {
      if (view.engine) view.engine.repaint = true;
    }
  });

for (const surface of document.querySelectorAll('.demo-surface')) {
  const view = surface.querySelector('milktea-view');
  const button = surface.querySelector('.restart');
  button.addEventListener('click', () => {
    button.disabled = true;
    view.restart();
  });
  view.addEventListener('ready', () => {button.disabled = false;});
  view.addEventListener('error', () => {button.disabled = false;});
}

// Give readers a moment at either end before wheel scrolling reaches the page.
for (const pane of document.querySelectorAll('#counter-code, .demo-code')) {
  let heldEdge = null, releaseAt = 0;
  pane.addEventListener('wheel', event => {
    if (event.ctrlKey || event.shiftKey || Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    const max = pane.scrollHeight - pane.clientHeight;
    if (max <= 0) return;
    const delta = event.deltaY * (event.deltaMode === 1 ? 24 : event.deltaMode === 2 ? pane.clientHeight : 1);
    const edge = delta > 0 ? 'bottom' : 'top';
    const remaining = delta > 0 ? max - pane.scrollTop : pane.scrollTop;
    if (remaining > Math.abs(delta) + 1) {heldEdge = null; return;}
    if (heldEdge !== edge) {
      heldEdge = edge;
      releaseAt = performance.now() + 2000;
    }
    if (performance.now() < releaseAt) {
      event.preventDefault();
      pane.scrollTop = delta > 0 ? max : 0;
    } else {
      // Explicitly hand off at the edge: browsers can retain the wheel
      // gesture on the inner scroller after earlier events were canceled.
      event.preventDefault();
      window.scrollBy({top: delta, behavior: 'instant'});
    }
  }, {passive: false});
  pane.addEventListener('scroll', () => {
    if (pane.scrollTop > 1 && pane.scrollTop < pane.scrollHeight - pane.clientHeight - 1) heldEdge = null;
  });
}

// Each demo owns its tab state and fetches source only when Code is opened.
for (const window of document.querySelectorAll('.code-window')) {
  const tabs = [...window.querySelectorAll('[role="tab"]')];
  const view = window.querySelector('milktea-view');
  const code = window.querySelector('[data-code-src]');
  const preview = window.querySelector('.demo-preview');
  if (code && preview) {
    new ResizeObserver(() => {
      if (!preview.hidden) code.style.height = `${preview.getBoundingClientRect().height}px`;
    }).observe(preview);
  }
  function focusPreview() {
    const active = tabs.find(tab => tab.getAttribute('aria-selected') === 'true');
    if (view.engine && active?.getAttribute('aria-controls').endsWith('-preview') &&
        document.activeElement === active) view.canvas.focus({preventScroll: true});
  }
  view.addEventListener('ready', focusPreview);
  async function loadCode() {
    if (!code || code.dataset.loaded) return;
    code.dataset.loaded = 'loading';
    code.setAttribute('aria-busy', 'true');
    code.textContent = 'Loading source…';
    try {
      const response = await fetch(code.dataset.codeSrc, {cache: 'no-cache'});
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      code.innerHTML = await response.text();
      code.dataset.loaded = 'true';
    } catch {
      delete code.dataset.loaded;
      code.textContent = 'Could not load source. Open Code again to retry.';
    } finally {code.removeAttribute('aria-busy');}
  }
  function selectTab(tab) {
    if (code && preview && !preview.hidden) code.style.height = `${preview.getBoundingClientRect().height}px`;
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
    }
    if (tab.getAttribute('aria-controls').endsWith('-code')) loadCode();
  }
  for (const [index, tab] of tabs.entries()) {
    tab.addEventListener('click', () => {selectTab(tab); focusPreview();});
    tab.addEventListener('keydown', event => {
      const next = event.key === 'ArrowRight' ? (index + 1) % tabs.length
        : event.key === 'ArrowLeft' ? (index + tabs.length - 1) % tabs.length
        : event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : null;
      if (next === null) return;
      event.preventDefault();
      selectTab(tabs[next]);
      tabs[next].focus();
    });
  }
}
