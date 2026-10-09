# milktea in the browser

Build and open the example gallery:

```sh
just web-build
just web-serve
# http://localhost:8000/?example=counter
```

Requires C3 0.8.4 (tested) with its WASM linker and Python 3. No Emscripten,
Node packages, or bundler are needed to build or serve. Node is needed for
`just web-test`. Build one example with `just web-build paint`; the gallery
keeps all previously built examples in its dropdown.

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

`web/build/examples.json` lists the 42 portable examples and explains which
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

The bottom-right button enters real browser fullscreen. It fits the current
grid to the screen, preserving the running program. Press Escape or click the
button again to return to the inline size. Set `expandable="false"` to hide it.
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

## Smaller builds

The build strips metadata and exports that the browser does not use. Install
[Binaryen](https://github.com/WebAssembly/binaryen) for an additional size pass;
the script detects `wasm-opt` on PATH, or accepts an explicit location:

```sh
python3 scripts/build_web.py --wasm-opt /path/to/wasm-opt
# Or: WASM_OPT=/path/to/wasm-opt just web-build
```

With Binaryen 132, the 42 examples total 3.04 MB, down from 3.93 MB (22.7%).
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
