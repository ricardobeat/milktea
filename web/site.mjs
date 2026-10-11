import './embed.mjs';

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
