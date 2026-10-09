import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {drawLegacyGlyph} from '../glyphs.mjs';

function context() {
  const shapes = [];
  let paths = [];
  return {
    shapes,
    beginPath() { paths = []; },
    moveTo(x, y) { paths.push([[x, y]]); },
    lineTo(x, y) { paths.at(-1).push([x, y]); },
    closePath() {},
    rect(x, y, w, h) { paths.push([[x,y],[x+w,y],[x+w,y+h],[x,y+h]]); },
    fill(rule) { shapes.push({paths, rule}); },
    fillRect(x, y, w, h) { shapes.push({paths: [[[x,y],[x+w,y],[x+w,y+h],[x,y+h]]]}); },
  };
}
function area(ctx) {
  const polygonArea = points => Math.abs(points.reduce((sum, [x,y], i) => {
    const [nx,ny] = points[(i + 1) % points.length];
    return sum + x * ny - nx * y;
  }, 0)) / 2;
  return ctx.shapes.reduce((sum, {paths, rule}) => sum + paths.reduce((subtotal, points, i) =>
    subtotal + (rule === 'evenodd' && i > 0 ? -1 : 1) * polygonArea(points), 0), 0);
}
function glyphArea(cp) {
  const ctx = context();
  assert.equal(drawLegacyGlyph(ctx, cp, 0, 0, 1, 1), true);
  return area(ctx);
}
test('legacy glyphs: every special block in nanobots has canvas geometry', async () => {
  const text = await readFile(new URL('../../examples/nanobots/milktea.txt', import.meta.url), 'utf8');
  const chars = [...new Set([...text].filter(c => c.codePointAt(0) >= 0x1fb00))];
  assert.ok(chars.length >= 20);
  for (const char of chars) {
    const ctx = context();
    assert.equal(drawLegacyGlyph(ctx, char.codePointAt(0), 10, 20, 12, 24), true, char);
    assert.ok(ctx.shapes.length > 0, char);
    assert.ok(area(ctx) > 0 && area(ctx) < 12 * 24, char);
    for (const {paths} of ctx.shapes) for (const points of paths) for (const [x,y] of points) {
      assert.ok(x >= 10 && x <= 22 && y >= 20 && y <= 44, char);
    }
  }
});
test('sextants: top two rows and all but lower-right match the embedded word', () => {
  assert.ok(Math.abs(glyphArea(0x1fb0e) - 2 / 3) < 1e-8); // 🬎 sextants 1234
  assert.ok(Math.abs(glyphArea(0x1fb1d) - 5 / 6) < 1e-8); // 🬝 sextants 12345
});
test('diagonal blocks: quarter shapes and their complements preserve area', () => {
  assert.ok(Math.abs(glyphArea(0x1fb4b) - .25) < 1e-8); // 🭋 lower-right quarter
  assert.ok(Math.abs(glyphArea(0x1fb61) - .75) < 1e-8); // 🭡 upper-left complement
  assert.ok(Math.abs(glyphArea(0x1fb5b) - .25) < 1e-8); // 🭛 upper-left quarter
  assert.ok(Math.abs(glyphArea(0x1fb45) - .75) < 1e-8); // 🭅 lower-right complement
  for (let cp = 0x1fb3c; cp <= 0x1fb51; cp++) {
    assert.ok(Math.abs(glyphArea(cp) + glyphArea(cp + 22) - 1) < 1e-8);
  }
});
test('triangular blocks: all four three-quarter complements and quarters', () => {
  for (let cp = 0x1fb68; cp <= 0x1fb6b; cp++) assert.equal(glyphArea(cp), .75);
  for (let cp = 0x1fb6c; cp <= 0x1fb6f; cp++) assert.equal(glyphArea(cp), .25);
  assert.equal(drawLegacyGlyph(context(), 'A'.codePointAt(0), 0, 0, 1, 1), false);
});
