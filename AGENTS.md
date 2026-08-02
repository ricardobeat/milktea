# milktea — agent guide

Three modules. Each has one job.

- **milktea** — Elm-style runtime loop (model/update/view, timers, input)
- **glaze** — styling; builds ANSI-escaped strings
- **xray** — geometry: layout constraints + the cell grid

User-facing docs cover the API in depth — this file only adds what they don't:

| I need to… | Read |
|---|---|
| model/update/view/main skeleton | `README.md` → "The model", "init", "update", "view", "main" |
| styling, colors, borders | `README.md` → "Styling with glaze" |
| splitting the screen (`vstack`/`hstack`) | `README.md` → "Layout with xray::layout" |
| walkthrough | `TUTORIAL.md` (builds a pomodoro timer step by step) |
| internals (event loop, render pipeline) | `ARCHITECTURE.md` |

## milktea — runtime loop

`update` receives key/window/timer messages and returns a `Cmd` (e.g. `milktea::quit()`).
`view` returns a `View` built from a cell grid or a plain string.
Launch with `milktea::@run_program(&model)`.

### Timers — `tick()` vs `every()`

Both schedule a one-shot timer that fires after the given delay, then deliver a
`TICK` message (or a custom callback's message). The model must re-arm the timer
from `update()` to keep it firing. (README "Timed updates" covers the loop and
custom messages.)

```c3
milktea::tick(16);    // fires after 16ms — use for animations/frame pacing
milktea::every(1000); // fires at the next wall-clock second boundary — use for clocks
```

**`tick(ms)`** — delay is measured from when you call it. Successive calls
drift by `update+render` time. Best for animations where the only thing that
matters is the *gap* between frames.

**`every(ms)`** — deadline is snapped to the next multiple of `ms` relative
to wall-clock time, so successive calls stay locked to absolute time
regardless of drift. Best for clocks, countdowns, and periodic sync. A 1s
display will tick exactly on `:00` forever, even if `update()` takes a few ms.

## glaze — styling

Builds ANSI-escaped strings. Chain calls, then call `.render(content)`. Full
reference (colors, border presets, joining, width measurement) is in
README → "Styling with glaze".

## xray — layout + cell grid

Two independent tools that compose.

**Layout** — solves constraints against a `Rect`. The ergonomic wrapper
(`vstack`/`hstack`, `slot()`, `LayoutOptions.gap`, `layout::screen()`) is
documented in README → "Layout with xray::layout". The raw splitters and
constraint kinds, which README doesn't cover, live in `xray/layout.c3`:

```c3
Constraint[3] cs = { constraint_len(1), constraint_fill(1), constraint_len(1) };
Rect[3] out;
layout_v(area, cs[..], out[..]);        // vertical split
layout_h(area, cs[..], out[..]);        // horizontal split
layout_v_gap(area, cs[..], 1, out[..]); // with 1-row gap
```

Constraint kinds: `constraint_len(n)` fixed, `constraint_fill(w)` weighted fill,
`constraint_percent(p)`, `constraint_min(n)`, `constraint_max(n)`,
`constraint_fit(measure, ctx)` sized by a measure callback.

For flexbox-style nested trees use `FlexNode`: `flex_row()` / `flex_col()` with
`.with_direction/.with_justify/.with_align/.with_gap/.with_padding/.with_main_size/
.with_cross_size` builders, then `.solve(area)` and read `.rect()` / `.child_rect(i)`.

Shrink a rect with `rect.inset(left, top, right, bottom)`.

**ScreenBuffer** — a persistent cell grid for precise x,y drawing (not in README):

```c3
ScreenBuffer* canvas = xray::new_screen_buffer(w, h);
canvas.clear();
canvas.render_ansi_string(x, y, ansi_str, default_style(), max_row, max_col);
canvas.set_string(x, y, text, style);
canvas.draw_border(rect, rounded_border(), style);  // draws border, returns inner rect
```

**TRANSPARENT color** — compositing primitive for overlays:

```c3
xray::Style s = xray::default_style()
    .set_fg(sparkle_color)
    .set_bg(xray::color_transparent());
canvas.set_cell(col, row, xray::new_cell(ch, 1, s));
```

`set_cell` resolves TRANSPARENT bg by inheriting from the existing cell. For block
characters (`█▀▄▌▐░▒▓` U+2580–U+259F) whose bg is NONE, the cell's fg is used instead,
since block glyphs fill the cell with their foreground. In `blit`, TRANSPARENT cells are
skipped entirely (keep what's underneath). In `diff_sgr`, TRANSPARENT channels emit no SGR
and trigger no reset.

Use `draw_border` on the `ScreenBuffer` when you need the inner `Rect` back for layout; use
glaze's `.border()` (README → Borders) when you just want a box around a string.

## Returning a View

**Simple case** — build a string (with glaze), hand it to milktea. See README → "View types":

```c3
return milktea::new_alt_screen_view(glaze_string);   // alt screen (typical TUI)
return milktea::new_view(glaze_string);               // inline (no alt screen)
```

**Cell-grid case** — use this only when you need the xray `ScreenBuffer` for precise x,y placement:

```c3
return milktea::new_alt_cell_view(canvas.cells[0:w*h], w, h);
```

## Typical view() pattern (cell-grid)

```c3
// 1. clear canvas
self.canvas.clear();

// 2. split screen with layout constraints
Rect[2] zones;
layout_v(screen, { constraint_fill(1), constraint_len(1) }[..], zones[..]);

// 3. draw border, get inner rect
Rect inner = self.canvas.draw_border(zones[0], rounded_border(), border_sty);

// 4. paint content (render_ansi_string accepts glaze output directly)
self.canvas.render_ansi_string(inner.x, inner.y, glaze_string, ...);

// 5. return
return milktea::new_alt_cell_view(canvas.cells[0:w*h], w, h);
```

## Tests

All tests live in `test/` (kept out of the library dirs so `milktea/**` etc. stay
test-free in build targets). Run `just test` (= `c3c test`). Snapshot tests compare
against `snapshots/*/*.snap`; re-record with `just update-snapshots` and review the
diff. See README → "Testing".

## Build

The `examples/*` targets in project.json are generated — do not hand-edit them. Change the OVERRIDES table in `scripts/gen_targets.py`, then run `just gen-targets`.
