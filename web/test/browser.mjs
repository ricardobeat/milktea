// Optional real-browser checks. Install Playwright, serve web/, then run this.
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const {chromium} = require('playwright');
const origin = process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
const browser = await chromium.launch({headless: true});
const errors = [];
async function pageFor(body) {
  const page = await browser.newPage({viewport:{width:1100,height:800}, deviceScaleFactor:2});
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/embed-test.html', route => route.fulfill({contentType:'text/html', body:
    `<html><head><script type="module" src="/embed.mjs"></script></head><body style="margin:0">${body}</body></html>`}));
  await page.goto(`${origin}/embed-test.html`);
  return page;
}
try {
  const lazy = await pageFor(`<milktea-view id="visible" src="/build/mouse.wasm" style="width:400px;height:240px"></milktea-view>
    <div style="height:1400px"></div>
    <milktea-view id="one" src="/build/counter.wasm" style="width:350px;height:180px"></milktea-view>
    <milktea-view id="two" src="/build/counter.wasm" style="width:350px;height:180px"></milktea-view>`);
  const requests = [];
  // Resource timing also captures requests made before this listener attaches.
  lazy.on('request', request => {if (request.url().endsWith('/counter.wasm')) requests.push(request.url());});
  await lazy.waitForFunction(() => !!document.querySelector('#visible').engine);
  assert.equal(await lazy.evaluate(() => performance.getEntriesByType('resource').filter(r => r.name.endsWith('/counter.wasm')).length), 0);
  assert.equal(await lazy.$eval('#one', v => !!v.engine), false);
  await lazy.locator('#one').scrollIntoViewIfNeeded();
  await lazy.waitForFunction(() => document.querySelector('#one').engine && document.querySelector('#two').engine);
  assert.equal(requests.length, 1, 'same-source embeds should share a download and compiled module');
  assert.equal(await lazy.evaluate(async () => {
    const {gridText} = await import('/engine.mjs');
    const a = document.querySelector('#one').engine, b = document.querySelector('#two').engine;
    a.wasm.mt_key(6,0,0,0); a.wasm.mt_frame(); b.wasm.mt_frame();
    return a.wasm.memory !== b.wasm.memory && gridText(a.wasm).includes('Counter: 1') && gridText(b.wasm).includes('Counter: 0');
  }), true, 'instances must have independent state');
  await lazy.waitForFunction(() => document.querySelector('#visible').engine.paused);
  await lazy.close();
  console.log('PASS lazy loading, shared compilation, independent state, offscreen pause');

  const mouse = await pageFor('<milktea-view id="view" src="/build/mouse.wasm" cols="64" rows="20" style="width:400px;height:240px;transform:scale(.75);transform-origin:top left"></milktea-view>');
  await mouse.waitForFunction(() => !!document.querySelector('#view').engine);
  const point = await mouse.$eval('#view', view => {
    const a = view.engine, r = a.canvas.getBoundingClientRect(), v = a.viewport;
    return {x:r.left+(v.offsetX+12.5*a.cellWidth*v.scaleX)*r.width/v.width,
      y:r.top+(v.offsetY+7.5*a.cellHeight*v.scaleY)*r.height/v.height};
  });
  await mouse.mouse.click(point.x, point.y);
  await mouse.waitForFunction(async () => {
    const {gridText} = await import('/engine.mjs');
    return gridText(document.querySelector('#view').engine.wasm).includes('Position: (12, 7)');
  });
  assert.equal(await mouse.$eval('#view', view => view.engine.canvas.width === view.engine.canvas.clientWidth * 2), true);
  await mouse.close();
  console.log('PASS scaled mouse coordinates and high-DPI canvas');

  const fire = await pageFor('<milktea-view id="view" src="/build/doom-fire.wasm" cols="80" rows="24" style="width:867px;height:523px"></milktea-view>');
  await fire.waitForFunction(() => !!document.querySelector('#view').engine);
  const seams = await fire.$eval('#view', async view => {
    const {readGrid} = await import('/engine.mjs');
    const a = view.engine;
    a.pause();
    const g = readGrid(a.wasm);
    // Uniform half-block colors reveal antialiased cell edges. Every pixel
    // inside the grid must be exactly one of these two opaque colors.
    for (let i = 0; i < g.cols * g.rows; i++) {
      const s = g.ptr + i * g.stride + g.style;
      g.bytes.set([3,0,240,80,20,255], s);
      g.bytes.set([3,0,180,190,40,255], s + g.colorSize);
    }
    a.paint(0);
    const v = a.viewport, d = a.dpr;
    const left = Math.round(d*v.offsetX), top = Math.round(d*v.offsetY);
    const width = Math.round(d*(v.offsetX+g.cols*a.cellWidth*v.scaleX))-left;
    const height = Math.round(d*(v.offsetY+g.rows*a.cellHeight*v.scaleY))-top;
    const pixels = a.ctx.getImageData(left,top,width,height).data;
    let unexpected = 0;
    for (let i = 0; i < pixels.length; i += 4) {
      const fg = pixels[i]===240 && pixels[i+1]===80 && pixels[i+2]===20;
      const bg = pixels[i]===180 && pixels[i+1]===190 && pixels[i+2]===40;
      if ((!fg && !bg) || pixels[i+3]!==255) unexpected++;
    }
    return unexpected;
  });
  assert.equal(seams, 0, 'fractionally scaled fire cells must have no blended grid seams');
  await fire.close();
  console.log('PASS fractional-scale fire cells have no grid seams');

  const sizing = await pageFor('<milktea-view id="view" src="/build/counter.wasm" style="width:400px;height:200px"></milktea-view>');
  await sizing.waitForFunction(() => !!document.querySelector('#view').engine);
  assert.deepEqual(await sizing.$eval('#view', v => [v.engine.cols,v.engine.rows]), [40,10]);
  await sizing.$eval('#view', v => v.setAttribute('font-size','12'));
  await sizing.waitForFunction(() => document.querySelector('#view').engine.cols === 53);
  await sizing.$eval('#view', v => {v.style.width='600px';v.style.height='300px';});
  await sizing.waitForFunction(() => document.querySelector('#view').engine.cols === 80 && document.querySelector('#view').engine.rows === 20);
  await sizing.$eval('#view', v => v.setAttribute('scale','2'));
  await sizing.waitForFunction(() => document.querySelector('#view').engine.cols === 40 && document.querySelector('#view').engine.rows === 10);
  await sizing.evaluate(() => {window.originalEngine=document.querySelector('#view').engine;});
  await sizing.locator('#view').locator('button').click();
  await sizing.waitForFunction(() => document.fullscreenElement === document.querySelector('#view'));
  assert.equal(await sizing.$eval('#view', v => v.engine === window.originalEngine), true);
  assert.equal(await sizing.$eval('#view', v => {
    const a=v.engine;
    return a.cols>=48 && a.rows>=12 && a.viewport.scaleX===a.viewport.scaleY &&
      a.viewport.offsetX<innerWidth/a.cols && a.viewport.offsetY<innerHeight/a.rows;
  }), true, 'fullscreen expands the grid to fit the screen with higher density');
  await sizing.keyboard.press('Escape');
  await sizing.waitForFunction(() => !document.fullscreenElement);
  assert.equal(await sizing.$eval('#view', v => v.engine === window.originalEngine && !v.engine.stopped), true);
  assert.deepEqual(await sizing.$eval('#view', v => [v.engine.cols,v.engine.rows]), [40,10]);
  await sizing.locator('#view').locator('canvas').click();
  await sizing.keyboard.press('ArrowUp');
  await sizing.waitForFunction(async () => {
    const {gridText} = await import('/engine.mjs');
    return gridText(document.querySelector('#view').engine.wasm).includes('Counter: 1');
  });
  await sizing.$eval('#view', v => {window.previousEngine=v.engine;v.restart();});
  await sizing.waitForFunction(async () => {
    const {gridText}=await import('/engine.mjs');
    const app=document.querySelector('#view').engine;
    return app && app!==window.previousEngine && gridText(app.wasm).includes('Counter: 0');
  });
  assert.equal(await sizing.evaluate(()=>window.previousEngine.stopped),true);
  await sizing.$eval('#view', view => {window.removedEngine=view.engine;view.remove();});
  assert.equal(await sizing.evaluate(() => window.removedEngine.stopped), true);
  await sizing.close();
  console.log('PASS live resizing, font size, zoom, real fullscreen, Escape, keyboard, cleanup');
  assert.deepEqual(errors, []);
} finally { await browser.close(); }
