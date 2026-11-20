import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const playwright=require('playwright');
const browser=await playwright[process.env.MILKTEA_TEST_BROWSER || 'chromium'].launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  const page=await browser.newPage({viewport:{width:1200,height:800}});
  await page.goto(`${origin}/editor.html`);
  const preview=page.frames().find(f=>f.url().endsWith('editor-runner.html'));
  await preview.waitForFunction(()=>window.app?.engine.wasm.mt_width()>0);
  await page.selectOption('#preset','counter');
  await preview.waitForFunction(()=>window.app?.model.count===0 && window.app.engine.wasm.mt_width()>0);
  const grid=()=>preview.evaluate(async()=>{
    const {gridText}=await import('/engine.js');return gridText(window.app.engine.wasm);
  });
  assert.match(await grid(),/Counter: 0/);
  await preview.locator('canvas').click();await page.keyboard.press('ArrowUp');
  await preview.waitForFunction(()=>window.app.model.count===1);
  const plus=await preview.evaluate(async()=>{
    const {readGrid}=await import('/engine.js');const a=window.app.engine,g=readGrid(a.wasm),v=a.viewport;
    for(let i=0;i<g.cols*g.rows;i++) if(g.bytes[g.ptr+i*g.stride]===43)
      return {x:v.offsetX+(i%g.cols+.5)*a.cellWidth*v.scaleX,
        y:v.offsetY+(Math.floor(i/g.cols)+.5)*a.cellHeight*v.scaleY};
  });
  await preview.locator('canvas').click({position:plus});
  await preview.waitForFunction(()=>window.app.model.count===2);
  console.log('PASS reusable WASM engine: JS model, styles, layout, keyboard and native clicks');
  await page.selectOption('#preset','clock');
  await preview.waitForFunction(()=>window.app.model.frame>2);
  console.log('PASS native timers drive JS updates');
  await page.selectOption('#preset','input');
  await preview.waitForFunction(()=>window.app.model.value==='');
  await preview.locator('canvas').click();await page.keyboard.type('milktea');
  await preview.waitForFunction(()=>window.app.model.value==='milktea');
  await page.keyboard.press('Backspace');await preview.waitForFunction(()=>window.app.model.value==='milkte');
  await page.fill('#code',`import {text} from 'milktea'; export default {init:()=>[{value:'Edited live'}],view:m=>text(m.value)};`);
  await preview.waitForFunction(()=>window.app.model.value==='Edited live' && window.app.engine.wasm.mt_width()>0);
  assert.match(await grid(),/Edited live/);
  await page.fill('#code','export default { syntax broken');await page.click('#run');
  await page.waitForFunction(()=>document.querySelector('#status').textContent==='Error');
  assert.match(await grid(),/Edited live/,'syntax errors retain previous running preview');
  await page.click('#reset');await preview.waitForFunction(()=>window.app.model.value==='');
  console.log('PASS typing, debounced live edits, syntax errors and reset');
  await page.close();
} finally {await browser.close();}
