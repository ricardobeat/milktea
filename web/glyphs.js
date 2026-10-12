// Unicode Symbols for Legacy Computing geometry, independent of fonts.
// Diagonal endpoints follow https://www.unicode.org/charts/PDF/U1FB00.pdf
// Unit-cell coordinates; middle edge points divide the height into thirds.
const DIAGONALS = [
  [[0.5,1.0],[0,1],[0.0,0.666666667]], // U+1FB3C
  [[1.0,1.0],[1,1],[0,1],[0.0,0.666666667]], // U+1FB3D
  [[0.5,1.0],[0,1],[0.0,0.333333333]], // U+1FB3E
  [[1.0,1.0],[1,1],[0,1],[0.0,0.333333333]], // U+1FB3F
  [[0,0],[0.0,0.0],[0.5,1.0],[0,1]], // U+1FB40
  [[0.5,0.0],[1,0],[1,1],[0,1],[0.0,0.333333333]], // U+1FB41
  [[1.0,0.0],[1,0],[1,1],[0,1],[0.0,0.333333333]], // U+1FB42
  [[0.5,0.0],[1,0],[1,1],[0,1],[0.0,0.666666667]], // U+1FB43
  [[1.0,0.0],[1,0],[1,1],[0,1],[0.0,0.666666667]], // U+1FB44
  [[0.5,0.0],[1,0],[1,1],[0,1],[0.0,1.0]], // U+1FB45
  [[1.0,0.333333333],[1,1],[0,1],[0.0,0.666666667]], // U+1FB46
  [[1.0,0.666666667],[1,1],[0.5,1.0]], // U+1FB47
  [[1.0,0.666666667],[1,1],[0,1],[0.0,1.0]], // U+1FB48
  [[1.0,0.333333333],[1,1],[0.5,1.0]], // U+1FB49
  [[1.0,0.333333333],[1,1],[0,1],[0.0,1.0]], // U+1FB4A
  [[1.0,0.0],[1,0],[1,1],[0.5,1.0]], // U+1FB4B
  [[0,0],[0.5,0.0],[1.0,0.333333333],[1,1],[0,1]], // U+1FB4C
  [[0,0],[0.0,0.0],[1.0,0.333333333],[1,1],[0,1]], // U+1FB4D
  [[0,0],[0.5,0.0],[1.0,0.666666667],[1,1],[0,1]], // U+1FB4E
  [[0,0],[0.0,0.0],[1.0,0.666666667],[1,1],[0,1]], // U+1FB4F
  [[0,0],[0.5,0.0],[1.0,1.0],[1,1],[0,1]], // U+1FB50
  [[1.0,0.666666667],[1,1],[0,1],[0.0,0.333333333]], // U+1FB51
  [[0,0],[1,0],[1,1],[0.5,1.0],[0.0,0.666666667]], // U+1FB52
  [[0,0],[1,0],[1,1],[1.0,1.0],[0.0,0.666666667]], // U+1FB53
  [[0,0],[1,0],[1,1],[0.5,1.0],[0.0,0.333333333]], // U+1FB54
  [[0,0],[1,0],[1,1],[1.0,1.0],[0.0,0.333333333]], // U+1FB55
  [[0,0],[1,0],[1,1],[0.5,1.0],[0.0,0.0]], // U+1FB56
  [[0,0],[0.5,0.0],[0.0,0.333333333]], // U+1FB57
  [[0,0],[1,0],[1.0,0.0],[0.0,0.333333333]], // U+1FB58
  [[0,0],[0.5,0.0],[0.0,0.666666667]], // U+1FB59
  [[0,0],[1,0],[1.0,0.0],[0.0,0.666666667]], // U+1FB5A
  [[0,0],[0.5,0.0],[0.0,1.0],[0,1]], // U+1FB5B
  [[0,0],[1,0],[1.0,0.333333333],[0.0,0.666666667]], // U+1FB5C
  [[0,0],[1,0],[1.0,0.666666667],[0.5,1.0],[0,1]], // U+1FB5D
  [[0,0],[1,0],[1.0,0.666666667],[0.0,1.0],[0,1]], // U+1FB5E
  [[0,0],[1,0],[1.0,0.333333333],[0.5,1.0],[0,1]], // U+1FB5F
  [[0,0],[1,0],[1.0,0.333333333],[0.0,1.0],[0,1]], // U+1FB60
  [[0,0],[1,0],[1.0,0.0],[0.5,1.0],[0,1]], // U+1FB61
  [[0.5,0.0],[1,0],[1.0,0.333333333]], // U+1FB62
  [[0,0],[1,0],[1.0,0.333333333],[0.0,0.0]], // U+1FB63
  [[0.5,0.0],[1,0],[1.0,0.666666667]], // U+1FB64
  [[0,0],[1,0],[1.0,0.666666667],[0.0,0.0]], // U+1FB65
  [[0.5,0.0],[1,0],[1,1],[1.0,1.0]], // U+1FB66
  [[0,0],[1,0],[1.0,0.666666667],[0.0,0.333333333]], // U+1FB67
 ];

function fillPolygon(ctx, points, x, y, w, h, snap) {
  ctx.beginPath();
  points.forEach(([px, py], i) => {
    if (i === 0) ctx.moveTo(snap(x + px * w), snap(y + py * h));
    else ctx.lineTo(snap(x + px * w), snap(y + py * h));
  });
  ctx.closePath(); ctx.fill();
}

export function drawLegacyGlyph(ctx, cp, x, y, w, h, snap = value => value) {
  if (cp >= 0x1fb00 && cp <= 0x1fb3b) {
    // Sextants are numbered row-major. Left/right half and full blocks
    // already have older Unicode characters, so their masks are skipped.
    let mask = cp - 0x1fb00 + 1;
    if (mask >= 21) mask++;
    if (mask >= 42) mask++;
    for (let i = 0; i < 6; i++) if (mask & (1 << i)) {
      const left = snap(x + (i % 2) * w / 2), top = snap(y + Math.floor(i / 2) * h / 3);
      const right = snap(x + (i % 2 + 1) * w / 2), bottom = snap(y + (Math.floor(i / 2) + 1) * h / 3);
      ctx.fillRect(left, top, right - left, bottom - top);
    }
  } else if (cp >= 0x1fb3c && cp <= 0x1fb67) {
    fillPolygon(ctx, DIAGONALS[cp - 0x1fb3c], x, y, w, h, snap);
  } else if (cp >= 0x1fb68 && cp <= 0x1fb6f) {
    const sides = [
      [[0, 0], [0, 1], [.5, .5]], // left quarter
      [[0, 0], [1, 0], [.5, .5]], // upper quarter
      [[1, 0], [1, 1], [.5, .5]], // right quarter
      [[0, 1], [1, 1], [.5, .5]], // lower quarter
    ];
    if (cp >= 0x1fb6c) fillPolygon(ctx, sides[cp - 0x1fb6c], x, y, w, h, snap);
    else {
      // Three-quarter shapes are the cell minus the opposite quarter.
      const missing = [0, 1, 2, 3][cp - 0x1fb68];
      ctx.beginPath(); ctx.rect(x, y, w, h);
      sides[missing].forEach(([px, py], i) => {
        if (i === 0) ctx.moveTo(snap(x + px * w), snap(y + py * h));
        else ctx.lineTo(snap(x + px * w), snap(y + py * h));
      });
      ctx.closePath(); ctx.fill('evenodd');
    }
  } else return false;
  return true;
}
