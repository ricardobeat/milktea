# milktea in the browser

Build and open the library showcase:

```sh
just web-build
just web-serve
# http://localhost:8000/
```

Requires C3 0.8.4 (tested) with its WASM linker and Python 3. No Emscripten,
Node packages, or bundler are needed to build or serve. Node is needed for
`just web-test`. Build one example with `just web-build paint`; the gallery
keeps all previously built examples in its dropdown.

The homepage introduces the C3 model/update/view loop, then walks through
inputbox, spinners, timer, splash, Doom fire, Doom fire tea, spotlight and
Avian Assault. The native C3 intro is highlighted to static HTML with
`inkfmt --lang c3 --html`; `intro.c3` holds the source excerpt. Demos load on
visibility, pause offscreen and have restart/fullscreen controls. The complete
gallery is at `gallery.html`, and old `/?example=…` links redirect there.

The renderer uses the same model/update/view API, glaze styles, xray layout,
cell grid, click targets, animation clock, and timer functions as the terminal.
`MILKTEA_WEB` selects a nonblocking runtime: JavaScript calls `mt_frame` from
`requestAnimationFrame`, paints cells with Canvas2D, and delivers keyboard,
pointer, wheel, focus, resize, and paste messages. Block, braille, sextant,
and diagonal block glyphs use canvas geometry; other glyphs use the browser's
monospace font fallback.
Mouse modes, pixel coordinates, key release/repeat reporting, and CSS pointer
shapes honor the program's settings. Tree click handlers also work without
raw mouse reporting.

`web/build/examples.json` lists the 43 portable examples and explains which
examples need native services or kitty graphics. The component viewer's
filesystem tab sees an empty directory. Kitty images, native file access,
QuickJS, HTTP services, and native image/video loaders are not implemented.
The canvas is a visual surface, with no accessible text tree or mobile text
input widget yet. Terminal cursor shapes and blinking are rendered, but
custom cursor colors currently use the default white inversion.

## Embed an example

Try the [inline demo](http://localhost:8000/inline.html) after `just web-serve`.
Serve `embed.mjs`, `engine.mjs`, `glyphs.mjs`, and the example's `.wasm` file
alongside your HTML. Import the component once, then add as many embeds as needed:

```html
<script type="module" src="./embed.mjs"></script>
<milktea-view src="./build/nanobots.wasm" cols="80" rows="24"
  style="width:400px;max-width:100%;height:240px"
  label="Nanobots animation"></milktea-view>
```

WASM downloads and compilation start when the embed enters the viewport.
Embeds with the same URL share the download and compiled module; each gets
independent memory and model state. Offscreen embeds pause rendering, and
removing an embed stops its program. Set `loading="eager"` to load immediately.
Call `element.restart()` to start a fresh instance using the cached module.

The bottom-right button enters real browser fullscreen. It expands the grid
to match the screen aspect ratio, with 20% more cells per fitted dimension.
The program receives a resize while retaining its model. Press Escape or click
the button again to restore the original inline grid. Set `expandable="false"` to hide it.
When placing the page inside an iframe, allow fullscreen on that iframe.

Choose either sizing mode:

- **Responsive grid:** omit `cols` and `rows`. CSS sets the viewport, while
  `font-size="12"` and `scale="1.5"` control text size and zoom. The model
  receives resize messages as its available cell count changes.
- **Fixed grid:** specify both `cols` and `rows`. The renderer fits that grid
  inside the CSS viewport, preserving its aspect ratio (`fit="contain"`).
  Alternatives are `cover` (crop), `stretch`, and `none` (manual zoom).

Attributes can change while the app runs. Text defaults to 16px monospace,
with 10×20px cells before scaling; `cell-width`, `cell-height`, `font`,
`foreground`, and `background` override those defaults. The canvas accounts
for display pixel density, CSS scaling, and fit margins when drawing and
mapping mouse coordinates. The element emits `ready`, `quit`, and `error`
events; `error.detail` holds the error. Its `engine` property exposes the
running `MilkteaCanvas` after `ready`. Style the button through
`milktea-view::part(expand-button)`.

For direct canvas control, import the lower-level engine instead:

```html
<canvas id="app" style="width:100%;height:480px"></canvas>
<script type="module">
  import {MilkteaCanvas} from './engine.mjs';
  const app = await MilkteaCanvas.load(document.querySelector('#app'),
    './build/paint.wasm', {cellWidth: 10, cellHeight: 20, fontSize: 16});
  // app.setOptions({fontSize: 12, scale: 1.5});
  // app.pause(); app.resume();
  // Call app.stop() when removing the canvas.
</script>
```

The browser runtime lives in `milktea-web/`. The build script uses the source
lists in generated `project.json` targets and adds the renderer dependencies
and a small exported bootstrap that calls the example's main function.
Unknown WASM imports fail explicitly when the module loads. Sine and cosine
use the browser math library, including the float variants, to keep particle
positions finite beyond the freestanding library's small-angle paths.

## JavaScript programs with a reusable WASM engine

`just web-engine` compiles only `build/milktea.wasm`, with no example code.
`just web-build` also builds this engine alongside the examples. The optimized
engine is about 82 KB (37 KB with gzip). Serve it with `bindings.mjs`,
`engine.mjs`, and `glyphs.mjs`. JavaScript owns your model; the WASM engine
runs milktea dispatch, timers, xray layout, glaze styling and click handling.

```html
<canvas id="app" style="width:400px;height:240px"></canvas>
<script type="module">
  import {mount, text, vstack} from './bindings.mjs';
  const app = await mount(document.querySelector('#app'), {
    init: () => [{count: 0}],
    update: (msg, model) => [{count: model.count +
      (msg.type === 'key' && msg.key === 'ArrowUp' ? 1 : 0)}],
    view: model => vstack([
      text(`Count: ${model.count}`, {style: {foreground: '#e4b2d6', bold: true}}),
      text('Press ↑')
    ], {gap: 1, padding: 2})
  });
  // app.model reads current state; app.send(message) queues a custom message.
  // app.engine exposes canvas controls; app.stop() releases the program.
</script>
```

`init(context)` and `update(message, model, context)` return `[model, command]`;
the command is optional, and may be an array of commands. Exported commands
are `tick(ms)`, `send(message)`, and `quit()`. Timers are native one-shot
milktea timers: return another `tick` from update to keep an animation running.
`context` exposes `cols`, `rows`, `time` (frame milliseconds) and the helpers.
`destroy(model)` is an optional cleanup callback. Callbacks are synchronous.

Messages include `key` (`key`, `code`, `rune`, modifiers, `action`), `resize`
(`cols`, `rows`), `mouse` (`button`, `action`, cell/pixel coordinates and
modifiers), `paste` (`text`), `focus`, `blur`, and `tick`. A node with
`onClick: 'increment'` delivers `{type: 'click', id: 'increment'}` through native
hit testing. `send` delivers the custom message as supplied.

Views may return strings or descriptors from `text(value, options)`,
`vstack(children, options)`, `hstack(children, options)`, or `zstack(children, options)`.
`stack`, `column`, and `row` remain aliases for saved programs.
Node options include `width`, `height`, `fill`, `gap`, `padding`, `center` and
`onClick`. Dimensions accept numbers or constraints from `cells(n)`, `fill(weight)`,
`percent(n)` and `fit()`. Use `justify` (`start`, `center`, `end`, `between`,
`around`, `evenly`) and `align` (`stretch`, `start`, `center`, `end`) on containers.
Layers support `at: [x, y]`, `offset: [dx, dy]`, `alpha: 0..255`, `animate: fps`,
and `shadow: {x, y, opacity, blur, color, halfBlocks}`. Alpha blends surface
colors while preserving the characters beneath; add a separate text layer
to keep a translucent panel's label readable.

Text's glaze `style` supports `foreground`, `background`, `backgroundGradient`,
`borderForeground` and `cornerForeground` (`#rrggbb` or RGB integers), `bold`,
`italic`, `underline`, `padding` (number or `[top, right, bottom, left]`),
`align` (`left`, `center`, `right`), `verticalAlign` (`top`, `center`, `bottom`),
and `border` (`rounded`, `normal`, `double`, `thick`). `borderAnimation` can be
`pulse`, `rainbow`, or `race`, with `borderSpeed` in milliseconds per cycle;
animated borders request their own repaint frames.

Create native tweens in init with `context.tween(value, durationMs, easing)`.
Curves include `linear`, `inQuad`, `outQuad`, `inOutQuad`, `inCubic`, `outCubic`,
`inOutCubic`, and `outBack`. A tween exposes `value`, `target`, `moving`, `showing`,
`alpha`, `update(target)`, `set(value)`, and `lerp(from, to)`. Updating a tween
requests native repaint frames without a JS timer loop. Tweens belong to their
mount and are released on stop. Apply a slide/fade with a node option:

```js
transition: {tween: model.open, fromY: -6, fromX: 0, fade: true}
```

These bindings cover text and layout trees; native C3
examples remain the route to APIs such as boba widgets and custom cell grids.
View nodes are rebuilt each frame; keep model state in JavaScript rather than
retaining native node handles. Each mount has its own WASM memory and model.

`mount` accepts the same viewport/text options as `MilkteaCanvas`, plus
`wasmURL` to relocate the engine. Compiled WASM is cached across mounts.

### Live editor

After `just web-engine` and `just web-serve`, open
<http://localhost:8000/editor.html>. Edit the JavaScript module on the left;
the preview runs on the right. Import helpers from `'milktea'` using the
editor's import map, and export your program as the default export.

Edits run after a short debounce, or press Ctrl/⌘ Enter or Run. Each run
mounts a fresh model in the same reusable engine. Presets demonstrate
an adaptive dashboard, native tween easing and reversal, a sliding/fading
composited modal, glaze gradients and animated borders, plus counter/click
handling, native timers and text input. Syntax errors show
below the preview and retain the last running program. Reset restores the
selected preset. Code is saved to localStorage in this browser.
Each preset keeps its glaze styles in a named `const styles = {}` table;
small style factories handle state-dependent colors so views focus on layout.

Syntax highlighting uses [Highlight.js](https://github.com/highlightjs/highlight.js)
11.12.0, bundled with only the core and JavaScript grammar (28 KB raw, 11 KB
gzipped). The bundle and BSD license live in `vendor/`. The textarea overlay
stays aligned while scrolling, and the editor works without a CDN or npm at
runtime. To rebuild the vendored bundle, install the maintenance tools outside
the repository and run:

```sh
npm install --prefix /tmp/milktea-highlight-build highlight.js@11.12.0 esbuild@0.28.2
MILKTEA_HIGHLIGHT_PACKAGE=/tmp/milktea-highlight-build/package.json node scripts/build_highlighter.mjs
```

The editor executes your JavaScript in a preview iframe; it does not compile
C3 in the browser. A canvas preview must be clicked to focus keyboard input.
Run `node web/test/editor-browser.mjs` for the live editor browser checks.
Set `MILKTEA_TEST_BROWSER=webkit` to run those checks with WebKit.
`node web/test/showcase-browser.mjs` exercises the layout, animation and style presets.

## Smaller builds

The build strips metadata and exports that the browser does not use. Install
[Binaryen](https://github.com/WebAssembly/binaryen) for an additional size pass;
the script detects `wasm-opt` on PATH, or accepts an explicit location:

```sh
python3 scripts/build_web.py --wasm-opt /path/to/wasm-opt
# Or: WASM_OPT=/path/to/wasm-opt just web-build
```

With Binaryen 132, the original 42 examples total 3.04 MB, down from 3.93 MB (22.7%).
Counter is 70 KB and nanobots is 96 KB. The build also writes deterministic
`.wasm.gz` files and records raw/compressed sizes in `build/examples.json`.
Configure your production server to serve those precompressed files with
`Content-Encoding: gzip` for `.wasm` requests. The Python demo server serves
the raw WASM files; no decompressor is needed in the engine.

## Verification

Run `just web-test` for WASM startup, input, animation, glyph, and viewport
checks. Optional browser checks cover lazy downloads, independent instances,
scaled mouse input, pixel density, resizing, fullscreen, and cleanup. With
Playwright and its Chromium browser installed, start `just web-serve`, then
run `node web/test/browser.mjs`. `MILKTEA_TEST_URL` overrides the server URL;
`PLAYWRIGHT_PACKAGE` can point at an external package.json containing Playwright.
`node web/test/site-browser.mjs` checks the showcase's lazy loading, interactive
controls, demo order, mobile layout and gallery redirects in Chromium or WebKit.

## Model lifetime

Unlike terminal `Program.run`, the browser version returns after startup.
The `@program`, `@run_program`, and `@run` macros copy the model to the heap
because browser callbacks outlive `main`'s stack. The copy is shallow: any
referenced storage must also outlive those callbacks. Use `on_destroy` to
release model resources. Code following `run` in `main` executes immediately,
so move cleanup and final model reporting into lifecycle hooks for web builds.
Direct `Program` construction must supply a heap model owned by the runtime.
One WASM instance hosts one program; restarting loads a fresh instance.

The host reacquires WASM memory after updates because allocations can grow
linear memory. `mt_frame` returns 2 for a new grid, 1 for an idle live program,
and 0 after quit. Events and model callbacks use scoped temporary allocations;
the painted grid survives in the program's persistent ScreenBuffer. `tick`
and `every` retain their one-shot semantics. Wall-aligned timers use the full
JavaScript wall clock, avoiding wasm32 integer overflow for epoch milliseconds.

Showcase demos start in Preview. Code tabs load highlighted C3 source on demand.
Regenerate those panels after editing an example:

```sh
python3 scripts/highlight_web_examples.py
```

If inkfmt needs its grammar directory, set `INKFMT_DIR` to that directory.
