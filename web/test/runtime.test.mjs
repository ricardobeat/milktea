import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {instantiateMilktea, gridText, readGrid, translateKey, createRandom} from '../engine.mjs';
const base = new URL('../build/', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('examples.json', base)));
async function start(name, cols = 80, rows = 24) {
  let time = 0;
  const wasm = await instantiateMilktea(await readFile(new URL(`${name}.wasm`, base)),
    {now: () => time, wall: () => 1700000000000 + time});
  wasm.mt_resize(cols, rows, 10, 20); wasm.mt_boot();
  return {wasm, advance: delta => {time += delta; return wasm.mt_frame();}};
}
for (const name of manifest.examples) {
  test(`${name}: startup, timers, resize, shutdown`, async () => {
    const {wasm: w, advance} = await start(name);
    try {
      assert.equal(w.mt_frame(), 2);
      assert.equal(w.mt_width(), 80); assert.equal(w.mt_height(), 24);
      if (name === 'colors') { assert.equal(advance(1), 0); return; }
      for (let i = 0; i < 5; i++) assert.ok(advance(1000) > 0);
      w.mt_resize(100, 30, 10, 20); assert.equal(w.mt_frame(), 2);
      assert.equal(w.mt_width(), 100); assert.equal(w.mt_height(), 30);
      w.mt_resize(40, 10, 10, 20); assert.equal(w.mt_frame(), 2);
    } finally { w.mt_stop(); }
    assert.equal(w.mt_frame(), 0);
    w.mt_stop();
  });
}
test('counter: arrow keys and quit', async () => {
  const {wasm: w} = await start('counter');
  try {
    w.mt_frame(); assert.match(gridText(w), /Counter: 0/);
    w.mt_key(6, 0, 0, 0); w.mt_frame(); assert.match(gridText(w), /Counter: 1/);
    w.mt_key(7, 0, 0, 0); w.mt_frame(); assert.match(gridText(w), /Counter: 0/);
    w.mt_key(1, 113, 0, 0); assert.equal(w.mt_frame(), 0);
  } finally { w.mt_stop(); }
});
test('spinners: all six text variants render and keep animating in the browser',async()=>{
  const {wasm:w,advance}=await start('spinners',64,12);
  try {
    w.mt_frame();
    const initial=gridText(w);
    for(const name of ['Dots','Lines','Arrow','Blocks','Moon','Pulse']) assert.ok(initial.includes(name),name);
    advance(80);
    assert.notEqual(gridText(w),initial);
  } finally {w.mt_stop();}
});
test('random: seeded output avoids short cycles in modulo-four values', () => {
  for (const seed of [0, 1, 1700000000000 >>> 0]) {
    const random = createRandom(seed), again = createRandom(seed);
    const values = Array.from({length: 4096}, () => random());
    assert.deepEqual(values, Array.from({length: 4096}, () => again()));
    assert.ok(values.every(value => Number.isInteger(value) && value >= 0 && value <= 0x7fffffff));
    const repetitions = values.slice(8).filter((value, i) => value % 4 === values[i] % 4).length;
    assert.ok(repetitions < values.length * .4, 'rand() % 4 must not repeat every eight calls');
  }
});
test('doom-fire: flames keep changing after warmup', async () => {
  const {wasm: w, advance} = await start('doom-fire');
  try {
    w.mt_frame();
    const frames = new Set();
    for (let frame = 0; frame < 240; frame++) {
      advance(16);
      if (frame < 180) continue;
      const g = readGrid(w);
      frames.add(Buffer.from(g.bytes.subarray(g.ptr, g.ptr + g.cols * g.rows * g.stride)).toString('base64'));
    }
    assert.ok(frames.size > 30, `expected evolving flames, saw only ${frames.size} distinct frames`);
  } finally { w.mt_stop(); }
});
test('nanobots: all blocks form the word and automatically cycle', async () => {
  const source = await readFile(new URL('../../examples/nanobots/milktea.txt', import.meta.url), 'utf8');
  const rows = source.split('\n').map(row => row.trim()).filter(Boolean);
  const {wasm: w, advance} = await start('nanobots', 100, 30);
  try {
    w.mt_frame();
    let formations = 0, formedBefore = false;
    for (let frame = 0; frame < 1200; frame++) {
      assert.ok(advance(32) > 0);
      const text = gridText(w);
      const formed = rows.every(row => text.includes(row));
      if (formed && !formedBefore) formations++;
      formedBefore = formed;
    }
    assert.ok(formations >= 3, `expected three complete formations, saw ${formations}`);
  } finally { w.mt_stop(); }
});
test('mouse: drag retains trail across event pools', async () => {
  const {wasm: w} = await start('mouse');
  try {
    w.mt_frame(); w.mt_mouse(0, 0, 12, 8, 120, 160, 0); w.mt_frame();
    w.mt_mouse(0, 2, 13, 9, 130, 180, 0); w.mt_frame();
    assert.match(gridText(w), /\(12,8\) -> \(13,9\)/);
    w.mt_mouse(0, 1, 13, 9, 130, 180, 0); w.mt_frame();
    assert.match(gridText(w), /Dragging: no/);
    w.mt_key(1, 99, 0, 0); w.mt_frame(); assert.doesNotMatch(gridText(w), /Click Trail/);
  } finally { w.mt_stop(); }
});
test('inputbox: typing, backspace and submit preserve model buffers', async () => {
  const {wasm: w} = await start('inputbox');
  try {
    w.mt_frame();
    for (const ch of 'hello') {
      w.mt_key(1, ch.codePointAt(0), 0, 0);
      w.mt_frame();
    }
    assert.match(gridText(w), /> hello█/);
    assert.match(gridText(w), /Type something below\./);
    w.mt_key(3, 0, 0, 0); w.mt_frame();
    assert.match(gridText(w), /> hell█/);
    w.mt_key(2, 0, 0, 0); w.mt_frame();
    assert.match(gridText(w), />> hell/);
    assert.match(gridText(w), /input len: 0 chars/);
    // Exercise buffer growth and subsequent event/render pools.
    for (let i = 0; i < 100; i++) {
      w.mt_key(1, 120, 0, 0);
      w.mt_frame();
    }
    assert.match(gridText(w), /input len: 100 chars/);
    w.mt_key(2, 0, 0, 0); w.mt_frame();
    assert.match(gridText(w), />> hell/);
    assert.match(gridText(w), /input len: 0 chars/);
  } finally { w.mt_stop(); }
});
test('browser key translation handles Unicode and modifiers', () => {
  assert.deepEqual(translateKey({key: 'ArrowUp'}), [6, 0, 0]);
  assert.deepEqual(translateKey({key: 'C', ctrlKey: true, shiftKey: true}), [28, 0, 5]);
  assert.deepEqual(translateKey({key: '🐱'}), [1, 0x1f431, 0]);
  assert.equal(translateKey({key: 'Dead'}), null);
  assert.equal(translateKey({key: 'x', isComposing: true}), null);
});

function contentBounds(w) {
  const g=readGrid(w),decode=new TextDecoder();
  let left=g.cols,top=g.rows,right=-1,bottom=-1;
  for(let i=0;i<g.cols*g.rows;i++) {
    const p=g.ptr+i*g.stride,len=g.bytes[p+8];
    if(!len || !decode.decode(g.bytes.subarray(p,p+len)).trim()) continue;
    const x=i%g.cols,y=Math.floor(i/g.cols);
    left=Math.min(left,x);right=Math.max(right,x);top=Math.min(top,y);bottom=Math.max(bottom,y);
  }
  return {left,top,right,bottom,cols:g.cols,rows:g.rows};
}
function gridLines(w) {
  const g=readGrid(w), decode=new TextDecoder();
  return Array.from({length:g.rows}, (_,y)=>Array.from({length:g.cols}, (_,x)=>{
    const p=g.ptr+(y*g.cols+x)*g.stride;
    return decode.decode(g.bytes.subarray(p,p+g.bytes[p+8])) || ' ';
  }));
}
function locate(lines, text) {
  for (let y=0; y<lines.length; y++) {
    for (let x=0; x<lines[y].length; x++) {
      if (lines[y].slice(x,x+text.length).join('')===text) return {x,y};
    }
  }
  assert.fail(`Missing text: ${text}`);
}
test('spinners align columns and pin the centered footer above bottom padding', async()=>{
  for (const [cols,rows,columns] of [[80,24,3],[37,14,2]]) {
    const {wasm:w,advance}=await start('spinners',cols,rows);
    try {
      w.mt_frame();
      for (let frame=0; frame<8; frame++) {
        const lines=gridLines(w);
        const labels=['Dots','Lines','Arrow','Blocks','Moon','Pulse'].map(name=>locate(lines,name));
        for (let i=columns; i<labels.length; i++) assert.equal(labels[i].x,labels[i%columns].x);
        const footer=locate(lines,'Press q or ESC to quit');
        assert.equal(footer.y,rows-2);
        assert.ok(Math.abs(footer.x*2+'Press q or ESC to quit'.length-cols)<=1);
        assert.ok(lines.at(-1).every(c=>!c.trim()));
        advance(80);
      }
    } finally {w.mt_stop();}
  }
});
test('inputbox spaces its title, indents instructions and pads the bottom', async()=>{
  const {wasm:w}=await start('inputbox',80,24);
  try {
    w.mt_frame();const lines=gridLines(w);
    const title=locate(lines,'Input test'), prompt=locate(lines,'Type something below.');
    const submit=locate(lines,'Enter to submit.');
    assert.equal(prompt.y,title.y+2);
    assert.equal(prompt.x,title.x+1);
    assert.equal(submit.x,prompt.x);
    assert.ok(lines.at(-1).every(c=>!c.trim()));
  } finally {w.mt_stop();}
});
test('timer centers each component with blank rows between them', async()=>{
  const {wasm:w}=await start('timer',80,24);
  try {
    w.mt_frame();
    for (const paused of [false,true]) {
      if (paused) {w.mt_key(1,32,0,0);w.mt_frame();}
      const lines=gridLines(w);
      for (const text of ['01:00',paused?'PAUSED · SPACE to resume':'SPACE to pause','r to reset  |  q to quit']) {
        const {x}=locate(lines,text);
        assert.ok(Math.abs(x*2+text.length-80)<=1,`${text} centered`);
      }
      const status=locate(lines,paused?'PAUSED · SPACE to resume':'SPACE to pause');
      const reset=locate(lines,'r to reset  |  q to quit');
      assert.equal(reset.y,status.y+2);
      assert.ok(lines[status.y-1].every(c=>!c.trim()));
      const b=contentBounds(w);
      assert.ok(Math.abs(b.top+b.bottom-23)<=2);
    }
  } finally {w.mt_stop();}
});
test('doom fire keeps headroom at small and large viewport sizes', async () => {
  for (const [cols, rows] of [[80,24], [100,30], [160,48]]) {
    const {wasm:w, advance} = await start('doom-fire', cols, rows);
    try {
      w.mt_frame();
      for (let i=0; i<180; i++) advance(16);
      const g=readGrid(w);
      let cold=0;
      for (let x=0; x<g.cols; x++) {
        const s=g.ptr+x*g.stride+g.style;
        if (g.bytes[s+2]===7 && g.bytes[s+3]===7 && g.bytes[s+4]===7) cold++;
      }
      assert.ok(cold>g.cols*.95, `${cold}/${g.cols} cold cells at top`);
    } finally {w.mt_stop();}
  }
});
