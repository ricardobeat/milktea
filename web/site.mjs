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

const tabs = [...document.querySelectorAll('.counter-tabs [role="tab"]')];
function selectCounterTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
}
for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => selectCounterTab(tab));
  tab.addEventListener('keydown', event => {
    const next = event.key === 'ArrowRight' ? (index + 1) % tabs.length
      : event.key === 'ArrowLeft' ? (index + tabs.length - 1) % tabs.length
      : event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : null;
    if (next === null) return;
    event.preventDefault();
    selectCounterTab(tabs[next]);
    tabs[next].focus();
  });
}
