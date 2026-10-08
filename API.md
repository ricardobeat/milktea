# milktea API reference

The complete public surface of the milktea libraries, grouped by module. For a
narrative introduction read `README.md`; for a step-by-step build read
`TUTORIAL.md`; for internals read `ARCHITECTURE.md`.

## Modules

| Module | Depends on | Role |
|---|---|---|
| `dye` | — | Color values, color spaces, blending, downsampling |
| `glaze` | `dye` | Styled strings: ANSI rendering, borders, joining, width |
| `xray` | `dye`, `glaze` | Cell grid, screen buffer, constraint solver, node tree |
| `milktea` | `dye`, `glaze`, `xray` | Runtime loop, input parsing, views, timers, tweens |
| `boba` | all of the above | Ready-made widgets (list, table, text input, …) |
| `tgp` | `milktea` | Kitty-graphics images |

Each has a `manifest.json` and can be consumed as a C3 library. `dye`, `glaze`
and `xray` also build for `windows-x64`; the modules that touch the tty
(`milktea`, `boba`, `tgp`) are macOS/Linux/FreeBSD only.

---

# Building an app

## The shape

An app is a struct implementing the `milktea::Model` interface. Methods are
attached with `@dynamic`; `init`, `update` and `view` are required and the four
lifecycle hooks are optional.

```c3
interface Model {
    fn Cmd init();
    fn Cmd update(Msg msg);
    fn View view();
    fn void on_mount()   @optional;
    fn void on_destroy() @optional;
    fn void on_focus()   @optional;
    fn void on_blur()    @optional;
}
```

`init` runs once before the first render. `update` receives one message at a
time and mutates the model in place. `view` runs after every `update` and must
be free of side effects. Both `init` and `update` return a `Cmd` — a
`fn Msg()` function pointer scheduling further work — or `null` for nothing.

```c3
module counter;

import milktea;
import glaze;

struct Counter { int value; }

fn milktea::Cmd Counter.init(Counter* self) @dynamic => null;

fn milktea::Cmd Counter.update(Counter* self, milktea::Msg msg) @dynamic {
    if (msg.kind != milktea::MsgKind.KEY) return null;
    switch (msg.key.code) {
        case milktea::KeyCode.UP:     self.value++;
        case milktea::KeyCode.DOWN:   self.value--;
        case milktea::KeyCode.CTRL_C: return milktea::quit();
        case milktea::KeyCode.RUNE:
            if (msg.key.rune == 'q') return milktea::quit();
        default:
    }
    return null;
}

fn milktea::View Counter.view(Counter* self) @dynamic {
    glaze::Style box = glaze::style()
        .foreground(glaze::color_hex("#00d7ff"))
        .padding(1, 3, 1, 3)
        .with_border(glaze::ROUNDED);
    return milktea::view(box.render(string::tformat("Counter: %d", self.value)));
}

fn int main() {
    Counter c = { };
    return milktea::@run(&c, { .alt_screen = true });
}
```

The model is used through a pointer for the whole run. Do not copy it after
`init` — components and glyphs may hold a borrow of it.

## Launch macros

| Macro | Returns | Use |
|---|---|---|
| `@run(&model, opts = {})` | `int` (0/1) | One-liner `main`; prints errors to stderr |
| `@run_program(&model, opts = {})` | `void?` | You handle the error yourself |
| `@program(&model, opts = {})` | `Program` | You want the `Program` before running it |
| `@test_program(&m, &dstring, w, h, opts = {})` | `Program` | Headless: captures output, fixed size |
| `@test_program_input(&m, &ds, w, h, input)` | `Program` | Same, preloaded with input bytes |

`opts` is an `Options` value; see below.

```c3
Counter c = { };
DString out = dstring::new();
milktea::Program p = milktea::@test_program(&c, &out, 80, 24);
p.send({ .kind = milktea::MsgKind.QUIT });
p.run()!!;
```

## Two ways to write `view`

**Strings** — build one with `glaze`, optionally solving rects with
`xray::layout`, and hand it to `view`. Simple and composable; joining
discards coordinates, so pieces land in argument order and cannot overlap.

**A node tree** — build with `milktea::root()`/`vstack()`/`hstack()` and return
`milktea::draw(root)`. The solver assigns every node a rect and each node paints
itself there, so nodes nest, overlap, take components, and report cursor
positions. Prefer this once a layout nests deeply or contains widgets.

## Build

Targets live in `project.json`. Each example is an executable that lists the
library dirs it needs plus its own:

```json
"examples/counter": {
  "type": "executable",
  "sources": ["milktea/**", "glaze/**", "dye/**", "examples/counter/**"],
  "c-sources": ["milktea/tty_winsize.c"],
  "opt": "Os",
  "strip-unused": true
}
```

`milktea/tty_winsize.c` is required by any target linking `milktea`. Add
`"xray/**"` for the node tree, `"boba/**"` for widgets, `"tgp/**"` for images.

| Command | Does |
|---|---|
| `just build` | Builds the `milktea` static-lib target |
| `just examples` | Builds every `examples/*` target |
| `just test` | `c3c test` — unit, integration and snapshot tests in `test/` |
| `just update-snapshots` | Re-records `snapshots/*/*.snap` |
| `just gen-targets` | Regenerates the `examples/*` targets in `project.json` |
| `just gen-width` | Regenerates the width tables in `xray/width.c3`, `glaze/style.c3` |
| `just format` | `c3fmt --in-place .` |

The `examples/*` entries in `project.json` are generated — change the
`OVERRIDES` table in `scripts/gen_targets.py` and re-run `just gen-targets`
rather than editing them by hand. All tests live in `test/`, keeping the
library directories test-free so they can be used as build sources directly.

---

# `milktea` — runtime

## Messages

```c3
struct Msg {
    MsgKind        kind;
    KeyMsg         key;
    WindowSizeMsg  window_size;
    MouseMsg       mouse;
    int            tag;
    void*          user;
    void*          owner;
    String         paste;
}
```

`MsgKind`: `NONE`, `KEY`, `WINDOW_SIZE`, `FOCUS`, `BLUR`, `MOUSE`, `QUIT`,
`TICK`, `USER`, `PASTE`. (`PASTE_START`/`PASTE_END` are internal and never
reach `update`.)

`msg.paste` is a view into a shared buffer, valid only for the duration of the
`update` call that delivers it. Copy it to keep it.

```c3
struct KeyMsg { KeyCode code; uint rune; bool ctrl, alt, shift; KeyAction action; }
struct MouseMsg { MouseButton button; MouseAction action; sz row, col;
                  bool shift, alt, ctrl; sz px, py; }
struct WindowSizeMsg { sz width, height; }
```

`KeyCode`: `NONE`, `RUNE`, `ENTER`, `BACKSPACE`, `ESC`, `TAB`, `UP`, `DOWN`,
`LEFT`, `RIGHT`, `HOME`, `END`, `DELETE`, `PAGE_UP`, `PAGE_DOWN`, `INSERT`,
`F1`–`F12`, `CTRL_C`. `rune` is a codepoint, so ASCII literals compare
directly (`k.rune == 'q'`).

`KeyAction`: `KEY_PRESS`, `KEY_REPEAT`, `KEY_RELEASE`. Only kitty-protocol
terminals with `View.set_report_key_events(true)` ever send the latter two.

`MouseAction`: `MOUSE_PRESS`, `MOUSE_RELEASE`, `MOUSE_MOTION`.
`MouseButton`: `MOUSE_LEFT`, `MOUSE_MIDDLE`, `MOUSE_RIGHT`, `MOUSE_NONE`,
`MOUSE_WHEEL_UP`, `MOUSE_WHEEL_DOWN`.

## Commands and timers

| Function | Does |
|---|---|
| `quit()` | `Cmd` that ends the program |
| `tick(ms = 16, callback = &tick_msg, owner = null)` | One-shot timer, delay from now |
| `every(ms = 16, callback = &tick_msg, owner = null)` | One-shot timer snapped to the next wall-clock multiple of `ms` |
| `cancel(owner)` | Cancels timers registered with that owner pointer |
| `frames_until(deadline_ms)` | Repaint every frame until `deadline_ms` on the `frame_ms()` clock |

Both timers are one-shot: re-arm from `update` to keep them firing. `tick` is
for animation, where only the gap between frames matters; `every` is for
clocks and countdowns, which must stay locked to absolute time despite update
and render cost.

`frames_until` is for something that keeps changing after `update` set it
going, such as a tween running to its end. The runtime keeps painting until the
deadline, and so does a drawn tree with a node that calls `.animate(fps)`. Both
feed one repaint timer, aligned to the `frame_ms()` clock. A repaint is not a
message: `view` runs again, but `update` does not.

A custom `Cmd` is just a function returning a `Msg`:

```c3
const int MY_MSG = 1;
fn milktea::Msg produce() => { .kind = milktea::MsgKind.USER, .tag = MY_MSG };
// ...
return milktea::tick(100, &produce);
```

## Views

A `View` carries content and per-frame terminal state. Whether it renders on the
alternate screen is a program option, not part of the view.

| Function | Content |
|---|---|
| `view(s)` | A string |
| `cell_view(cells, w, h)` | A caller-owned `xray::Cell` grid |
| `ScreenBuffer.view()` | The grid inside a `ScreenBuffer`, sized from the buffer |
| `draw(root)` | A node tree solved against the whole terminal |
| `draw_inline(root)` | The same tree, sized to its content height |

`View` builder methods (each returns the view):

```c3
.set_cursor(x, y)
.set_cursor_shape(x, y, CursorShape shape, bool blink)
.set_cursor_color(String color)
.set_mouse_cursor(String name)          // OSC 22 CSS cursor name
.set_mouse_mode(MouseMode mode)
.set_mouse_pixels(bool on)              // SGR-Pixels; fills MouseMsg.px/py
.set_report_key_events(bool on)         // kitty repeat/release events
.add_overlay(x, y, w, h, content, alpha = 0, ...)
.draw(xray::Rect rect, glaze::Style style, String content)  // cell views
```

`CursorShape` is `CURSOR_BLOCK`/`CURSOR_UNDERLINE`/`CURSOR_BAR`; `MouseMode` is
`MOUSE_MODE_NONE`/`MOUSE_MODE_CELL_MOTION`/`MOUSE_MODE_ALL_MOTION`. Up to
`MAX_OVERLAYS` (8) overlays per view.

`View.draw(rect, style, content)` paints styled content into a cell-backed
view's grid at `rect`, and returns the view so calls chain:

```c3
return self.canvas.view()
    .draw(header_rect, title_style, "My App")
    .draw(body_rect,   body_style,  body_text);
```

## Options

`Options` is program-level terminal state, fixed for the run and applied before
the first frame. Pass it as the second argument to any launch macro.

```c3
return milktea::@run(&model, { .alt_screen = true });
```

| Field | Effect |
|---|---|
| `alt_screen` | Runs on the alternate screen buffer, leaving scrollback untouched |

The alternate screen is entered before `init()` and exited on teardown,
including on a fatal signal, so `in_alt_screen()` is already true when `init()`
runs and screen-tied writes (kitty-graphics images) are safe from the first
frame.

Mouse mode, key-event reporting and pixel-resolution mouse reporting stay on
the `View`: each legitimately changes while a program runs, so a view declares
what it wants and the runtime applies the difference.

## Runtime accessors

Callable from `init`, `update`, `view` and `on_mount`; main thread only.

| Function | Returns |
|---|---|
| `screen_width()` / `screen_height()` | Terminal size, `80x24` outside a run |
| `cell_width_px()` / `cell_height_px()` | Pixels per cell |
| `cell_size_known()` | Whether the terminal answered the probe |
| `kitty_graphics_supported()` | Result of the `a=q` probe |
| `in_alt_screen()` | Whether the alternate screen is showing |
| `frame_ms()` | The frame clock: monotonic ms, fixed for the current callback |
| `time_ms()` | Monotonic milliseconds, live |
| `emit(String escape)` | Writes a raw escape through the renderer's tty path |

`frame_ms()` is stamped once before each `init`, `update`, `view` and `on_mount`
call, so everything one callback reads agrees on the time. Outside a running
program it reads the live clock.

The size is set before the first `view` and refreshed on resize, so there is no
startup gap — you do not need to mirror it in the model. Handle
`MsgKind.WINDOW_SIZE` only when a change requires work (reallocating a grid,
reflowing cached text).

Write escape sequences only through `emit`; `io::print` buffers separately and
interleaves badly with frame output. `in_alt_screen()` is `false` during
`init()` even for alt-screen programs, so defer screen-tied writes until it
turns true.

## Program

`Program` is the runtime object the macros build for you.

| Member | Does |
|---|---|
| `run()` | Runs the loop until quit; returns `void?` |
| `send(Msg)` | Injects a message |
| `send_recv(Msg* out)` | Injects and takes the reply |
| `with_window_size(&p, w, h)` | Fixes the size (tests) |
| `with_test_mode(&p, DString*)` | Captures output instead of writing to the tty |
| `with_input(&p, char[])` | Preloads input bytes (tests) |
| `with_clock(&p, ClockFn)` | Replaces the clock behind `frame_ms()` (tests) |

## Node tree

`milktea` re-exports the `xray` node API so a view needs one import:

```c3
alias Node, Rect, Content, ContentCursor, Shadow, InnerShadow, Constraint;
alias component = xray::content_node;
alias root, vstack, hstack, zstack, shadow, inner_shadow;
alias cells, fill, percent, min, max;
const START, CENTER, END, BETWEEN, AROUND, EVENLY;      // JustifyContent
const STRETCH, ALIGN_START, ALIGN_CENTER, ALIGN_END;    // AlignItems
fn Node* text(glaze::Style style, String s);
```

`root()` is the mandatory outermost node and is a zstack, so anything added to
it sits over the rest of the tree — that is how a modal works. `.add()`
returns the same node, so chained and statement forms are the same call and
conditional content is a plain `if`.

```c3
return milktea::draw(milktea::root()
    .add(milktea::vstack()
        .add(milktea::text(title_s, "  My App").height(milktea::cells(1)))
        .add(milktea::text(body_s, self.body).fill(1))
        .add(self.list.node())));
```

## Tweens and motion

A `Tween` carries a value to a target over a fixed duration and easing. It is
used the way a `Spring` is: `update()` aims it, `view()` reads it, and each
change asks the runtime for frames until it arrives, so the model runs no
timer for it.

```c3
Tween t = milktea::tween(0, 300, Easing.EASE_OUT_CUBIC); // resting at 0
t.update(target);    // run to target from wherever it is now (in update())
t.value();           // where it is now (in view())
t.moving();          // false once it arrives
t.settles_at();      // when it arrives, on the frame_ms() clock
t.showing();         // over 0..1: on its way in, in, or still on its way out
t.set(value);        // jump, no animation
t.lerp(a, b); t.lerpf(a, b); t.lerp_color(a, b); t.alpha(); // over 0..1
```

The plain calls read `frame_ms()`; `update_at`, `value_at`, `moving_at` and
`set_at` take the time explicitly. A run takes the full duration, except one
that turns back toward where the current run began, which takes only as long
as the tween has run so far. `Easing` is `LINEAR`, the `QUAD` and `CUBIC`
in/out/in-out family, and `EASE_OUT_BACK` — which deliberately overshoots past
the target before settling, so clamp anything that must stay in range.

## Springs

A `Spring` eases toward a target that can change at any time, keeping its
momentum through each change. It is solved exactly from the moment it was last
updated, so reading it never writes it: `update()` aims it, `view()` reads it.
Each change asks the runtime for frames until the spring settles, so the model
runs no timer for it.

```c3
Spring s = milktea::spring(0, milktea::spring_smooth());
s.update(target);    // aim from wherever it is now (in update())
s.value();           // where it is now (in view())
s.velocity();        // units per second
s.moving();          // false once settled
s.settles_at();      // when it comes to rest, on the frame_ms() clock
s.set(value, velocity = 0);  // jump, or fling with a velocity
```

The plain calls read `frame_ms()`; `update_at`, `value_at`, `velocity_at`,
`moving_at` and `set_at` take the time explicitly. `Spring.rest` (default
`SPRING_REST`, 0.01) is how close and slow counts as settled, in the value's
own units.

Parameters are `SpringParams { stiffness, damping }`, built with:

| Function | Spring |
|---|---|
| `spring_feel(duration_ms, bounce = 0)` | Takes about `duration_ms`; `bounce` 0 settles without overshoot, 0..1 wobbles, < 0 is sluggish |
| `spring_overshoot(duration_ms, overshoot)` | Swings `overshoot` (0.1 = 10%) past the target once |
| `spring_physics(stiffness, damping)` | Raw physics, unit mass |
| `spring_smooth()` / `spring_snappy()` / `spring_bouncy()` | Presets: bounce 0, 0.15, 0.3 at 500ms |

`Motion` animates a node's entry: `slide_down(rows)`, `slide_up(rows)`,
`slide_in(cols)`, `fade_in()`, and `.fade()` to add a fade to any of them. Apply
with `node.transition(motion, tween)`, which reads a tween running over 0..1 at
`frame_ms()`: 1 is at rest in place, 0 fully away.

## Other helpers

`Rect.render(style, content)` and `Style.render_in(rect, content)` fill a solved
rect. Both live in `milktea` — that is what lets `glaze` and `xray` stay
independent of each other.

## Terminal behavior handled for you

Bracketed paste (mode 2004) and the kitty keyboard protocol (progressive
enhancement flag 1) are enabled at startup and disabled on exit. The kitty
protocol makes a bare `ESC` arrive instantly rather than being held 50ms to
rule out an escape sequence; terminals that do not support it ignore the
push/pop, so no capability query is needed. Cell pixel size is probed with
`CSI 16 t` (iTerm2 `ReportCellSize` as fallback). Cleanup runs on normal
teardown and on fatal signals.

---

# `glaze` — styled strings

```c3
glaze::Style s = glaze::style()
    .foreground(glaze::color_hex("#ff6600"))
    .background(glaze::color_hex("#1a1a2e"))
    .with_bold(true).with_italic(true).with_underline(true)
    .padding(1, 2, 1, 2)
    .with_border(glaze::ROUNDED);
String out = s.render("Hello");
```

Styles are values: build, chain, then `render`.

| Group | Methods |
|---|---|
| Color | `.foreground(c)`, `.background(c)`, `.with_fg(hex)`, `.with_bg(hex)` |
| Attributes | `.with_bold`, `.with_italic`, `.with_underline` |
| Padding | `.pad(n)`, `.pad_x(n)`, `.pad_y(n)`, `.padding(t, r, b, l)` |
| Size | `.with_width(w)`, `.with_height(h)` |
| Alignment | `.align(h, v)`, `.align_horizontal(h)`, `.align_vertical(v)` |
| Border | `.with_border(b)`, `.border_fg(c)`, `.corner_fg(c)`, `.border_anim(a)`, `.border_anim_speed(ms)` |
| Render | `.render(s)`, `.render_content_only(s)`, `.measure_height(s, outer_w)` |

Borders: `NONE`, `NORMAL`, `SQUARE`, `ROUNDED`, `HIDDEN`, `THICK`, `DOUBLE`.
`Border.wrap(s)`, `.wrap_with_color(s, fg, bg, corner_fg)`, and
`.wrap_animated(w, h, anim, style, time_ms)` are available directly.

Colors (re-exported from `dye`): `color_none`, `color_ansi(code)`,
`color_256(idx)`, `color_hex("#rrggbb")`, `hsl(h,s,l)`, `hcl(h,c,l)`,
`blend_hsl/blend_hcl/blend_luv(a, b, t)`, `color_ramp(a, b, out[])`.

Joining and placement:

```c3
join_horizontal(left, right, gap)
join_horizontal_pos(Position pos, left, right, gap)
join_horizontal_arr(Position pos, String[] views, gap)
join_vertical(Position pos, top, bottom)
join_vertical_arr(Position pos, String[] views)
place(w, h, content)
place_pos(w, h, hpos, vpos, content)
place_horizontal(w, pos, content) / place_vertical(h, pos, content)
```

These understand embedded ANSI, so already-styled strings stack correctly.
`Position` is `TOP`, `CENTER`, `BOTTOM`, `LEFT`, `RIGHT` — the vertical and
horizontal names share one enum, and `CENTER` serves both axes.

Measurement and text: `string_width(s)` (ANSI-aware, wide- and zero-width
correct), `truncate_to_width(s, n)`, `utf8_sequence_len`, `utf8_width_at`,
`codepoint_width(cp)`, `clip_lines(s, max)`, `gradient_text(s, from, to, bold)`,
`progress_bar(...)`.

---

# `xray` — grid, layout, tree

## Rect and constraints

```c3
Rect r = xray::new_rect(x, y, w, h);
r.right(); r.bottom(); r.contains(px, py);
r.inset(left, top, right, bottom);
```

`Constraint` kinds: `cells(n)`, `fill(weight)`, `percent(p)`, `min(n)`,
`max(n)`, `fit(measure, ctx)`, `min_fit(n, ...)`, `max_fit(n, ...)`,
`range_fit(lo, hi, ...)`.

Raw splitters write into a caller-supplied array:

```c3
Constraint[3] cs = { xray::cells(1), xray::fill(1), xray::cells(1) };
Rect[3] out;
xray::layout_v(area, cs[..], out[..]);
xray::layout_h(area, cs[..], out[..]);
xray::layout_v_gap(area, cs[..], 1, out[..]);
xray::layout_h_gap(area, cs[..], 1, out[..]);
```

## `xray::layout` — ergonomic wrapper

```c3
xray::Rect top, body, bottom;
layout::vertical(layout::screen(w, h), {
    layout::slot(layout::cells(1), &top),
    layout::slot(layout::fill(1),  &body),
    layout::slot(layout::cells(1), &bottom),
}, { .gap = 1 });
```

`screen(w, h)` is `new_rect(0, 0, w, h)`. Constraint shorthands here are
`cells`, `fill`, `percent`, `min`, `max`. `horizontal` is the horizontal twin.

## Node tree

```c3
Node* n = xray::vstack();   // or hstack(), zstack(), root(), content_node(c)
n.add(child); n.add_content(c);
n.width(c); n.height(c); n.min_width(n); n.min_height(n); n.fill(weight);
n.with_justify(j); n.with_align(a); n.with_gap(g);
n.with_padding(top, right, bottom, left);
n.place(j, a); n.at(x, y); n.center(); n.offset(dx, dy);
n.shadow(s); n.with_inner_shadow(s); n.alpha(a); n.animate(fps = 60);
n.on_click(handler, ctx); n.on_click_outside(handler, ctx);
n.solve(area); n.rect(); n.child_rect(i); n.count();
```

`JustifyContent`: `JUSTIFY_START/CENTER/END/SPACE_BETWEEN/SPACE_AROUND/SPACE_EVENLY`.
`AlignItems`: `ALIGN_STRETCH/START/CENTER/END`. `MAX_NODE_CHILDREN` is 32.

Custom content implements `Content`:

```c3
interface Content {
    fn String render(Rect r);
    fn sz measure(sz width)        @optional;
    fn sz measure_width(sz height) @optional;
    fn ContentCursor cursor(Rect r)  @optional;
}
```

`cursor` lets content report where the caret belongs so the terminal cursor
follows the layout instead of a hand-counted row; build the return value with
`xray::place_cursor(text_rect, col, row, cursor_style)`. A caret scrolled out of
view reports no cursor rather than one clamped to an edge.

`Shadow` (`shadow(offset_x, offset_y, opacity, blur, half_blocks)`,
`.with_color(c)`) and `InnerShadow` (`inner_shadow(t, r, b, l, opacity)`) attach
to nodes for drop and inset shadows.

## ScreenBuffer

A persistent cell grid for precise x,y drawing.

```c3
ScreenBuffer* buf = xray::new_screen_buffer(w, h);
buf.clear(); buf.clear_range(r0, r1); buf.resize(w, h); buf.destroy();
buf.set_cell(col, row, cell); buf.cell_at(col, row); buf.overlay_char(...);
buf.set_string(col, row, text, style);
buf.render_ansi_string(x, y, ansi, style, max_row, max_col);
buf.fill_rect(rect, style); buf.draw_string_in_rect(rect, text, style);
Rect inner = buf.draw_border(rect, xray::ROUNDED, style);
buf.draw_gradient_border(rect, border, c1, c2);
buf.fill_gradient_v(rect, c1, c2); buf.fill_gradient_ellipse(...);
buf.blit(dst_x, dst_y, src, transparent);
buf.blit_ansi(dst_x, dst_y, w, h, ansi_text, transparent);
buf.render_ansi(); buf.render_frame(); buf.render_diff_str();
buf.paint(node_root, &scratch, now_ms);
```

Use `draw_border` when you need the inner `Rect` back for further layout; use
glaze's `.border()` when you just want a box around a string.

`Cell` is `new_cell(ch, width, style)` / `empty_cell()`; cell `Style` is
`default_style()` with `.set_fg`, `.set_bg`, `.with_bold`, `.set_dim`,
`.with_italic`, `.with_underline`, `.set_blink`, `.set_reverse`,
`.set_strikethrough`, `.to_sgr()`, `.diff_sgr(prev)`.

### TRANSPARENT

`xray::color_transparent()` is the compositing primitive. `set_cell` resolves a
transparent background by inheriting the existing cell's; for block characters
(U+2580–U+259F) whose background is `NONE`, the cell's foreground is used
instead, since block glyphs fill the cell with their foreground. `blit` skips
transparent cells entirely, and `diff_sgr` emits no SGR and triggers no reset
for a transparent channel.

## PixelBuffer

Half-block pixel rendering at twice the vertical resolution.

```c3
PixelBuffer* p = xray::new_pixel_buffer(w, h);
p.clear(c); p.set_pixel(col, row, c); p.get_pixel(col, row); p.blend_pixel(...);
p.fill_rect(rect, c, to, space); p.fill_ellipse(cx, cy, rx, ry, c, to, space);
p.draw_line(x0, y0, x1, y1, c, to, space);
p.to_cells(cells, grid_width, base_style);
p.destroy();
```

## Renderer

`new_renderer(w, h, write_fn)`, `.resize`, `.clear`, `.begin_frame`,
`.end_frame`, `.set_sync_supported(bool)`, `.set_position_mode(mode)`,
`.destroy()`. Emits synchronized-output markers (mode 2026) when supported.

---

# `dye` — color

```c3
Color c = dye::color_rgb(255, 100, 0);
dye::color_none(); dye::color_transparent(); dye::color_ansi(code);
dye::color_256(idx); dye::color_rgba(r, g, b, a); dye::color_hex("#ff6600");
c.is_none(); c.eq(other); c.effective_alpha(); c.blend_over(dst);
c.to_sgr_fg(); c.to_sgr_bg(); c.to_sgr_fg_profile(profile);
```

`ColorKind` is `NONE`, `ANSI`, `ANSI256`, `TRUECOLOR`, `TRANSPARENT`. `ColorProfile`
selects the output fidelity; `downsample_truecolor_to_256`,
`downsample_256_to_ansi` and `downsample_truecolor_to_ansi` convert explicitly,
and `palette_256(idx)` gives the RGB of a palette entry.

Spaces and blending: `hsl(h, s, l)`, `hcl(h, c, l)`, `blend_hsl`, `blend_hcl`,
`blend_luv` (all `(a, b, t)`), `blend_gradient(from, to, BlendSpace, t)`, and
`color_ramp(a, b, out[])` to fill an array. `BlendSpace` selects RGB, HSL, HCL
or LUV; LUV and HCL are the perceptual ones.

---

# `boba` — components

Every component implements `xray::Content` and exposes `.node()` to drop it
into a tree, plus `.view()` returning a plain string for string-built views.
Stateful ones take keys via `handle_key(milktea::KeyMsg) -> bool` (true when
consumed) and some take `update(Msg) -> Cmd`.

| Component | Constructor | Notable methods |
|---|---|---|
| `TextInput` | `new_text_input()` | `.with_placeholder`, `.with_password`, `.with_styles`, `.text()`, `.insert`, `.insert_rune`, `.insert_string`, `.backspace`, `.delete_char`, `.clear`, `.handle_key`, `.handle_paste`, `.cursor_col()` |
| `Textarea` | `new_textarea(w, h)` | `.with_placeholder`, `.text()`, `.insert`, `.backspace`, `.delete_char`, `.clear`, `.line_count()`, `.handle_key`, `.handle_paste`, `.update` |
| `List` | `new_list()` | `.add_item(title, desc)`, `.set_size`, `.handle_key`, `.visible_rows()`, `.view_with_pagination()` |
| `Table` | `new_table()` | `.add_column(title, w)`, `.add_row`/`add_row2`/`add_row3`, `.handle_key` |
| `Viewport` | `new_viewport(w, h)` | `.set_lines`, `.add_line`, `.scroll_up/down`, `.page_up/down`, `.scroll_to_top/bottom`, `.handle_key`, `.handle_mouse_msg`, `.get_selected_text()`, `.copy_to_clipboard()`, `.with_mouse_wheel()`, `.free()` |
| `FilePicker` | `new_file_picker(dir)` | `.load_dir`, `.handle_key` |
| `Spinner` | `new_spinner(kind = DOTS)` | `.with_color`, `.init_cmd()`, `.update`, `.advance`, `.current_frame()` |
| `Progress` | `new_progress(w, pct)` | `.set_percent`, `.incr_percent`, `.with_chars`, `.with_styles`, `.view_with_percent()` |
| `Timer` | `new_timer(seconds)` | `.init_cmd()`, `.update`, `.toggle`, `.pause`, `.resume`, `.reset`, `.remaining()` |
| `Stopwatch` | `new_stopwatch()` | `.init_cmd()`, `.update`, `.toggle`, `.pause`, `.resume`, `.reset` |
| `Pagination` | `new_pagination(per_page, total)` | `.with_kind`, `.next_page`, `.prev_page`, `.goto_page`, `.total_pages()`, `.page_start/end()` |
| `Help` | `new_help()` / `default_help()` | `.add_entry(key, desc)`, `.clear`, `.with_styles`, `.with_separator`, `.view_vertical()` |
| `KeyMap` | `new_keymap()` | `.bind(key, action)`, `.bind_mod(key, action, alt, ctrl)`, `.match(k) -> action`, `.has_binding` |
| `Toast` | `new_toast()` | `.show(msg)`, `.dismiss`, `.update`, `.visible()`, `.add_overlays(view)` |

`TextInput.handle_paste` inserts up to the first newline (single-line
semantics); `Textarea.handle_paste` inserts the text as given, newlines
included. `TextInput` and `Textarea` both implement `Content.cursor`, so in a
node tree the terminal cursor lands where the layout put the caret.

Components that own heap memory (notably `Viewport`) expect the model to free
them from `on_destroy`.

---

# `tgp` — kitty graphics

A *glyph* is an animated RGBA image, drawn procedurally or supplied as frames.
Register once, then render it inline in text or place it at absolute
coordinates.

```c3
struct Model {
    tgp::Session gfx;
    tgp::Glyph   spinner;
}

fn milktea::Cmd Model.init(&self) @dynamic {
    self.spinner = self.gfx.register({
        .draw = &draw_frame,        // fn void(char* rgba, int frame)
        .count = 8, .width = 32, .height = 64,
        .fps = 12, .fallback = "◌",
    })!!;
    return milktea::tick(80, &on_spin);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    self.gfx.tick();      // advance the clock, transmit, reconcile placements
    return milktea::tick(80, &on_spin);
}

fn milktea::View Model.view(&self) @dynamic {
    String inline_cell = self.spinner.render();
    tgp::InstId id     = self.spinner.place(0, 0);
    // ...
}
```

| API | Does |
|---|---|
| `new_session()` | Creates a `Session` |
| `Session.register(GlyphDef) -> Glyph?` | Registers a glyph (max 32) |
| `Session.release(g)` | Frees a glyph's images |
| `Session.tick()` | Advances the clock; transmits and reconciles |
| `Session.flush()` | Forces pending transmission |
| `Session.sync()` | Reconciles placements now |
| `Session.frame_of(g)` | Current frame index for a glyph |
| `Glyph.render()` | Placeholder string for inline use in text |
| `Glyph.place(col, row, z = 0, cols = 0, rows = 0) -> InstId` | Absolute placement |
| `Session.move(id, col, row)` / `.resize(id, cols, rows)` / `.remove(id)` | Manage placements |
| `supported()` | Probe result |
| `set_sink(fn)` / `emit(escape)` | Redirect or write raw graphics escapes |

`Z_UNDER_TEXT` and `Z_UNDER_BG` are the useful negative z values.

Design notes:

- **Capability is probed, never sniffed.** `a=q` runs at startup; where
  unsupported, `placeholder` returns the glyph's `fallback` and `place` is a
  no-op. No `TERM_PROGRAM` branching in your code.
- **Animation is declarative.** Glyphs own no timers; the frame index derives
  from a session clock advanced by `gfx.tick()` in `update`, so every glyph in a
  frame agrees and `view` stays side-effect free.
- **Glyphs render themselves.** Registration captures the session pointer, so
  `spinner.render()` needs no session at the call site — which is the other
  reason not to copy the model after `init`.
- **Transmission is lazy**, ordered after the alt screen is active.
- **Cleanup is automatic** on normal teardown and on fatal signals.

Placements work in kitty, WezTerm, Ghostty, Konsole, iTerm2 and Warp;
everything else shows the fallback. Cell pixel size answers on kitty, Ghostty,
WezTerm, foot, Konsole, mintty, Windows Terminal and xterm, and approximately
under tmux.

---

# Testing

Tests live in `test/`, outside the library directories, so `milktea/**` and the
rest stay test-free when listed as build sources. `just test` runs unit,
integration and snapshot tests. Snapshot tests render components and compare
against `snapshots/*/*.snap`; after an intentional rendering change run
`just update-snapshots` and review the diff.

Drive a model headlessly with the test macros — no tty required:

```c3
Model m = { };
DString out = dstring::new();
milktea::Program p = milktea::@test_program_input(&m, &out, 80, 24, "q");
p.run()!!;
// assert against out.str_view()
```
