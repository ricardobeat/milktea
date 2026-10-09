import test from 'node:test';
import assert from 'node:assert/strict';
import {canvasOptions, canvasViewport, canvasPointer} from '../engine.mjs';

test('responsive embeds: font size and zoom determine cell counts', () => {
  let options = canvasOptions({fontSize: 12});
  let v = canvasViewport(300, 180, options);
  assert.equal(v.cols, 40); assert.equal(v.rows, 12);
  v = canvasViewport(450, 300, options);
  assert.equal(v.cols, 60); assert.equal(v.rows, 20);
  v = canvasViewport(300, 180, canvasOptions({fontSize: 12, scale: 2}));
  assert.equal(v.cols, 20); assert.equal(v.rows, 6);
});
test('fixed embeds: contain centers the same grid in inline and fullscreen sizes', () => {
  const options = canvasOptions({cols: 80, rows: 24});
  const inline = canvasViewport(400, 300, options);
  assert.equal(inline.scaleX, .5); assert.equal(inline.scaleY, .5);
  assert.equal(inline.offsetX, 0); assert.equal(inline.offsetY, 30);
  const fullscreen = canvasViewport(1200, 900, options);
  assert.equal(fullscreen.cols, inline.cols); assert.equal(fullscreen.rows, inline.rows);
  assert.equal(fullscreen.scaleX, 1.5); assert.equal(fullscreen.offsetY, 90);
});
test('mouse: maps contain margins and external CSS scaling to logical coordinates', () => {
  const options = canvasOptions({cols: 80, rows: 24});
  const v = canvasViewport(400, 300, options);
  const rect = {left: 50, top: 20, width: 800, height: 600};
  assert.deepEqual(canvasPointer(rect, v, {clientX: 175, clientY: 230}, 10, 20),
    {px: 125, py: 150, col: 12, row: 7});
  const margin = canvasPointer(rect, v, {clientX: 100, clientY: 30}, 10, 20);
  assert.ok(margin.row < 0, 'letterbox margins must not hit the first row');
});
test('mouse: stretch maps each axis independently', () => {
  const options = canvasOptions({cols: 80, rows: 24, fit: 'stretch'});
  const v = canvasViewport(400, 480, options);
  assert.equal(v.scaleX, .5); assert.equal(v.scaleY, 1);
  assert.deepEqual(canvasPointer({left:0,top:0,width:400,height:480}, v,
    {clientX: 102, clientY: 142}, 10, 20), {px:204,py:142,col:20,row:7});
});
test('viewport: manual zoom, cover cropping, and invalid configuration', () => {
  const v = canvasViewport(400, 300, canvasOptions({cols:80,rows:24,fit:'cover'}));
  assert.equal(v.scaleX, .625); assert.equal(v.offsetX, -50);
  const zoom = canvasViewport(400, 300, canvasOptions({cols:80,rows:24,fit:'none',scale:.25}));
  assert.equal(zoom.scaleX, .25);
  for (const options of [{scale:0}, {fontSize:NaN}, {cols:80}, {cols:0,rows:24}, {fit:'invalid'}]) {
    assert.throws(() => canvasOptions(options), RangeError);
  }
});
