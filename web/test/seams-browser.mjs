import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(process.env.PLAYWRIGHT_PACKAGE || import.meta.url);
const playwright=require('playwright');
const browserName=process.env.MILKTEA_TEST_BROWSER || 'chromium';
const browser=await playwright[browserName].launch({headless:true});
const origin=process.env.MILKTEA_TEST_URL || 'http://127.0.0.1:8000';
try {
  for (const dpr of [1,1.25,2]) {
    const page=await browser.newPage({viewport:{width:1100,height:800},deviceScaleFactor:dpr});
    await page.route('**/seams-test.html',route=>route.fulfill({contentType:'text/html',body:
      '<script type="module" src="/embed.js"></script><milktea-view id="view" src="/build/doom-fire.wasm" cols="80" rows="24" style="width:756px;height:413px"></milktea-view>'}));
    await page.goto(`${origin}/seams-test.html`);
    await page.waitForFunction(()=>!!document.querySelector('#view').engine);
    for (const name of ['doom-fire','dos-app','avian-assault','nanobots']) {
      if (name!=='doom-fire') {
        await page.$eval('#view',(v,name)=>{v.setAttribute('src','/build/'+name+'.wasm');v.setAttribute('cols',name==='avian-assault'?'160':'80');v.setAttribute('rows',name==='avian-assault'?'48':'24');v.setAttribute('cell-width','9.6');v.setAttribute('cell-height','19.2');},name);
        await page.waitForFunction(()=>!!document.querySelector('#view').engine);
      }
      for (const [width,height] of [[756,413],[867,523],[317,197],[950,570],[1104,662.4]]) {
        const bad=await page.$eval('#view',async(view,{width,height,name})=>{
          const {readGrid}=await import('/engine.js');
          view.style.width=width+'px';view.style.height=height+'px';
          const a=view.engine;a.pause();a.resize();a.wasm.mt_frame();
          const g=readGrid(a.wasm);
          for(let i=0;i<g.cols*g.rows;i++) {
            const p=g.ptr+i*g.stride,s=p+g.style;
            if(name==='nanobots') {
              const glyph=new TextEncoder().encode(String.fromCodePoint(i%2 ? 0x1fb4d : 0x1fb02));
              g.bytes.set(glyph,p);g.bytes[p+8]=glyph.length;g.bytes[p+9]=1;
            } else if(name!=='doom-fire') {g.bytes[p]=32;g.bytes[p+8]=1;g.bytes[p+9]=1;}
            else {
              // Exercise all three optimized block shapes, including shared edges.
              g.bytes.set([0xe2,0x96,[0x80,0x84,0x88][i%3]],p);
              g.bytes[p+8]=3;g.bytes[p+9]=1;
            }
            g.bytes[s+g.attrs]=0;
            g.bytes.set([3,0,240,80,20,255],s);
            g.bytes.set([3,0,180,190,40,255],s+g.colorSize);
          }
          a.paint(0);
          const v=a.viewport,d=a.dpr,left=Math.round(v.offsetX*d),top=Math.round(v.offsetY*d);
          const w=Math.round((v.offsetX+g.cols*a.cellWidth*v.scaleX)*d)-left;
          const h=Math.round((v.offsetY+g.rows*a.cellHeight*v.scaleY)*d)-top;
          const pixels=a.ctx.getImageData(left,top,w,h).data;
          let bad=0;
          if(name==='nanobots') {
            const snap=x=>Math.floor(x+.5+1e-7);
            for(let row=0;row<g.rows;row++)for(let col=0;col<g.cols;col++) {
              const i=row*g.cols+col, fraction=i%2 ? .75 : .15;
              const y=snap((v.offsetY+(row+fraction)*a.cellHeight*v.scaleY)*d)-top;
              const x0=snap((v.offsetX+col*a.cellWidth*v.scaleX)*d)-left;
              const x1=snap((v.offsetX+(col+1)*a.cellWidth*v.scaleX)*d)-left;
              for(let x=x0;x<x1;x++) {
                const offset=(y*w+x)*4;
                if(pixels[offset]!==240 || pixels[offset+1]!==80 || pixels[offset+2]!==20)bad++;
              }
            }
            return bad;
          }
          for(let i=0;i<pixels.length;i+=4) {
            const fg=pixels[i]===240 && pixels[i+1]===80 && pixels[i+2]===20;
            const bg=pixels[i]===180 && pixels[i+1]===190 && pixels[i+2]===40;
            if((!bg && !(name==='doom-fire' && fg)) || pixels[i+3]!==255) bad++;
          }
          return bad;
        },{width,height,name});
        assert.equal(bad,0,`${browserName} ${name} ${width}x${height} DPR ${dpr}: no blended seams`);
      }
    }
    await page.close();
  }
  console.log(`PASS ${browserName}: blocks, legacy glyphs and text backgrounds have zero seams at 5 viewports × 3 pixel densities`);
} finally {await browser.close();}
