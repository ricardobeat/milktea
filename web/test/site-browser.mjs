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
  assert.equal(await page.locator('#demos-title').textContent(),'Live examples');
  assert.match(await page.locator('.wasm-note').textContent(),/real milktea binary.*no terminal emulator involved/);
  assert.deepEqual(await page.locator('#demos milktea-view').evaluateAll(views=>views.map(v=>new URL(v.getAttribute('src'),location.href).pathname)),
    ['inputbox','spinners','timer','splash','doom-fire','doom-fire-overlay','spotlight','avian-assault'].map(n=>`/build/${n}.wasm`));
  assert.equal(await page.locator('#demos milktea-view').evaluateAll(views=>views.every(v=>!v.engine)),true,'demos stay unloaded before entering view');
  assert.equal(await page.locator('#demos [role=tab][aria-selected=true]').evaluateAll(tabs=>tabs.every(t=>t.textContent==='Preview')),true,'all demos start in Preview');
  assert.equal(await page.locator('.code-footer').count(),0,'tabs have no bottom bar');
  assert.equal(await page.evaluate(()=>performance.getEntriesByType('resource').filter(r=>new URL(r.name).pathname.startsWith('/code/')).length),0,'source is lazy loaded');
  assert.equal(await page.locator('#counter-code-tab').getAttribute('aria-selected'),'true');
  await page.locator('#counter-preview-tab').click();
  await page.waitForFunction(()=>document.querySelector('#counter-preview milktea-view').engine?.wasm.mt_width()>0);
  await page.waitForFunction(()=>{const v=document.querySelector('#counter-preview milktea-view');return v.shadowRoot.activeElement===v.canvas;});
  await page.keyboard.press('ArrowUp');
  await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#counter-preview milktea-view').engine.wasm).includes('Counter: 1');});
  await page.locator('#counter-code-tab').click();
  await page.waitForFunction(()=>document.querySelector('#counter-preview milktea-view').engine.paused);
  await page.locator('#counter-code-tab').press('ArrowRight');
  assert.equal(await page.locator('#counter-preview-tab').getAttribute('aria-selected'),'true');
  await page.locator('#counter-code-tab').click();
  await page.locator('#counter-preview-tab').click();
  assert.equal(await page.locator('#counter-preview milktea-view').evaluate(v=>v.shadowRoot.activeElement===v.canvas),true,'preview focuses an already loaded counter');
  await page.locator('#counter-code-tab').click();
  console.log('PASS native counter preview, keyboard tabs and hidden-panel pause');
  await page.screenshot({path:`/private/tmp/milktea-site-${browserName}.png`});
  const input=page.locator('#inputbox milktea-view');
  await input.scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>!!document.querySelector('#inputbox milktea-view').engine);
  assert.match(await input.evaluate(async v=>{const {gridText}=await import('/engine.mjs');return gridText(v.engine.wasm);}),/Input test/);
  await checkTabs('inputbox');
  await input.locator('canvas').click();await page.keyboard.type('hello milktea');await page.keyboard.press('Enter');
  await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#inputbox milktea-view').engine.wasm).includes('>> hello milktea');});
  await input.evaluate(v=>{window.oldInput=v.engine;});
  await page.locator('#inputbox .restart').click();
  await page.waitForFunction(()=>{const a=document.querySelector('#inputbox milktea-view').engine;return a && a!==window.oldInput && a.wasm.mt_width()>0;});
  assert.equal(await page.evaluate(()=>window.oldInput.stopped),true);
  console.log('PASS demo ordering, lazy WASM, input submission and restart');

  async function checkTabs(id) {
    const view=page.locator(`#${id} milktea-view`);
    const initial=await page.locator(`#${id} .demo-browser`).boundingBox();
    await view.evaluate(v=>{window.tabbedEngine=v.engine;});
    await page.locator(`#${id}-code-tab`).click();
    await page.waitForFunction(id=>document.getElementById(`${id}-code`).dataset.loaded==='true',id);
    await page.waitForFunction(id=>document.querySelector(`#${id} milktea-view`).engine.paused,id);
    assert.ok(await page.locator(`#${id}-code .ink span`).count()>0,`${id} has highlighted code`);
    assert.match(await page.locator(`#${id}-code`).textContent(),/milktea::/);
    const code=await page.locator(`#${id} .demo-browser`).boundingBox();
    assert.ok(Math.abs(initial.height-code.height)<2,`${id} tab switch retains height`);
    if (id==='inputbox') {
      const pane=page.locator('#inputbox-code');
      await pane.evaluate(p=>{p.scrollTop=p.scrollHeight;});
      await pane.hover();
      const top=await page.evaluate(()=>scrollY);
      await page.mouse.wheel(0,160);
      await page.waitForTimeout(150);
      assert.equal(await page.evaluate(()=>scrollY),top,'code bottom holds page scroll');
      await page.mouse.wheel(0,160);
      await page.waitForTimeout(2100);
      assert.equal(await page.evaluate(()=>scrollY),top,'continued wheel input does not scroll during the hold');
      await page.mouse.wheel(0,160);
      await page.waitForFunction(top=>scrollY>top,top);
      await pane.scrollIntoViewIfNeeded();
      await pane.evaluate(p=>{p.scrollTop=0;});
      await pane.hover();
      const atTop=await page.evaluate(()=>scrollY);
      await page.mouse.wheel(0,-160);
      await page.waitForTimeout(150);
      assert.equal(await page.evaluate(()=>scrollY),atTop,'code top also holds page scroll');
    }
    await page.locator(`#${id}-preview-tab`).click();
    assert.equal(await view.evaluate(v=>v.engine===window.tabbedEngine && v.shadowRoot.activeElement===v.canvas),true,`${id} preview keeps state and focuses canvas`);
    await page.waitForFunction(id=>!document.querySelector(`#${id} milktea-view`).engine.paused,id);
  }
  for (const id of ['spinners','timer','splash','doom-fire','doom-fire-tea','spotlight','avian-assault']) {
    const view=page.locator(`#${id} milktea-view`);
    await view.scrollIntoViewIfNeeded();
    await page.waitForFunction(id=>{const a=document.querySelector(`#${id} milktea-view`).engine;return a && a.wasm.mt_width()>0;},id);
    assert.equal(await view.evaluate(v=>v.engine.stopped),false,`${id} runs`);
    await checkTabs(id);
    if (id==='timer') {
      await view.locator('canvas').focus();await page.keyboard.press('Space');
      await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#timer milktea-view').engine.wasm).includes('PAUSED');});
    }
    if (id==='doom-fire') {
      assert.deepEqual(await view.evaluate(v=>[v.engine.wasm.mt_width(),v.engine.wasm.mt_height()]),[100,30]);
      await page.screenshot({path:`/private/tmp/milktea-fire-${browserName}.png`});
    }
    if (id==='avian-assault') {
      assert.equal(await view.evaluate(v=>Math.abs(v.canvas.getBoundingClientRect().height-v.getBoundingClientRect().height)<1),true,'canvas stays inside the game viewport');
      assert.equal(await view.evaluate(v=>v.engine.viewport.scaleX===v.engine.viewport.scaleY && v.engine.cellHeight===v.engine.cellWidth*2),true,'half-block pixels remain square');
      await view.locator('canvas').focus();await page.keyboard.press('Enter');await page.keyboard.press('Enter');
      await page.waitForFunction(async()=>{const {gridText}=await import('/engine.mjs');return gridText(document.querySelector('#avian-assault milktea-view').engine.wasm).includes('Aim');});
    }
  }
  await page.screenshot({path:`/private/tmp/milktea-avian-${browserName}.png`});
  assert.equal(await input.evaluate(v=>v.engine.paused),true);
  console.log('PASS all eight Code/Preview tabs, highlighted source, input focus and retained state');
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
