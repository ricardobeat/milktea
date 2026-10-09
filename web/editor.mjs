const presets = {
  counter: `import {text, vstack, hstack} from 'milktea';

export default {
  init() { return [{count: 0}]; },
  update(msg, model) {
    if (msg.type === 'key' && msg.key === 'ArrowUp' || msg.type === 'click' && msg.id === 'plus')
      return [{count: model.count + 1}];
    if (msg.type === 'key' && msg.key === 'ArrowDown' || msg.type === 'click' && msg.id === 'minus')
      return [{count: model.count - 1}];
    return [model];
  },
  view(model, screen) {
    return vstack([
      text('Counter: ' + model.count, {style: {
        foreground: '#e4b2d6', bold: true, border: 'rounded', padding: 1
      }}),
      hstack([
        text(' − ', {onClick: 'minus', style: {background: '#393047'}}),
        text(' + ', {onClick: 'plus', style: {background: '#393047'}})
      ], {gap: 2}),
      text('Use ↑ / ↓ or click the buttons'),
      text(screen.cols + ' × ' + screen.rows + ' cells')
    ], {gap: 1, center: true});
  }
};`,
  clock: `import {text, vstack, tick} from 'milktea';

export default {
  init() { return [{frame: 0}, tick(60)]; },
  update(msg, model) {
    if (msg.type === 'tick') return [{frame: model.frame + 1}, tick(60)];
    return [model];
  },
  view(model) {
    const dots = '●'.repeat(model.frame % 20 + 1);
    return vstack([
      text('One-shot timers, re-armed from update', {style: {foreground: '#e4b2d6', bold: true}}),
      text(dots, {style: {foreground: '#64d8c2'}}),
      text('Frame ' + model.frame)
    ], {gap: 1, padding: 2});
  }
};`,
  input: `import {text, vstack} from 'milktea';

export default {
  init() { return [{value: ''}]; },
  update(msg, model) {
    if (msg.type === 'paste') return [{value: model.value + msg.text}];
    if (msg.type === 'key') {
      if (msg.key === 'Backspace') return [{value: [...model.value].slice(0, -1).join('')}];
      if ([...msg.key].length === 1 && !msg.ctrl && !msg.alt)
        return [{value: model.value + msg.key}];
    }
    return [model];
  },
  view(model) {
    return vstack([
      text('Click here, then type or paste', {style: {foreground: '#e4b2d6'}}),
      text(model.value + '▌', {style: {border: 'rounded', padding: 1}})
    ], {gap: 1, padding: 2});
  }
};`
};
const code=document.querySelector('#code'), frame=document.querySelector('iframe');
const preset=document.querySelector('#preset'), status=document.querySelector('#status'), output=document.querySelector('#output');
let ready=false, debounce;
try {code.value=localStorage.getItem('milktea-editor-code') || presets.counter;} catch {code.value=presets.counter;}
function run() {
  clearTimeout(debounce);
  try {localStorage.setItem('milktea-editor-code',code.value);} catch {}
  if (!ready) return;
  output.textContent=''; status.textContent='Starting…';
  frame.contentWindow.postMessage({source:'milktea-editor',code:code.value},location.origin);
}
addEventListener('message',event=>{
  if (event.source!==frame.contentWindow || event.origin!==location.origin || event.data?.source!=='milktea-editor') return;
  const {type,detail}=event.data;
  if (type==='loaded') {ready=true;run();}
  else if (type==='error') {status.textContent='Error';output.textContent=detail;}
  else if (type==='log') output.textContent+=detail+'\n';
  else status.textContent=detail;
});
document.querySelector('#run').addEventListener('click',run);
preset.addEventListener('change',()=>{code.value=presets[preset.value];run();});
document.querySelector('#reset').addEventListener('click',()=>{code.value=presets[preset.value];run();});
code.addEventListener('input',()=>{if(document.querySelector('#auto').checked) {clearTimeout(debounce);debounce=setTimeout(run,600);}});
code.addEventListener('keydown',event=>{
  if ((event.ctrlKey || event.metaKey) && event.key==='Enter') {event.preventDefault();run();}
  if (event.key==='Tab') {event.preventDefault();code.setRangeText('  ',code.selectionStart,code.selectionEnd,'end');code.dispatchEvent(new Event('input'));}
});
