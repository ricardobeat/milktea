// The orange header is a field of block-drawing characters, every cell a
// slightly different shade of orange. At the bottom the field breaks into a
// jagged staircase; below it the page shows through, with light (░) and
// medium (▒) shade characters scattered around the boundary.

const CELL_W = 12;
const CELL_H = 24;

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

function shade([hue, sat, light], col, row, glow = 0) {
  const h = hue + (hash(col, row, 1) - .5) * 3 + glow * 6;
  const s = Math.min(100, Math.max(0, sat + (hash(col, row, 2) - .5) * 5));
  const l = Math.min(92, light + (hash(col, row, 3) - .5) * 10 + glow * 18);
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

    // ░ ▒ ▓ drawn the way a terminal font does: every pattern sits on the same
    // grid of DOT-sized pixels, anchored at the cell origin, so neighbouring
    // cells tile seamlessly whatever their shade. ░ is a staggered dot lattice on
    // odd rows, ▓ the same lattice as holes on even rows, ▒ a checker: every
    // shade reaches all four edges of the cell the same way.
    const DOT = 2;
    const pattern = [
      (i, j) => j % 2 === 1 && (i + (j >> 1)) % 2 === 0,
      (i, j) => (i + j) % 2 === 0,
      (i, j) => !(j % 2 === 0 && (i + (j >> 1)) % 2 === 0),
    ];
    const shadeCell = (level, left, top, color) => {
      ctx.fillStyle = color;
      for (let j = 0; j < CELL_H / DOT; j++) for (let i = 0; i < CELL_W / DOT; i++) {
        if (pattern[level](i, j)) ctx.fillRect(left + i * DOT, top + j * DOT, DOT, DOT);
      }
    };

    // One cell, optionally brightened by the cursor glimmer (glow 0..1).
    drawCell = (col, row, glow = 0) => {
      const left = col * CELL_W;
      const top = row * CELL_H;
      const line = rows - drops[col];
      ctx.clearRect(left, top, CELL_W, CELL_H);
      if (row >= line) {
        // Just below the ragged edge: a few stray ░ / ▒ left over from the
        // field, never in the last row where they would hang off the poster.
        if (edge && row === line && row < rows - 1 && hash(col, row, 63) < .5) {
          shadeCell(hash(col, row, 64) < .3 ? 1 : 0, left, top, shade(orange, col, row, glow));
        }
        return;
      }
      // Toward the edge the solid blocks thin out: █ -> ▓ -> ▒ -> ░.
      const depth = line - row;
      const level = edge ? depth - 1 + (hash(col, row, 61) < .35 ? 1 : 0) - (hash(col, row, 62) < .25 ? 1 : 0) : 3;
      if (level < 3) {
        ctx.fillStyle = paper;
        ctx.fillRect(left, top, CELL_W, CELL_H);
        shadeCell(Math.max(0, level), left, top, shade(orange, col, row, glow));
        return;
      }
      ctx.fillStyle = orangeCss;
      ctx.fillRect(left, top, CELL_W, CELL_H);
      ctx.fillStyle = shade(orange, col, row, glow);
      const shape = hash(col, row, 7);
      if (shape < .05) ctx.fillRect(left, top, CELL_W, CELL_H / 2);
      else if (shape < .1) ctx.fillRect(left, top + CELL_H / 2, CELL_W, CELL_H / 2);
      else if (shape < .13) ctx.fillRect(left, top, CELL_W / 2, CELL_H);
      else if (shape < .16) ctx.fillRect(left + CELL_W / 2, top, CELL_W / 2, CELL_H);
      else ctx.fillRect(left, top, CELL_W, CELL_H);
    };
    grid = {columns, rows};
    lit.clear();

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    for (let col = 0; col < columns; col++) {
      for (let row = 0; row < rows; row++) drawCell(col, row);
    }
  }

  // Glimmer: every so often a streak of light dashes across the field from
  // left to right, at a random height that favours the title lines. Cells it
  // passes brighten and twinkle, each on its own phase, then settle back.
  let drawCell = null, grid = null, dash = null, frame = 0, last = 0, wait = 800;
  const lit = new Set();
  const RADIUS = 150;
  const STRETCH = 2.2; // the streak is longer than it is tall

  let first = true;
  function pickHeight() {
    const box = element.getBoundingClientRect();
    // The first streak after load runs right under the MILKTEA heading.
    const heading = element.querySelector('h1');
    if (first && heading) {
      first = false;
      return heading.getBoundingClientRect().bottom - box.top;
    }
    const titles = [...element.querySelectorAll('h1, h2')];
    if (titles.length && Math.random() < .75) {
      const title = titles[Math.floor(Math.random() * titles.length)].getBoundingClientRect();
      return title.top - box.top + Math.random() * title.height;
    }
    return Math.random() * box.height;
  }

  function glimmer(time) {
    frame = requestAnimationFrame(glimmer);
    if (!drawCell) return;
    const dt = Math.min(64, time - (last || time));
    last = time;
    if (!dash) {
      wait -= dt;
      if (wait <= 0) dash = {x: -RADIUS * STRETCH, y: pickHeight(), speed: .9 + Math.random() * .8};
    } else {
      dash.x += dash.speed * dt;
      if (dash.x > grid.columns * CELL_W + RADIUS * STRETCH) {
        dash = null;
        wait = 1500 + Math.random() * 3500;
      }
    }
    const next = new Set();
    if (dash) {
      const reach = RADIUS * STRETCH;
      const c0 = Math.max(0, Math.floor((dash.x - reach) / CELL_W));
      const c1 = Math.min(grid.columns - 1, Math.floor((dash.x + reach) / CELL_W));
      const r0 = Math.max(0, Math.floor((dash.y - RADIUS) / CELL_H));
      const r1 = Math.min(grid.rows - 1, Math.floor((dash.y + RADIUS) / CELL_H));
      for (let col = c0; col <= c1; col++) for (let row = r0; row <= r1; row++) {
        const dx = ((col + .5) * CELL_W - dash.x) / STRETCH, dy = (row + .5) * CELL_H - dash.y;
        const falloff = 1 - Math.hypot(dx, dy) / RADIUS;
        if (falloff <= 0) continue;
        const twinkle = .5 + .5 * Math.sin(time / (180 + hash(col, row, 71) * 260) + hash(col, row, 72) * 6.283);
        drawCell(col, row, falloff * falloff * twinkle);
        next.add(col * 65536 + row);
      }
    }
    for (const key of lit) if (!next.has(key)) drawCell(Math.floor(key / 65536), key % 65536);
    lit.clear();
    for (const key of next) lit.add(key);
  }

  // Only the poster gets the streak; the sticky nav stays still.
  if (edge && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    frame = requestAnimationFrame(glimmer);
  }

  new ResizeObserver(paint).observe(element);
  paint();
}

for (const element of document.querySelectorAll('.poster, .site-nav')) mount(element);
