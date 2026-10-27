// The orange header is a field of block-drawing characters, every cell a
// slightly different shade of orange. At the bottom the field breaks into a
// jagged staircase; below it the page shows through, with light (░) and
// medium (▒) shade characters scattered around the boundary.

const CELL_W = 12;
const CELL_H = 24;

const SHADE_FONT = '"Geist Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';

// Deterministic hash of a cell position, so resizing adds or removes cells
// instead of reshuffling the whole field.
function hash(x, y, salt = 0) {
  let n = Math.imul(x | 0, 374761393) + Math.imul(y | 0, 668265263) + Math.imul(salt | 0, 1442695041);
  n = Math.imul(n ^ (n >>> 13), 1274126177);
  return ((n ^ (n >>> 16)) >>> 0) / 4294967296;
}

function parseHex(value) {
  const match = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec((value || '').trim());
  return match ? [1, 2, 3].map(index => parseInt(match[index], 16)) : null;
}

function toHsl([r, g, b]) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), delta = max - min;
  let hue = 0;
  if (delta) {
    if (max === r) hue = ((g - b) / delta) % 6;
    else if (max === g) hue = (b - r) / delta + 2;
    else hue = (r - g) / delta + 4;
    hue *= 60;
    if (hue < 0) hue += 360;
  }
  const light = (max + min) / 2;
  const sat = delta ? delta / (1 - Math.abs(2 * light - 1)) : 0;
  return [hue, sat * 100, light * 100];
}

function shade([hue, sat, light], col, row) {
  const h = hue + (hash(col, row, 1) - .5) * 3;
  const s = Math.min(100, Math.max(0, sat + (hash(col, row, 2) - .5) * 5));
  const l = light + (hash(col, row, 3) - .5) * 10;
  return `hsl(${h.toFixed(1)},${s.toFixed(1)}%,${l.toFixed(1)}%)`;
}

function mount(element) {
  const canvas = document.createElement('canvas');
  canvas.className = 'block-field';
  canvas.setAttribute('aria-hidden', 'true');
  element.insertBefore(canvas, element.firstChild);

  const ctx = canvas.getContext('2d');
  const edge = element.querySelector(':scope > .poster-edge');

  function paint() {
    const width = element.clientWidth;
    const height = element.clientHeight;
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    if (!width || !height) return;

    const styles = getComputedStyle(element);
    const paper = getComputedStyle(document.documentElement).getPropertyValue('--paper').trim();
    const orangeCss = styles.getPropertyValue('--orange').trim();
    const orange = toHsl(parseHex(orangeCss) || [249, 106, 36]);

    const columns = Math.ceil(width / CELL_W);
    const rows = Math.ceil(height / CELL_H);

    // One staircase step per 24px, snapped to whole cells: the field climbs
    // and drops a cell or two at a time, leaving V shapes behind.
    const maxDrop = edge ? Math.max(2, Math.round(edge.offsetHeight / CELL_H) - 1) : 0;
    const drops = [];
    let drop = 2;
    for (let col = 0; col < columns; col += 2) {
      drop = edge ? Math.max(1, Math.min(maxDrop, drop + Math.round((hash(col, 2, 57) - .5) * 4))) : 0;
      drops.push(drop, drop);
    }

    // Shade characters are stretched to the cell, the way a terminal draws
    // them: the full block sets the box, every other glyph shares its box.
    ctx.font = `100px ${SHADE_FONT}`;
    const box = ctx.measureText('█');
    const scaleX = CELL_W / (box.actualBoundingBoxLeft + box.actualBoundingBoxRight);
    const scaleY = CELL_H / (box.actualBoundingBoxAscent + box.actualBoundingBoxDescent);
    const shadeGlyph = (character, x, y, color) => {
      ctx.fillStyle = color;
      ctx.setTransform(scaleX * dpr, 0, 0, scaleY * dpr,
        (x - box.actualBoundingBoxLeft * scaleX) * dpr,
        (y + box.actualBoundingBoxAscent * scaleY) * dpr);
      ctx.fillText(character, 0, 0);
    };

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    for (let col = 0; col < columns; col++) {
      const left = col * CELL_W;
      const line = rows - drops[col];
      for (let row = 0; row < rows; row++) {
        const top = row * CELL_H;
        if (row >= line) {
          if (edge && row < Math.min(rows, line + 2) && hash(col, row, 63) < (row === line ? .5 : .25)) {
            shadeGlyph(hash(col, row, 64) < .3 ? '▒' : '░', left, top, orangeCss);
          }
          continue;
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.fillStyle = orangeCss;
        ctx.fillRect(left, top, CELL_W, CELL_H);
        ctx.fillStyle = shade(orange, col, row);
        const shape = hash(col, row, 7);
        if (shape < .05) ctx.fillRect(left, top, CELL_W, CELL_H / 2);
        else if (shape < .1) ctx.fillRect(left, top + CELL_H / 2, CELL_W, CELL_H / 2);
        else if (shape < .13) ctx.fillRect(left, top, CELL_W / 2, CELL_H);
        else if (shape < .16) ctx.fillRect(left + CELL_W / 2, top, CELL_W / 2, CELL_H);
        else ctx.fillRect(left, top, CELL_W, CELL_H);
        if (edge && line - row <= 2 && hash(col, row, 61) < (line - row === 1 ? .45 : .25)) {
          shadeGlyph(hash(col, row, 62) < .3 ? '▒' : '░', left, top, paper);
        }
      }
    }
  }

  new ResizeObserver(paint).observe(element);
  paint();
  if (document.fonts) document.fonts.ready.then(paint);
}

for (const element of document.querySelectorAll('.poster, .site-nav')) mount(element);
