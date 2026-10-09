import {presets, presetNames} from './presets.mjs';
const code=document.querySelector('#code'), frame=document.querySelector('iframe');
const preset=document.querySelector('#preset'), status=document.querySelector('#status'), output=document.querySelector('#output');
for (const [id, label] of Object.entries(presetNames)) preset.add(new Option(label, id));
let ready=false, debounce;
try {
  const savedPreset=localStorage.getItem('milktea-editor-preset');
  if (savedPreset && presets[savedPreset]) preset.value=savedPreset;
  code.value=localStorage.getItem('milktea-editor-code') || presets[preset.value];
} catch {code.value=presets[preset.value];}
function run() {
  clearTimeout(debounce);
  try {localStorage.setItem('milktea-editor-code',code.value);localStorage.setItem('milktea-editor-preset',preset.value);} catch {}
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
