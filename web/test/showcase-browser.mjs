import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const playwright=require('playwright');
const browser=await playwright[process.env.MILKTEA_TEST_BROWSER || 'chromium'].launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  const page=await browser.newPage({viewport:{width:1200,height:1000}}), errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`${origin}/editor.html`);
  const preview=page.frames().find(f=>f.url().endsWith('editor-runner.html'));
  const grid=()=>preview.evaluate(async()=>{const {gridText}=await import('/engine.mjs');return gridText(window.app.engine.wasm);});
  const preset=async(name,ready)=>{
    await page.selectOption('#preset',name);await preview.waitForFunction(ready);
    await preview.waitForFunction(()=>window.app.engine.wasm.mt_width()>0);
    assert.notEqual(await page.locator('#status').textContent(),'Error',await page.locator('#output').textContent());
  };
  await preview.waitForFunction(()=>window.app?.model.page==='Overview' && window.app.engine.wasm.mt_width()>0);
  assert.match(await grid(),/Compact layout/);
  await page.setViewportSize({width:1700,height:1000});
  await preview.waitForFunction(()=>window.app.engine.wasm.mt_width()>=64);
  assert.match(await grid(),/Sidebar layout/);
  await preview.locator('canvas').focus();await page.keyboard.press('Space');
  await preview.waitForFunction(()=>window.app.model.launches===129);
  console.log('PASS dashboard changes layout with viewport and reacts to input');

  await preset('tweens',()=>window.app?.model.motions?.length===4);
  await preview.waitForFunction(()=>window.app.model.motions[0].value>.2 && window.app.model.motions[0].moving);
  const progress=await preview.evaluate(()=>window.app.model.motions.map(t=>t.value));
  assert.ok(progress[2]>progress[0], 'outCubic runs ahead of linear');
  await preview.locator('canvas').focus();await page.keyboard.press('Space');
  await preview.waitForFunction(()=>window.app.model.target===0);
  await preview.waitForFunction(()=>window.app.model.motions.every(t=>!t.moving));
  assert.ok(await preview.evaluate(()=>window.app.model.motions.every(t=>t.value===window.app.model.target)));
  console.log('PASS native tweens animate without tick loops, reverse and settle');

  await preset('composite',()=>!!window.app?.model.open);
  await preview.waitForFunction(()=>!window.app.model.open.moving);
  assert.match(await grid(),/COMPOSITED MODAL/);
  await preview.locator('canvas').focus();await page.keyboard.press('m');
  await preview.waitForFunction(()=>!window.app.model.open.showing);
  assert.doesNotMatch(await grid(),/COMPOSITED MODAL/);
  assert.match(await grid(),/LAYER 02/);
  await page.keyboard.press('ArrowUp');await preview.waitForFunction(()=>window.app.model.opacity===185);
  console.log('PASS native slide/fade compositing completes with no modal ghost');

  await preset('styles',()=>window.app?.model.palette===0);
  const colors=()=>preview.evaluate(async()=>{const {readGrid}=await import('/engine.mjs');const g=readGrid(window.app.engine.wasm);return [...g.bytes.slice(g.ptr,g.ptr+g.cols*g.rows*g.stride)].join(',');});
  const initial=await colors();
  await preview.waitForFunction(async old=>{const {readGrid}=await import('/engine.mjs');const g=readGrid(window.app.engine.wasm);return [...g.bytes.slice(g.ptr,g.ptr+g.cols*g.rows*g.stride)].join(',')!==old;},initial);
  assert.match(await grid(),/Rounded \/ rainbow/);
  await preview.locator('canvas').focus();await page.keyboard.press('Space');
  await preview.waitForFunction(()=>window.app.model.palette===1);
  console.log('PASS glaze gradients, borders, animated colors and palette updates');

  assert.ok(await page.locator('#highlight .hljs-keyword').count()>0);
  await page.$eval('#code',textarea=>{textarea.scrollTop=200;textarea.scrollLeft=60;textarea.dispatchEvent(new Event('scroll'));});
  assert.deepEqual(await page.evaluate(()=>{const t=document.querySelector('#code'),h=document.querySelector('#highlight');return [h.scrollTop===t.scrollTop,h.scrollLeft===t.scrollLeft];}),[true,true]);
  assert.deepEqual(errors,[]);
  await page.screenshot({path:'/private/tmp/milktea-showcase.png'});
  console.log('PASS syntax highlighting stays aligned while scrolling');
  await page.close();
} finally {await browser.close();}
