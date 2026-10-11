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

