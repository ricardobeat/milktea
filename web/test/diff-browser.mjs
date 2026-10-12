import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const browserName=process.env.MILKTEA_TEST_BROWSER || 'chromium';
const browser=await require('playwright')[browserName].launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  const page=await browser.newPage({viewport:{width:1000,height:700},deviceScaleFactor:1.25});
  await page.goto(origin);
  const results=await page.evaluate(async()=>{
    const {mount,text}=await import('/bindings.js');
    const canvas=document.createElement('canvas');
    canvas.style.cssText='width:537px;height:263px';document.body.append(canvas);
    canvas.getContext('2d', {willReadFrequently:true});
    let value='Counter: 0', style={foreground:'#e0c080',background:'#213547'};
    const app=await mount(canvas,{init:()=>[{}],update:m=>[m],view:()=>text(value,{style})},
      {cols:40,rows:12,cellWidth:9.6,cellHeight:19.2,autoStart:false});
    const a=app.engine,w=a.wasm;
    let cursorX=-1,cursorY=0;
    a.wasm={...w,mt_cursor_x:()=>cursorX,mt_cursor_y:()=>cursorY,mt_cursor_shape:()=>0,mt_cursor_blink:()=>true};
    const pixels=()=>a.ctx.getImageData(0,0,canvas.width,canvas.height).data;
    const results=[];
    function compare(label,blink=0) {
      // Prime font rasterization/readback after allocating or resizing a canvas.
      if (a.repaint || w.mt_full_redraw()) { a.paint(blink); pixels(); }
      let area=0;
      const fill=a.ctx.fillRect.bind(a.ctx);
      a.ctx.fillRect=(x,y,w,h)=>{area+=Math.abs(w*h);fill(x,y,w,h);};
      a.paint(blink,true);
      a.ctx.fillRect=fill;
      const partial=pixels();
      a.paint(blink);
      const full=pixels();
      let maxDelta=0;for(let i=0;i<full.length;i++)maxDelta=Math.max(maxDelta,Math.abs(full[i]-partial[i]));
      results.push({label,maxDelta,damage:w.mt_dirty_count(),area});
      a.blink=blink;a.repaint=false;
    }
    w.mt_frame();compare('initial');
    value='Counter: 1';w.mt_key(6,0,0,0);w.mt_frame();compare('one digit');
    w.mt_frame();compare('idle');
    for(const next of ['界x','a界','abc','','\x1b[5mblink\x1b[0m']) {
      value=next;w.mt_key(6,0,0,0);w.mt_frame();compare('text '+next);
    }
    w.mt_frame();compare('blink off',1);compare('blink on',0);
    cursorX=1;compare('cursor appears');cursorX=4;compare('cursor moves');
    compare('cursor blinks off',1);compare('cursor blinks on',0);
    cursorX=-1;compare('cursor disappears');
    a.setOptions({cols:52,rows:16});w.mt_frame();compare('resize');
    a.setOptions({foreground:'#00ff88',fontSize:18});compare('font and theme');
    app.stop();canvas.remove();
    return results;
  });
  // WebKit can round antialiased text channels by one on repeated readbacks.
  for(const result of results)assert.ok(result.maxDelta <= (browserName==='webkit' ? 1 : 0),result.label+' matches full repaint (delta '+result.maxDelta+')');
  assert.equal(results.find(r=>r.label==='one digit').damage,1);
  assert.ok(results.find(r=>r.label==='one digit').area<2000,'single-cell update paints a small area');
  assert.equal(results.find(r=>r.label==='idle').area,0,'idle output does not draw any fills');
  console.log('PASS '+browserName+': incremental pixels match full redraw for text, wide glyphs, erasure, blink, cursor, resize and styles');
} finally {await browser.close();}
