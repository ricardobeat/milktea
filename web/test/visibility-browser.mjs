import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const {chromium}=require('playwright');
const browser=await chromium.launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  const page=await browser.newPage({viewport:{width:1000,height:700}});
  await page.route('**/visibility-test.html',route=>route.fulfill({contentType:'text/html',body:
    '<script type="module" src="/embed.js"></script><milktea-view id="one" loading="eager" src="/build/spinners.wasm" style="width:400px;height:200px"></milktea-view><milktea-view id="two" loading="eager" src="/build/spinners.wasm" style="width:400px;height:200px"></milktea-view><div style="height:1600px"></div><milktea-view id="offscreen" loading="eager" src="/build/spinners.wasm"></milktea-view>'}));
  await page.goto(origin+'/visibility-test.html');
  await page.waitForFunction(()=>[...document.querySelectorAll('milktea-view')].every(v=>v.engine));
  assert.equal(await page.$eval('#offscreen',v=>v.engine.paused && v.engine.raf===null || v.engine.paused && v.engine.raf===undefined),true,'eager offscreen embed starts without RAF');
  await page.$eval('#one',v=>{
    const a=v.engine,frame=a.frame.bind(a);a.frames=0;
    a.frame=t=>{a.frames++;frame(t);};
  });
  await page.waitForFunction(()=>document.querySelector('#one').engine.frames>2);
  await page.$eval('#one',v=>v.hidden=true);
  await page.waitForFunction(()=>document.querySelector('#one').engine.paused);
  let count=await page.$eval('#one',v=>v.engine.frames);
  await page.waitForTimeout(100);
  assert.equal(await page.$eval('#one',v=>v.engine.frames),count,'hidden panel schedules no frames');
  assert.equal(await page.$eval('#one',v=>v.engine.raf),null);
  await page.$eval('#one',v=>v.hidden=false);
  await page.waitForFunction(n=>document.querySelector('#one').engine.frames>n,count);
  await page.$eval('#offscreen',v=>v.scrollIntoView());
  await page.waitForFunction(()=>document.querySelector('#one').engine.paused);
  count=await page.$eval('#one',v=>v.engine.frames);
  await page.waitForTimeout(100);
  assert.equal(await page.$eval('#one',v=>v.engine.frames),count,'offscreen embed schedules no frames');
  await page.$eval('#one',v=>v.scrollIntoView());
  await page.waitForFunction(()=>!document.querySelector('#one').engine.paused);
  await page.locator('#one').locator('button').click();
  await page.waitForFunction(()=>document.fullscreenElement && document.querySelector('#two').engine.paused);
  await page.keyboard.press('Escape');
  await page.waitForFunction(()=>!document.fullscreenElement && !document.querySelector('#two').engine.paused);
  await page.evaluate(()=>{
    Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});
    document.dispatchEvent(new Event('visibilitychange'));
  });
  assert.equal(await page.evaluate(()=>[...document.querySelectorAll('milktea-view')].every(v=>v.engine.paused && v.engine.raf===null)),true,'page visibility cancels all RAFs');
  await page.evaluate(()=>{delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));});
  await page.waitForFunction(()=>!document.querySelector('#one').engine.paused);
  console.log('PASS RAF stops offscreen, in hidden panels, behind fullscreen, and on page visibility changes');
} finally {await browser.close();}
