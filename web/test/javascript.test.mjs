import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {instantiateMilktea,gridText,readGrid} from '../engine.mjs';
import {text,column,row,tick,quit} from '../bindings.mjs';

test('standalone engine: JS callbacks, native layout/styles, timers, paste, clicks and teardown', async () => {
  let w, now=0, destroyed=0;
  const events=[];
  const label=value=>{
    const bytes=new TextEncoder().encode(value), ptr=w.mt_alloc(bytes.length);
    new Uint8Array(w.memory.buffer,ptr,bytes.length).set(bytes);
    return w.mt_js_text(ptr,bytes.length,0x64d8c2,-1,1,0,0);
  };
  w=await instantiateMilktea(await readFile(new URL('../build/milktea.wasm',import.meta.url)),{
    now:()=>now,callbacks:{init:()=>{w.mt_js_tick(25);return false;},
      update:(...args)=>{events.push(args);return args[0]===1 && args[1]===4;},
      view:()=>{
        const node=w.mt_js_container(0);
        const child=label('Hello, 世界');
        w.mt_js_node_options(child,-1,-1,0,0,0,false,42);
        w.mt_js_add(node,child);w.mt_js_add(node,label('Second row'));
        return node;
      },destroy:()=>destroyed++}});
  w.mt_resize(40,10,10,20);w.mt_boot();
  assert.equal(w.mt_frame(),2);
  assert.match(gridText(w),/Hello, 世 界/);assert.match(gridText(w),/Second row/);
  const grid=readGrid(w), style=grid.ptr+grid.style;
  assert.deepEqual([...grid.bytes.slice(style+2,style+5)],[100,216,194]);
  now=24;w.mt_frame();assert.ok(!events.some(e=>e[0]===7));
  now=25;w.mt_frame();assert.equal(events.filter(e=>e[0]===7).length,1);
  now=100;w.mt_frame();assert.equal(events.filter(e=>e[0]===7).length,1,'tick is one-shot');
  w.mt_mouse(0,0,1,0,10,0,0);w.mt_frame();
  assert.ok(events.some(e=>e[0]===8 && e[1]===42),'native tree hit-testing queues click ID');
  const bytes=new TextEncoder().encode('pasted 🧋'), ptr=w.mt_alloc(bytes.length);
  new Uint8Array(w.memory.buffer,ptr,bytes.length).set(bytes);w.mt_paste(ptr,bytes.length);
  assert.ok(events.some(e=>e[0]===9 && e[2]===bytes.length));
  w.mt_key(4,0,0,0);assert.equal(w.mt_frame(),0);
  w.mt_stop();w.mt_stop();assert.equal(destroyed,1);
});

test('JavaScript descriptors and commands preserve values for native bindings',()=>{
  assert.deepEqual(column([row([text('a')]),text('b',{onClick:'increment'})],{gap:1}),
    {type:'column',children:[{type:'row',children:[{type:'text',value:'a'}]},{type:'text',value:'b',onClick:'increment'}],gap:1});
  assert.deepEqual(tick(100),{type:'tick',ms:100});assert.deepEqual(quit(),{type:'quit'});
});
