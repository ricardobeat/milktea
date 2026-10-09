import {MilkteaCanvas, instantiateMilktea, loadMilkteaModule} from './engine.mjs';

const encoder = new TextEncoder(), decoder = new TextDecoder();
const keyNames = ['None','Rune','Enter','Backspace','Escape','Tab','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Home','End','Delete','PageUp','PageDown','Insert','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','Ctrl+C'];
export const text = (value, options = {}) => ({type:'text', value:String(value), ...options});
export const vstack = (children, options = {}) => ({type:'vstack', children, ...options});
export const hstack = (children, options = {}) => ({type:'hstack', children, ...options});
// Keep saved programs using the original names working.
export const column = vstack;
export const row = hstack;
export const zstack = (children, options = {}) => ({type:'zstack', children, ...options});
export const stack = zstack;
export const cells = value => ({kind:'cells', value});
export const fill = (value = 1) => ({kind:'fill', value});
export const percent = value => ({kind:'percent', value});
export const fit = () => ({kind:'fit', value:0});
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
function signed(value = 0) {
  if (!Number.isInteger(value) || Math.abs(value) > 1000000) throw new RangeError('Expected a signed integer');
  return value;
}
function finite(value) {
  if (!Number.isFinite(value)) throw new RangeError('Expected a finite number');
  return value;
}
function choice(value, names, fallback) {
  if (value === undefined) return fallback;
  if (names[value] === undefined) throw new TypeError(`Unknown option: ${value}`);
  return names[value];
}
function padding(value = 0) {
  const values = Array.isArray(value) ? value : [value,value,value,value];
  if (values.length !== 4) throw new TypeError('Padding is a number or [top, right, bottom, left]');
  return values.map(n => integer(n,0,256));
}

// JS owns model state; C3 owns dispatch, one-shot timers, layout and painting.
// init/update return [model, command?]; view returns a string or tree descriptor.
export async function mount(canvas, program, {wasmURL = new URL('./build/milktea.wasm', import.meta.url), host = {}, ...options} = {}) {
  if (typeof program.view !== 'function') throw new TypeError('A program needs view(model, context)');
  let wasm, engine, model, nextMessage = 1;
  const messages = new Map(), clicks = new Map();
  const tweens = new Map();
  let destroyed = false;
  function tween(value = 0, duration = 300, easing = 'outCubic') {
    if (destroyed) throw new Error('Program is stopped');
    const curves = {linear:0,inQuad:1,outQuad:2,inOutQuad:3,inCubic:4,outCubic:5,inOutCubic:6,outBack:7};
    const ptr = wasm.mt_js_tween(finite(value),integer(duration,300),choice(easing,curves,5));
    const live = () => {if (destroyed) throw new Error('Tween belongs to a stopped program'); return ptr;};
    const t = {
      get value() {return wasm.mt_js_tween_value(live());},
      get target() {return wasm.mt_js_tween_target(live());},
      get moving() {return !!wasm.mt_js_tween_moving(live());},
      get showing() {return this.target!==0 || this.moving;},
      get alpha() {return wasm.mt_js_tween_alpha(live());},
      update(target) {wasm.mt_js_tween_update(live(),finite(target));return this;},
      set(value) {wasm.mt_js_tween_set(live(),finite(value));return this;},
      lerp(from,to) {return wasm.mt_js_tween_lerp(live(),signed(from),signed(to));}
    };
    tweens.set(t,ptr);return t;
  }
  const context = {get cols() {return engine?.cols ?? wasm.mt_screen_width();},
    get rows() {return engine?.rows ?? wasm.mt_screen_height();},
    get time() {return wasm.mt_js_time();}, text, vstack, hstack, zstack, column, row, stack, cells, fill, percent, fit, tween, tick, send, quit};
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
      const borders = {rounded:1,normal:2,double:3,thick:4};
      if (s.border != null && !borders[s.border]) throw new TypeError(`Unknown border: ${s.border}`);
      const pads=padding(s.padding), borderFg=color(s.borderForeground), cornerFg=color(s.cornerForeground), gradient=color(s.backgroundGradient);
      const borderAnimation=choice(s.borderAnimation,{none:0,pulse:1,rainbow:2,race:3},0);
      if (borderAnimation && !s.border) throw new TypeError('An animated border needs a border style');
      const speed=integer(s.borderSpeed,1000);
      const horizontal=choice(s.align,{left:3,center:1,right:4},3), vertical=choice(s.verticalAlign,{top:0,center:1,bottom:2},0);
      const ptr=wasm.mt_alloc(bytes.length);
      new Uint8Array(wasm.memory.buffer,ptr,bytes.length).set(bytes);
      node=wasm.mt_js_text(ptr,bytes.length,fg,bg,(s.bold?1:0)|(s.italic?2:0)|(s.underline?4:0),borders[s.border]??0,0);
      if (Object.keys(s).length) wasm.mt_js_style_options(node,borderFg,cornerFg,gradient,borderAnimation,speed,...pads,horizontal,vertical);
    } else {
      const direction={vstack:0,hstack:1,zstack:2,stack:2,column:0,row:1}[value.type];
      if (direction===undefined || !Array.isArray(value.children)) throw new TypeError('View must be text, vstack, hstack, or zstack');
      node=wasm.mt_js_container(direction);
      for (const child of value.children) wasm.mt_js_add(node,tree(child,depth+1,count));
    }
    let click=0;
    if (value.onClick!==undefined) {click=-(clicks.size+1); clicks.set(click,value.onClick);}
    wasm.mt_js_node_options(node,-1,-1,
      integer(value.fill,0,512),integer(value.gap,0,256),integer(value.padding,0,256),!!value.center,click);
    for (const [axis,size] of [value.width,value.height].entries()) {
      if (size===undefined) continue;
      const constraint=typeof size==='number' ? cells(size) : size;
      const kind=choice(constraint.kind,{cells:0,fill:1,percent:2,fit:3,min:4,max:5},0);
      wasm.mt_js_size(node,axis,kind,integer(constraint.value,0,kind===2 ? 100 : 1000000));
    }
    const at=value.at ?? [0,0], offset=value.offset ?? [0,0];
    if (at.length!==2 || offset.length!==2) throw new TypeError('at and offset must be [x, y]');
    wasm.mt_js_layer(node,!!value.at,...at.map(signed),...offset.map(signed),integer(value.alpha,255,255),integer(value.animate,0,240),
      choice(value.justify,{start:0,center:1,end:2,between:3,around:4,evenly:5},-1),
      choice(value.align,{stretch:0,start:1,center:2,end:3},-1));
    if (value.shadow) {
      const s=value.shadow;
      wasm.mt_js_shadow(node,signed(s.x??1),signed(s.y??1),integer(s.opacity,128,255),integer(s.blur,0,32),color(s.color??'#000000'),!!s.halfBlocks);
    }
    if (value.transition) {
      const t=value.transition, ptr=tweens.get(t.tween);
      if (!ptr) throw new TypeError('Transition needs a tween from this program’s context');
      wasm.mt_js_transition(node,ptr,signed(t.fromX??0),signed(t.fromY??0),!!t.fade);
    }
    return node;
  }
  const callbacks = {init:()=>result(program.init ? program.init(context) : [{}]), update:event,
    view:()=>{clicks.clear(); return tree(program.view(model,context));},
    destroy:()=>{
      try {program.destroy?.(model);} finally {
        for (const ptr of tweens.values()) wasm.mt_js_free(ptr);
        tweens.clear();messages.clear();clicks.clear();destroyed=true;
      }
    }};
  wasm = await instantiateMilktea(await loadMilkteaModule(wasmURL), {...host,callbacks});
  try {engine = new MilkteaCanvas(canvas,wasm,options);} catch(error) {wasm.mt_stop();throw error;}
  return {engine, get model() {return model;}, send:queue, stop:()=>engine.stop()};
}
