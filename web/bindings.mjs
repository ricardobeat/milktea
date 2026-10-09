import {MilkteaCanvas, instantiateMilktea, loadMilkteaModule} from './engine.mjs';

const encoder = new TextEncoder(), decoder = new TextDecoder();
const keyNames = ['None','Rune','Enter','Backspace','Escape','Tab','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Home','End','Delete','PageUp','PageDown','Insert','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','Ctrl+C'];
export const text = (value, options = {}) => ({type:'text', value:String(value), ...options});
export const column = (children, options = {}) => ({type:'column', children, ...options});
export const row = (children, options = {}) => ({type:'row', children, ...options});
export const stack = (children, options = {}) => ({type:'stack', children, ...options});
export const tick = (ms = 16) => ({type:'tick', ms});
export const send = message => ({type:'send', message});
export const quit = () => ({type:'quit'});

function integer(value, fallback, max = 1000000) {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < 0 || value > max) throw new RangeError(`Expected an integer from 0 to ${max}`);
  return value;
}
function color(value) {
  if (value === undefined) return -1;
  if (typeof value === 'number') return integer(value, -1, 0xffffff);
  if (/^#[0-9a-f]{6}$/i.test(value)) return parseInt(value.slice(1), 16);
  throw new TypeError('Colors must be #rrggbb or RGB integers');
}

// JS owns model state; C3 owns dispatch, one-shot timers, layout and painting.
// init/update return [model, command?]; view returns a string or tree descriptor.
export async function mount(canvas, program, {wasmURL = new URL('./build/milktea.wasm', import.meta.url), host = {}, ...options} = {}) {
  if (typeof program.view !== 'function') throw new TypeError('A program needs view(model, context)');
  let wasm, engine, model, nextMessage = 1;
  const messages = new Map(), clicks = new Map();
  const context = {get cols() {return engine?.cols ?? wasm.mt_screen_width();},
    get rows() {return engine?.rows ?? wasm.mt_screen_height();},
    get time() {return wasm.mt_js_time();}, text, column, row, stack, tick, send, quit};
  function queue(message) {
    if (engine?.stopped) throw new Error('Cannot send to a stopped program');
    const id = nextMessage++;
    messages.set(id, message); wasm.mt_js_send(id);
  }
  function result(value) {
    if (!Array.isArray(value) || value.length < 1 || value.length > 2) throw new TypeError('init/update must return [model, command?]');
    model = value[0];
    let stopping = false;
    for (const cmd of (Array.isArray(value[1]) ? value[1] : [value[1]])) {
      if (cmd == null) continue;
      if (cmd.type === 'tick') wasm.mt_js_tick(integer(cmd.ms, 16));
      else if (cmd.type === 'send') queue(cmd.message);
      else if (cmd.type === 'quit') stopping = true;
      else throw new TypeError(`Unknown command: ${cmd.type}`);
    }
    return stopping;
  }
  function update(message) {
    return program.update ? result(program.update(message, model, context)) : false;
  }
  function event(kind, a, b, c, d, e, f, g) {
    const mods = bits => ({ctrl:!!(bits&1), alt:!!(bits&2), shift:!!(bits&4)});
    if (kind===1) return update({type:'key',key:a===1 ? String.fromCodePoint(b) : keyNames[a],code:a,rune:b,action:['press','repeat','release'][d],...mods(c)});
    if (kind===2) return update({type:'resize',cols:a,rows:b});
    if (kind===5) return update({type:'mouse',button:['left','middle','right','none','wheel-up','wheel-down'][a],action:['press','release','motion'][b],col:c,row:d,px:e,py:f,...mods(g)});
    if (kind===8) {
      if (a<0) return update({type:'click',id:clicks.get(a)});
      const message = messages.get(a); messages.delete(a);
      return update(message);
    }
    if (kind===9) return update({type:'paste',text:decoder.decode(new Uint8Array(wasm.memory.buffer,a,b))});
    return update({type:({3:'focus',4:'blur',7:'tick'})[kind] ?? 'unknown'});
  }
  function tree(value, depth = 0, count = {n:0}) {
    if (value == null) return 0;
    if (typeof value === 'string' || typeof value === 'number') value = text(value);
    if (depth > 128 || ++count.n > 4096) throw new RangeError('View exceeds tree limits');
    let node;
    if (value.type==='text') {
      const s = value.style ?? {}, bytes = encoder.encode(value.value);
      const fg=color(s.foreground), bg=color(s.background);
      const borders = {rounded:1,normal:2,double:3};
      if (s.border != null && !borders[s.border]) throw new TypeError(`Unknown border: ${s.border}`);
      const padding=integer(s.padding,0,256), ptr=wasm.mt_alloc(bytes.length);
      new Uint8Array(wasm.memory.buffer,ptr,bytes.length).set(bytes);
      node=wasm.mt_js_text(ptr,bytes.length,fg,bg,(s.bold?1:0)|(s.italic?2:0)|(s.underline?4:0),borders[s.border]??0,padding);
    } else {
      const direction={column:0,row:1,stack:2}[value.type];
      if (direction===undefined || !Array.isArray(value.children)) throw new TypeError('View must be text, column, row, or stack');
      node=wasm.mt_js_container(direction);
      for (const child of value.children) wasm.mt_js_add(node,tree(child,depth+1,count));
    }
    let click=0;
    if (value.onClick!==undefined) {click=-(clicks.size+1); clicks.set(click,value.onClick);}
    wasm.mt_js_node_options(node,integer(value.width,-1,512),integer(value.height,-1,256),
      integer(value.fill,0,512),integer(value.gap,0,256),integer(value.padding,0,256),!!value.center,click);
    return node;
  }
  const callbacks = {init:()=>result(program.init ? program.init(context) : [{}]), update:event,
    view:()=>{clicks.clear(); return tree(program.view(model,context));},
    destroy:()=>{messages.clear();clicks.clear();program.destroy?.(model);}};
  wasm = await instantiateMilktea(await loadMilkteaModule(wasmURL), {...host,callbacks});
  try {engine = new MilkteaCanvas(canvas,wasm,options);} catch(error) {wasm.mt_stop();throw error;}
  return {engine, get model() {return model;}, send:queue, stop:()=>engine.stop()};
}
