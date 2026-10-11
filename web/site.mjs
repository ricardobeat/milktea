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

// Give the text demos fewer columns on small screens, rather than shrinking
// their characters until they become hard to read. Fullscreen retains this grid.
const compact = matchMedia('(max-width: 650px)');
function sizeTextDemos() {
  for (const id of ['inputbox', 'spinners']) {
    document.querySelector(`#${id} milktea-view`).setAttribute('cols', compact.matches ? '44' : '64');
  }
}
compact.addEventListener('change', sizeTextDemos);
sizeTextDemos();
