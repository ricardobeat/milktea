// Editor-ready modules: style definitions stay separate from model and layout.
export const presets = {
  counter: `import { text, vstack, hstack } from 'milktea';

const styles = {
  counter: {
    foreground: '#e4b2d6',
    background: '#393047',
    backgroundGradient: '#1b2132',
    bold: true,
    border: 'double',
    borderForeground: '#72e2be',
    padding: [1, 3, 1, 3]
  },
  decrement: { background: '#554064', foreground: '#f4e6ff', bold: true },
  increment: { background: '#29534c', foreground: '#9af3d1', bold: true },
  buttonShadow: { opacity: 100 }
};

export default {
  init() {
    return [{ count: 0 }];
  },
  update(msg, model) {
    if (
      (msg.type === 'key' && msg.key === 'ArrowUp') ||
      (msg.type === 'click' && msg.id === 'plus')
    )
      return [{ count: model.count + 1 }];
    if (
      (msg.type === 'key' && msg.key === 'ArrowDown') ||
      (msg.type === 'click' && msg.id === 'minus')
    )
      return [{ count: model.count - 1 }];
    return [model];
  },
  view(model, screen) {
    return vstack(
      [
        text('Counter: ' + model.count, { style: styles.counter }),
        hstack(
          [
            text(' − ', {
              onClick: 'minus',
              shadow: styles.buttonShadow,
              style: styles.decrement
            }),
            text(' + ', {
              onClick: 'plus',
              shadow: styles.buttonShadow,
              style: styles.increment
            })
          ],
          { gap: 2 }
        ),
        text('Use ↑ / ↓ or click the buttons'),
        text(screen.cols + ' × ' + screen.rows + ' cells')
      ],
      { gap: 1, center: true }
    );
  }
};`,
  clock: `import { text, vstack, tick } from 'milktea';

const styles = {
  header: {
    foreground: '#e4b2d6',
    background: '#29283d',
    bold: true,
    border: 'rounded',
    borderForeground: '#86b8f9',
    padding: [1, 2, 0, 2]
  },
  track: {
    foreground: '#72e2be',
    background: '#21313b',
    backgroundGradient: '#1c2030',
    border: 'double',
    borderForeground: '#72e2be',
    borderAnimation: 'pulse',
    padding: 1
  }
};

export default {
  init() {
    return [{ frame: 0 }, tick(60)];
  },
  update(msg, model) {
    if (msg.type === 'tick') return [{ frame: model.frame + 1 }, tick(60)];
    return [model];
  },
  view(model) {
    const dots = '●'.repeat((model.frame % 20) + 1);
    return vstack(
      [
        text('One-shot timers, re-armed from update', {
          height: 4,
          style: styles.header
        }),
        text(dots, { height: 5, style: styles.track }),
        text('Frame ' + model.frame)
      ],
      { gap: 1, padding: 2 }
    );
  }
};`,
  input: `import { text, vstack } from 'milktea';

const styles = {
  hint: { foreground: '#e4b2d6' },
  field: {
    border: 'rounded',
    borderForeground: '#72e2be',
    cornerForeground: '#e4b2d6',
    foreground: '#f0e8fa',
    background: '#302a43',
    backgroundGradient: '#1a2933',
    padding: [1, 2, 1, 2]
  },
  caption: { foreground: '#8d95b1', italic: true }
};

export default {
  init() {
    return [{ value: '' }];
  },
  update(msg, model) {
    if (msg.type === 'paste') return [{ value: model.value + msg.text }];
    if (msg.type === 'key') {
      if (msg.key === 'Backspace')
        return [{ value: [...model.value].slice(0, -1).join('') }];
      if ([...msg.key].length === 1 && !msg.ctrl && !msg.alt)
        return [{ value: model.value + msg.key }];
    }
    return [model];
  },
  view(model) {
    return vstack(
      [
        text('Click here, then type or paste', { style: styles.hint }),
        text(model.value + '▌', { height: 7, style: styles.field }),
        text([...model.value].length + ' characters  ·  Unicode + paste', {
          style: styles.caption
        })
      ],
      { gap: 1, padding: 2 }
    );
  }
};`,
  layout: `import { text, vstack, hstack, zstack, fill } from 'milktea';

const ink = '#e6e4f0',
  muted = '#9293ad',
  mint = '#72e2be';
const panel = {
  background: '#242438',
  backgroundGradient: '#171b2b',
  foreground: ink,
  border: 'rounded',
  borderForeground: '#595579',
  padding: [1, 2, 1, 2]
};

const styles = {
  metric: color => ({ ...panel, foreground: color, bold: true }),
  navigation: active => ({
    ...panel,
    padding: 0,
    align: 'center',
    foreground: active ? mint : muted,
    borderForeground: active ? mint : '#424259'
  }),
  kicker: { foreground: muted, bold: true },
  launch: {
    ...panel,
    padding: 0,
    background: '#254d46',
    foreground: mint,
    align: 'center'
  },
  pipeline: { ...panel, borderForeground: mint },
  background: { background: '#171724', backgroundGradient: '#111927' },
  header: {
    foreground: ink,
    background: '#363052',
    backgroundGradient: '#232638',
    bold: true,
    padding: [1, 2, 1, 2]
  },
  footer: { foreground: muted }
};

const card = (title, value, color) =>
  text(title + '\\n' + value, { width: fill(), height: 5, style: styles.metric(color) });

export default {
  init() {
    return [{ page: 'Overview', launches: 128, progress: 68 }];
  },
  update(msg, model) {
    if (msg.type === 'click' && ['Overview', 'Activity', 'Settings'].includes(msg.id))
      return [{ ...model, page: msg.id }];
    if (
      (msg.type === 'click' && msg.id === 'launch') ||
      (msg.type === 'key' && msg.key === ' ')
    )
      return [
        { ...model, launches: model.launches + 1, progress: (model.progress + 7) % 101 }
      ];
    return [model];
  },
  view(model, screen) {
    const wide = screen.cols >= 64;
    const nav = ['Overview', 'Activity', 'Settings'].map(name =>
      text(' ' + name + ' ', {
        onClick: name,
        height: 3,
        style: styles.navigation(model.page === name)
      })
    );
    const sidebar = vstack(
      [
        text('WORKSPACE', { style: styles.kicker }),
        ...nav,
        text(' + Launch ', { onClick: 'launch', height: 3, style: styles.launch })
      ],
      { width: 16, height: fill(), gap: 1 }
    );
    const meter = '━'.repeat(Math.round(model.progress / 5)).padEnd(20, '─');
    const content = vstack(
      [
        hstack(
          [
            card('LAUNCHES', String(model.launches), mint),
            card('HEALTH', '99.9%', '#d9acf4')
          ],
          { height: 5, gap: 1 }
        ),
        text(
          model.page +
            '\\n\\nDeploy pipeline  ' +
            model.progress +
            '%\\n' +
            meter +
            '\\n\\n✓ Build artifacts ready\\n✓ WASM engine online\\n● Waiting for your next launch',
          { width: fill(), height: fill(), onClick: 'launch', style: styles.pipeline }
        )
      ],
      { width: fill(), height: fill(), gap: 1 }
    );
    return zstack([
      text('', { width: fill(), height: fill(), style: styles.background }),
      vstack(
        [
          text('MILKTEA  /  mission control', { height: 3, style: styles.header }),
          wide
            ? hstack([sidebar, content], { height: fill(), gap: 2 })
            : vstack([hstack(nav, { height: 3, gap: 1 }), content], {
                height: fill(),
                gap: 1
              }),
          text(
            (wide ? 'Sidebar layout' : 'Compact layout') +
              '  ·  click to launch  ·  Space',
            { height: 1, style: styles.footer }
          )
        ],
        { width: fill(), height: fill(), padding: 1, gap: 1 }
      )
    ]);
  }
};`,
  tweens: `import { text, vstack, zstack } from 'milktea';

const curves = ['linear', 'inOutCubic', 'outCubic', 'outBack'];
const colors = ['#86b8f9', '#72e2be', '#d9acf4', '#ffc98e'];
const styles = {
  header: {
    bold: true,
    foreground: '#f2e7ff',
    background: '#39304d',
    border: 'double',
    borderForeground: '#d9acf4',
    align: 'center'
  },
  label: i => ({ foreground: colors[i] }),
  track: { foreground: '#504b66', background: '#202030', verticalAlign: 'center' },
  marker: i => ({ foreground: '#171724', background: colors[i], bold: true }),
  caption: { foreground: '#aaa3bd' }
};

export default {
  init(screen) {
    const motions = curves.map(curve => screen.tween(0, 1400, curve));
    motions.forEach(t => t.update(1));
    return [{ motions, target: 1 }];
  },
  update(msg, model) {
    if (
      msg.type === 'click' ||
      (msg.type === 'key' && (msg.key === ' ' || msg.key === 'Enter'))
    ) {
      const target = 1 - model.target;
      model.motions.forEach(t => t.update(target));
      return [{ ...model, target }];
    }
    return [model];
  },
  view(model, screen) {
    const width = Math.max(12, screen.cols - 6),
      travel = Math.max(1, width - 4);
    return vstack(
      [
        text('EASING / native milktea tweens', { height: 3, style: styles.header }),
        ...model.motions.map((motion, i) =>
          vstack(
            [
              text(
                curves[i].padEnd(12) +
                  '  ' +
                  motion.value.toFixed(2) +
                  (motion.moving ? '  moving' : '  settled'),
                { style: styles.label(i) }
              ),
              zstack(
                [
                  text('·'.repeat(width), { width, height: 3, style: styles.track }),
                  text(' ◆ ', {
                    at: [motion.lerp(0, travel), 1],
                    width: 3,
                    height: 1,
                    style: styles.marker(i)
                  })
                ],
                { height: 3, onClick: 'toggle' }
              )
            ],
            { height: 4 }
          )
        ),
        text(
          'Click a track or press Space to reverse mid-flight.\\nNo tick loop: each tween requests its own frames.',
          { style: styles.caption }
        )
      ],
      { padding: 2, gap: 1 }
    );
  }
};`,
  composite: `import { text, zstack, fill } from 'milktea';

const panel = {
  foreground: '#f5edff',
  background: '#403154',
  backgroundGradient: '#23273d',
  border: 'rounded',
  borderForeground: '#d9acf4',
  cornerForeground: '#ffffff',
  padding: [1, 2, 1, 2]
};

const styles = {
  background: {
    foreground: '#797197',
    background: '#171c31',
    backgroundGradient: '#362742'
  },
  panel: { ...panel, background: '#234e59', borderForeground: '#72e2be' },
  glass: { background: '#724376', backgroundGradient: '#393660' },
  glassLabel: {
    foreground: '#f5edff',
    border: 'double',
    borderForeground: '#d9acf4',
    padding: [1, 2, 1, 2]
  },
  scrim: { background: '#080915' },
  modal: { ...panel, borderAnimation: 'race', borderSpeed: 1800, align: 'center' },
  header: {
    foreground: '#f4e8ff',
    background: '#423052',
    bold: true,
    border: 'rounded',
    borderForeground: '#d9acf4',
    align: 'center'
  },
  footer: { foreground: '#d8cbe6' },
  panelShadow: { x: 1, y: 1, opacity: 160, blur: 2 },
  glassShadow: { blur: 2, opacity: 130 },
  modalShadow: { x: 1, y: 1, blur: 2, opacity: 190 }
};

export default {
  init(screen) {
    const open = screen.tween(0, 520, 'outBack'),
      dim = screen.tween(0, 420, 'outCubic');
    open.update(1);
    dim.update(1);
    return [{ open, dim, visible: true, opacity: 170 }];
  },
  update(msg, model) {
    if (
      (msg.type === 'click' && msg.id === 'toggle') ||
      (msg.type === 'key' && (msg.key === 'm' || msg.key === ' '))
    ) {
      const visible = !model.visible;
      model.open.update(visible ? 1 : 0);
      model.dim.update(visible ? 1 : 0);
      return [{ ...model, visible }];
    }
    if (msg.type === 'key' && ['ArrowUp', 'ArrowDown'].includes(msg.key))
      return [
        {
          ...model,
          opacity: Math.max(
            40,
            Math.min(255, model.opacity + (msg.key === 'ArrowUp' ? 15 : -15))
          )
        }
      ];
    return [model];
  },
  view(model, screen) {
    const w = Math.max(12, screen.cols),
      h = Math.max(8, screen.rows);
    const field = Array.from({ length: h }, (_, y) =>
      Array.from({ length: w }, (_, x) =>
        (x * 17 + y * 23) % 47 === 0 ? '✦' : (x + y * 3) % 19 === 0 ? '·' : ' '
      ).join('')
    ).join('\\n');
    return zstack([
      text(field, { width: fill(), height: fill(), style: styles.background }),
      text('LAYER 01\\n\\nOpaque surface\\nNative drop shadow\\n\\nBehind the glass', {
        at: [2, 5],
        width: Math.min(27, w - 4),
        height: 11,
        shadow: styles.panelShadow,
        style: styles.panel
      }), // Alpha tints the surface while preserving the characters underneath.
      text('', {
        at: [Math.max(3, Math.floor(w / 2) - 5), 10],
        width: Math.min(30, w - 5),
        height: 10,
        alpha: model.opacity,
        shadow: styles.glassShadow,
        style: styles.glass
      }), // A separate label/border layer stays readable above the glass.
      text(
        'LAYER 02\\n\\nTranslucent glass\\nAlpha: ' +
          model.opacity +
          '/255\\n\\n↑ / ↓ changes opacity',
        {
          at: [Math.max(3, Math.floor(w / 2) - 5), 10],
          width: Math.min(30, w - 5),
          height: 10,
          style: styles.glassLabel
        }
      ),
      model.open.showing
        ? text('', {
            width: fill(),
            height: fill(),
            alpha: (model.dim.alpha * 0.6) | 0,
            onClick: 'toggle',
            style: styles.scrim
          })
        : null,
      model.open.showing
        ? text(
            'COMPOSITED MODAL\\n\\nSlide + fade, eased in WASM.\\nBackgrounds blend beneath me.\\n\\nClick or press M to dismiss.',
            {
              center: true,
              width: Math.min(42, w - 4),
              height: 11,
              onClick: 'toggle',
              transition: { tween: model.open, fromY: -7, fade: true },
              shadow: styles.modalShadow,
              style: styles.modal
            }
          )
        : null,
      text('ZSTACK / layered surfaces', {
        at: [2, 1],
        width: Math.max(1, w - 4),
        height: 3,
        onClick: 'toggle',
        style: styles.header
      }),
      text('M: modal  ·  ↑↓: glass opacity', {
        at: [2, Math.max(4, h - 2)],
        style: styles.footer
      })
    ]);
  }
};`,
  styles: `import { text, vstack, hstack, zstack, fill } from 'milktea';

const colors = ['#72e2be', '#d9acf4', '#86b8f9', '#ffc98e'];
const names = [
  'Rounded / rainbow',
  'Double / race',
  'Thick / pulse',
  'Corners / gradient'
];
const borders = ['rounded', 'double', 'thick', 'rounded'];
const animations = ['rainbow', 'race', 'pulse', 'none'];
const styles = {
  card: (i, palette) => ({
    foreground: colors[(i + palette) % colors.length],
    background: '#353049',
    backgroundGradient: '#172b32',
    bold: i === 0,
    italic: i === 3,
    border: borders[i],
    borderForeground: colors[(i + palette) % colors.length],
    cornerForeground: '#ffffff',
    borderAnimation: animations[i],
    borderSpeed: 2200,
    padding: [1, 2, 1, 2],
    align: i === 3 ? 'center' : 'left'
  }),
  background: { background: '#171927', backgroundGradient: '#2c2338' },
  header: {
    foreground: '#e8daff',
    background: '#302a46',
    bold: true,
    border: 'double',
    borderForeground: '#d9acf4',
    align: 'center'
  },
  caption: { foreground: '#b0a8c4' },
  cardShadow: { x: 1, y: 1, blur: 1, opacity: 140 }
};

export default {
  init() {
    return [{ palette: 0 }];
  },
  update(msg, model) {
    if (msg.type === 'click' || (msg.type === 'key' && msg.key === ' '))
      return [{ palette: (model.palette + 1) % colors.length }];
    return [model];
  },
  view(model, screen) {
    const cards = names.map((name, i) =>
      text(
        name + '\\n\\nNative glaze styles.\\nXray layout trees.\\nMilktea frame clock.',
        {
          width: fill(),
          height: 9,
          onClick: 'palette',
          shadow: styles.cardShadow,
          style: styles.card(i, model.palette)
        }
      )
    );
    return zstack([
      text('', { width: fill(), height: fill(), style: styles.background }),
      vstack(
        [
          text('GLAZE / surface studies', { height: 3, style: styles.header }),
          ...[0, 2].map(i => hstack(cards.slice(i, i + 2), { height: 9, gap: 2 })),
          text('Click any card or press Space to rotate the palette.', {
            style: styles.caption
          })
        ],
        { padding: 2, gap: 1 }
      )
    ]);
  }
};`,
};

export const presetNames = {
  "layout": "Adaptive dashboard",
  "tweens": "Tween easing lab",
  "composite": "Composited modal",
  "styles": "Glaze surface gallery",
  "counter": "Counter + clicks",
  "clock": "Animation + timers",
  "input": "Text input"
};
