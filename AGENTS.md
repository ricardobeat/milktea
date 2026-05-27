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
layout_v(area, cs[..], out[..]);   // vertical split
layout_h(area, cs[..], out[..]);   // horizontal split
```

Constraint kinds: `constraint_len(n)` fixed, `constraint_fill(w)` weighted fill,  
`constraint_percent(p)`, `constraint_min(n)`, `constraint_max(n)`.

Shrink a rect with `rect.inset(left, top, right, bottom)`.

**ScreenBuffer** — a persistent cell grid for precise x,y drawing:

```c3
ScreenBuffer* canvas = xray::new_screen_buffer(w, h);
canvas.clear();
canvas.render_ansi_string(x, y, ansi_str, default_style(), max_row, max_col);
canvas.set_string(x, y, text, style);
canvas.draw_border(rect, rounded_border(), style);  // draws border, returns inner rect
```

Borders can also be applied directly in glaze without touching the cell grid — useful in the simple string-based path:

```c3
glaze::new_style()
    .border(glaze::rounded_border())
    .foreground(glaze::color_hex("#5f0087"))   // colours the border characters
    .render(content)                           // returns bordered ANSI string
```

Use `draw_border` on the `ScreenBuffer` when you need the inner `Rect` back for layout; use glaze's `.border()` when you just want a box around a string.

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
