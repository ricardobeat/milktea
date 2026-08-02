# bubble-tree — agent guide

Three modules. Each has one job.

## milktea — runtime loop

Elm-style TUI framework. Your model implements three methods:

```c3
fn Cmd  init();
fn Cmd  update(Msg msg);
fn View view();
```

`update` receives key/window/timer messages and returns a `Cmd` (e.g. `milktea::quit()`).  
`view` returns a `View` built from a cell grid or a plain string.  
Launch with `milktea::@run_program(&model)`.

### Timers — `tick()` and `every()`

Both schedule a one-shot timer that fires after the given delay, then deliver
a `TICK` message (or a custom callback's message) to the model. The model
must re-arm the timer from `update()` to keep it firing.

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

Builds ANSI-escaped strings. Chain calls, then call `.render(content)`:

```c3
glaze::new_style()
    .foreground(glaze::color_hex("#ff5fd7"))
    .set_bold(true)
    .render("hello")   // → ANSI string
```

Border presets: `rounded_border()`, `thick_border()`, `double_border()`.  
Measure display width with `glaze::string_width(s)`.

## xray — layout + cell grid

Two independent tools that compose.

**Layout** — splits a `Rect` into sub-rects using constraints:

```c3
Constraint[3] cs = { constraint_len(1), constraint_fill(1), constraint_len(1) };
Rect[3] out;
layout_v(area, cs[..], out[..]);        // vertical split
layout_h(area, cs[..], out[..]);        // horizontal split
layout_v_gap(area, cs[..], 1, out[..]); // vertical split with 1-row gap
layout_h_gap(area, cs[..], 1, out[..]); // horizontal split with 1-col gap
```

Constraint kinds: `constraint_len(n)` fixed, `constraint_fill(w)` weighted fill,
`constraint_percent(p)`, `constraint_min(n)`, `constraint_max(n)`,
`constraint_fit(measure, ctx)` sized by a measure callback.

Shrink a rect with `rect.inset(left, top, right, bottom)`.

**ScreenBuffer** — a persistent cell grid for precise x,y drawing:

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

Borders can also be applied directly in glaze without touching the cell grid — useful in the simple string-based path:

```c3
glaze::new_style()
    .border(glaze::rounded_border())
    .foreground(glaze::color_hex("#5f0087"))   // colours the border characters
    .render(content)                           // returns bordered ANSI string
```

Use `draw_border` on the `ScreenBuffer` when you need the inner `Rect` back for layout; use glaze's `.border()` when you just want a box around a string.

## Layout — stacks (`xray::layout`)

Split an area with `vstack`/`hstack`. Each slot pairs a constraint with an
output `Rect*`; results are written back in place:

```c3
import xray::layout;

Rect top, body, bottom;
layout::vstack(layout::screen(w, h), {
    layout::slot(layout::len(1),   &top),
    layout::slot(layout::fill(1),  &body),
    layout::slot(layout::len(1),   &bottom),
});

Rect sidebar, content;
layout::hstack(body, {
    layout::slot(layout::len(24), &sidebar),
    layout::slot(layout::fill(1), &content),
}, { .gap = 1 });   // 1-col gap
```

- `layout::screen(w, h)` is shorthand for `xray::new_rect(0, 0, w, h)`.
- Constraint aliases: `layout::len(n)`, `layout::fill(weight)`, `layout::percent(p)`,
  `layout::min(n)`, `layout::max(n)`.
- Gap goes in `layout::LayoutOptions{ .gap = n }` (zero value = no gap).
- Up to 64 slots per stack; extra slots are ignored.

For flexbox-style nested trees use `FlexNode`: `flex_row()` / `flex_col()` with
`.with_direction/.with_justify/.with_align/.with_gap/.with_padding/.with_main_size/
.with_cross_size` builders, then `.solve(area)` and read `.rect()` / `.child_rect(i)`.

For string-based row layout with auto cursor tracking, use `milktea::Layout`
(`new_layout()`, `.write()`, `.write_line()`, `.write_input_line()`, `.view()`).

## Returning a View

**Simple case** — build a string (with glaze), hand it to milktea:

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

All tests live in `test/` (kept out of the library dirs so `milktea/**` etc. stay test-free in build targets). Run `just test` (= `c3c test`). Snapshot tests compare against `snapshots/*/*.snap`; re-record with `just update-snapshots` (= `UPDATE_SNAPSHOTS=1 c3c test`) and review the diff.

## Build

The `examples/*` targets in project.json are generated — do not hand-edit them. Change the OVERRIDES table in `scripts/gen_targets.py`, then run `just gen-targets`.
