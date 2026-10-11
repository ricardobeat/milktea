import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const playwright=require('playwright');
const browserName=process.env.MILKTEA_TEST_BROWSER || 'chromium';
const browser=await playwright[browserName].launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  const page=await browser.newPage({viewport:{width:1280,height:900},deviceScaleFactor:2});
  const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(origin);
  assert.deepEqual(await page.locator('milktea-view').evaluateAll(views=>views.map(v=>v.getAttribute('src'))),
    ['inputbox','spinners','timer','splash','doom-fire','doom-fire-overlay','spotlight','avian-assault'].map(n=>`./build/${n}.wasm`));
  assert.equal(await page.evaluate(()=>performance.getEntriesByType('resource').filter(r=>r.name.endsWith('.wasm')).length),0,'demos stay unloaded before entering view');
  await page.screenshot({path:`/private/tmp/milktea-site-${browserName}.png`});
  const input=page.locator('#inputbox milktea-view');
  await input.scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>!!document.querySelector('#inputbox milktea-view').engine);
  await input.locator('canvas').click();await page.keyboard.type('hello milktea');await page.keyboard.press('Enter');
  await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#inputbox milktea-view').engine.wasm).includes('>> hello milktea');});
  await input.evaluate(v=>{window.oldInput=v.engine;});
  await page.locator('#inputbox .restart').click();
  await page.waitForFunction(()=>{const a=document.querySelector('#inputbox milktea-view').engine;return a && a!==window.oldInput && a.wasm.mt_width()>0;});
  assert.equal(await page.evaluate(()=>window.oldInput.stopped),true);
  console.log('PASS demo ordering, lazy WASM, input submission and restart');

  for (const id of ['spinners','timer','splash','doom-fire','doom-fire-tea','spotlight','avian-assault']) {
    const view=page.locator(`#${id} milktea-view`);
    await view.scrollIntoViewIfNeeded();
    await page.waitForFunction(id=>{const a=document.querySelector(`#${id} milktea-view`).engine;return a && a.wasm.mt_width()>0;},id);
    assert.equal(await view.evaluate(v=>v.engine.stopped),false,`${id} runs`);
    if (id==='timer') {
      await view.locator('canvas').focus();await page.keyboard.press('Space');
      await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#timer milktea-view').engine.wasm).includes('PAUSED');});
    }
    if (id==='avian-assault') {
      await view.locator('canvas').focus();await page.keyboard.press('Enter');await page.keyboard.press('Enter');
      await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#avian-assault milktea-view').engine.wasm).includes('Aim');});
    }
  }
  assert.equal(await input.evaluate(v=>v.engine.paused),true);
  console.log('PASS all eight embeds, timer controls, game launch and offscreen pause');
  await page.locator('#spotlight').scrollIntoViewIfNeeded();
  await page.screenshot({path:`/private/tmp/milktea-site-demos-${browserName}.png`});
  if (browserName==='chromium') {
    const spotlight=page.locator('#spotlight milktea-view');
    await spotlight.locator('button').click();
    await page.waitForFunction(()=>document.fullscreenElement===document.querySelector('#spotlight milktea-view'));
    assert.equal(await spotlight.evaluate(v=>v.engine.viewport.width===innerWidth),true);
    await page.keyboard.press('Escape');await page.waitForFunction(()=>!document.fullscreenElement);
    assert.equal(await spotlight.evaluate(v=>v.engine.stopped),false);
  }
  for (const width of [390,320]) {
    await page.setViewportSize({width,height:844});
    await page.evaluate(()=>{document.documentElement.style.scrollBehavior='auto';scrollTo(0,0);});
    await page.waitForFunction(()=>scrollY===0);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,`no horizontal page overflow at ${width}px`);
  }
  await page.screenshot({path:`/private/tmp/milktea-site-mobile-${browserName}.png`});
  await page.goto(`${origin}/?example=counter`);
  await page.waitForURL('**/gallery.html?example=counter');
  await page.waitForFunction(()=>document.querySelector('#examples')?.value==='counter');
  assert.equal(await page.locator('#examples').inputValue(),'counter');
  assert.deepEqual(errors,[]);
  console.log(`PASS ${browserName}: mobile layout and old gallery URLs`);
  await page.close();
} finally {await browser.close();}
