# milktea

A terminal UI library for [C3](https://c3-lang.org), built on the Elm Architecture. Write your app as a data model, an update function, and a view — milktea handles the event loop, rendering, and terminal management.

```
╭──────────────────────────────────────╮
│   Counter: 3                         │
│   Use ^/v to change, q to quit       │
╰──────────────────────────────────────╯
```

## Getting started

Milktea is part of a small family of libraries:

| Module | Role |
|--------|------|
| `milktea` | Runtime, event loop, message types |
| `glaze` | Styles, colors, borders, text layout |
| `xray` | Cell grid, screen buffer, constraint solver |
| `tgp` | Kitty-graphics images (see "Images with tgp") |
| `xray::layout` | `vertical` / `horizontal` rect-splitting helpers |

You only need to import what you use. A simple app needs just `milktea` and `glaze`.

## The model

Every milktea program is a struct that implements three methods: `init`, `update`, and `view`. This is the [Elm Architecture](https://guide.elm-lang.org/architecture/) — also known as TEA.

```c3
module counter;

import milktea;
import glaze;
import std::io;

struct Counter {
    int value;
}
```

Your struct is your entire application state. Keep it flat and boring — no callbacks, no shared mutable state, no surprises.

## init

`init` runs once when the program starts. Return a `Cmd` to kick off background work (timers, ticks, async IO), or `null` to do nothing.

```c3
fn milktea::Cmd Counter.init(Counter* self) @dynamic {
    return null;
}
```

## update

`update` receives messages and mutates the model. Return a `Cmd` to schedule more work, or `null` to wait for the next message.

```c3
fn milktea::Cmd Counter.update(Counter* self, milktea::Msg msg) @dynamic {
    if (msg.kind != milktea::MsgKind.KEY) return null;

    switch (msg.key.code) {
        case milktea::KeyCode.UP:    self.value++;
        case milktea::KeyCode.DOWN:  self.value--;
        case milktea::KeyCode.CTRL_C:
        case milktea::KeyCode.RUNE:
            if (msg.key.rune == 'q') return milktea::quit();
        default:
    }
    return null;
}
```

Messages come in several kinds:

| `msg.kind` | What it carries |
|------------|----------------|
| `KEY` | `msg.key` — keycode, rune, modifiers |
| `MOUSE` | `msg.mouse` — action, position, button |
| `WINDOW_SIZE` | `msg.window_size` — width and height |
| `TICK` | timer fired |
| `USER` | your own message type via `msg.tag` |

## view

`view` turns the model into something to display. It runs after every `update`. Return a `View`.

```c3
fn milktea::View Counter.view(Counter* self) @dynamic {
    glaze::Style box = glaze::style()
        .foreground(glaze::color_hex("#00d7ff"))
        .with_bold(true)
        .padding(1, 3, 1, 3)
        .with_border(glaze::ROUNDED);

    String content = string::tformat("Counter: %d\nUse ↑↓ to change, q to quit", self.value);
    return milktea::view(box.render(content));
}
```

## main

Wire it up and run:

```c3
fn int main() {
    Counter c = { };
    return milktea::@run(&c);
}
```

That's the whole app. `@run` handles errors by printing to stderr and returning 1. If you need to do something after the program exits (print a message, free heap memory), write the boilerplate by hand instead.

---

## Styling with glaze

Glaze builds styled strings using ANSI codes. Styles are values — create them, chain methods, then call `.render(content)` to get a string.

```c3
glaze::Style s = glaze::style()
    .foreground(glaze::color_hex("#ff6600"))
    .background(glaze::color_hex("#1a1a2e"))
    .with_bold(true)
    .with_italic(true)
    .padding(1, 2, 1, 2)
    .with_border(glaze::ROUNDED);

String rendered = s.render("Hello, world");
```

### Colors

```c3
glaze::color_hex("#ff6600")     // truecolor from hex
glaze::color_256(196)           // 256-color palette
glaze::color_rgb(255, 100, 0)   // truecolor RGB

// Color space utilities
glaze::hsl(hue, sat, light)
glaze::hcl(hue, chroma, light)
glaze::blend_luv(a, b, 0.5)     // perceptual blend
glaze::blend_hcl(a, b, 0.5)     // perceptual + hue-aware blend
```

### Borders

```c3
glaze::ROUNDED         // ╭─╮╰─╯
glaze::NORMAL          // ┌─┐└─┘
glaze::DOUBLE          // ╔═╗╚═╝
glaze::THICK           // ┏━┓┗━┛
glaze::HIDDEN          // invisible (takes up space)
glaze::NONE              // none
```

Set individual colors per side:

```c3
glaze::style()
    .with_border(glaze::ROUNDED)
    .border_fg(glaze::color_hex("#3b82f6"))
    .border_bg(glaze::color_hex("#1e1e2e"))
```

### Joining strings

Glaze knows how to stack strings that might already contain ANSI codes:

```c3
// Place b below a, aligned left
String both = glaze::join_vertical(glaze::Position.LEFT, a, b);

// Place b to the right of a, aligned top
String both = glaze::join_horizontal(a, b, /*gap=*/0);

// Join an array
glaze::join_vertical_arr(glaze::Position.LEFT, pieces[..]);
```

---

## Layout

A view is a tree of nodes. The solver gives each node a rect, and each node
paints itself there — so pieces can overlap, nest, and size themselves.

```c3
fn milktea::View Model.view(&self) @dynamic {
    glaze::Style title_s  = { .fg = glaze::color_hex("#00d7ff"), .bold = true };
    glaze::Style body_s   = { .fg = glaze::color_hex("#ffffff") };
    glaze::Style status_s = { .fg = glaze::color_hex("#555555") };

    return milktea::draw(milktea::root()
        .add(milktea::vstack()
            .add(milktea::text(title_s, "  My App").height(milktea::cells(1)))
            .add(milktea::text(body_s, self.body).fill(1))
            .add(milktea::text(status_s, "  Ready").height(milktea::cells(1)))));
}
```

`milktea::root()` is the outermost node and is always present. Anything added
to it sits over the rest of the tree, which is how a modal works:

```c3
if (self.confirming_quit) {
    root.add(milktea::text(modal_s, "Really quit? (y/n)").center());
}
```

`add` returns the same node, so the chained and statement forms are the same
call and conditional content is a plain `if`.

### Containers

| | |
|---|---|
| `root()` | the mandatory outermost node; a zstack |
| `vstack()` | children stacked top to bottom |
| `hstack()` | children side by side |
| `zstack()` | children share the rect, later ones on top |

Containers take `.with_gap(n)`, `.with_padding(top, right, bottom, left)`,
`.with_justify(...)` and `.with_align(...)`.

### Sizing

`.width()` and `.height()` are both optional on every node, and take:

```c3
milktea::cells(n)     // exactly n cells
milktea::percent(p)   // percentage of the parent
milktea::at_least(n)  // at least n cells
milktea::at_most(n)   // at most n cells
```

`.fill(weight)` divides whatever space is left over among siblings.
`.center()` sizes a node to its content and puts it in the middle of its
parent. A node given neither fills.

### Components

Every boba component has a `node()` that puts it in a tree, sizing itself from
the rect it is given:

```c3
.add(self.list.node())
```

Anything else implementing `xray::Content` goes in with
`milktea::component(&thing)`. A text input also reports where the cursor belongs,
so the terminal cursor follows the layout rather than a hand-counted row.

### Inline mode

`milktea::draw()` uses the whole terminal. `milktea::draw_inline()` measures
the tree and claims only as many rows as it needs, leaving the scrollback
alone.

### Solving to rects instead

`xray::layout` solves the same constraints into plain `Rect`s, for building a
view as a string:

```c3
xray::Rect top, body, bottom;

layout::vertical(layout::screen(w, h), {
    layout::slot(xray::cells(1),  &top),
    layout::slot(xray::fill(1),   &body),
    layout::slot(xray::cells(1),  &bottom),
}, { .gap = 1 });

String doc = glaze::join_vertical(glaze::Position.LEFT,
    top.render(title_s, "  My App"),
    body.render(body_s, self.body));
```

`layout::screen(w, h)` is shorthand for `xray::new_rect(0, 0, w, h)`.

Use `rect.render(style, content)` to fill a solved rect; `style.render_in(rect,
content)` is the same thing style-first. Both live in `milktea`, which is what
keeps `glaze` and `xray` independent — `glaze` styles, `xray` measures, and
`milktea` joins them.

Note that joining strings discards the coordinates the solver computed, so
pieces land in argument order and cannot overlap. Reach for the tree when a
layout nests deeply, needs to overlap, or contains components.

---

## Timed updates

Use `milktea::tick(ms)` to schedule a message after a delay, then return another tick from `update` to keep it going:

```c3
fn milktea::Cmd SpinnerModel.init(SpinnerModel* self) @dynamic {
    return milktea::tick(80);
}

fn milktea::Cmd SpinnerModel.update(SpinnerModel* self, milktea::Msg msg) @dynamic {
    if (msg.kind == milktea::MsgKind.TICK) {
        self.frame++;
        return milktea::tick(80);  // schedule next tick
    }
    // ...
    return null;
}
```

To generate a custom message instead of a generic tick:

```c3
const int MY_MSG = 1;

fn milktea::Msg produce_msg() {
    return { .kind = milktea::MsgKind.USER, .tag = MY_MSG };
}

// In init:
return milktea::tick(100, &produce_msg);
```

---

## Window size

The runtime tracks the terminal size for you. Read it anywhere inside `init`, `update`, `view` or `on_mount`:

```c3
int w = milktea::screen_width();
int h = milktea::screen_height();
```

The size is set before your first `view` and refreshed on every resize, so there is no startup gap to guard against. Outside a running program the accessors return `80x24`. They read unsynchronized state, so call them from the main thread only.

You do **not** need to store the size in your model to read it back.

### Reacting to a resize

`WINDOW_SIZE` is still delivered, for models that must do work when the size *changes* — reallocate a cell grid, resize a canvas, reflow cached text:

```c3
fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
        self.grid.resize(msg.window_size.width, msg.window_size.height);
        return null;
    }
    // ...
}
```

If all you do in that handler is copy the size into two fields, delete it and call the accessors instead.

### Cell pixel size

Some rendering needs to know how many *pixels* one character cell occupies — images are the obvious case. Milktea probes this at startup (`CSI 16 t`, with iTerm2's `ReportCellSize` as a fallback) and keeps it current on resizes:

```c3
if (milktea::cell_size_known()) {
    int cw = milktea::cell_width_px();   // pixels per cell, horizontal
    int ch = milktea::cell_height_px();  // pixels per cell, vertical
}
```

`cell_size_known()` is false when the terminal never answered (alacritty, GNU Screen). Fall back to a `10x20` guess — flagged as a guess, so later answers can still correct it.

---

## Raw escape output

Terminal state that milktea does not manage (graphics, mode sets, private modes) should be written through `milktea::emit`, which shares the renderer's tty path and respects test-mode capture:

```c3
milktea::emit("\x1b_Ga=d,d=A,q=2\x1b\\"); // kitty graphics: delete all
```

Never mix in `io::print` for escape sequences — it buffers independently and interleaves badly with frame output.

Call `milktea::in_alt_screen()` to check whether the alternate screen is currently showing. For a program run with `.alt_screen = true` it is already `true` when `init()` runs, so screen-tied writes — graphics images die on a screen switch — are safe from the first frame.

---

## Images with tgp

The `tgp` module wraps the [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/). Register a *glyph* (an animated RGBA image, drawn procedurally or supplied as pre-rendered frames), then draw it inline in text or place it at absolute coordinates:

```c3
struct Model {
    tgp::Session gfx;
    tgp::Glyph   spinner;
}

fn milktea::Cmd Model.init(&self) @dynamic {
    self.spinner = self.gfx.register({
        .draw = &draw_frame,       // fn void(char* rgba, int frame)
        .count = 8, .width = 32, .height = 64,
        .fps = 12, .fallback = "◌",
    })!!;
    return milktea::tick(80, &on_spin);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    self.gfx.tick();  // advances the clock, transmits + reconciles placements
    // ...
}

fn milktea::View Model.view(&self) @dynamic {
    String cell = self.spinner.render();          // 1-cell image, in text
    tgp::InstId id = self.spinner.place(0, 0);    // absolute placement
    // ...
}
```

Design notes:

- **Capability is probed, never sniffed.** `a=q` runs during startup; on unsupported terminals `placeholder` returns the glyph's `fallback` string and `place` becomes a no-op. No `TERM_PROGRAM` branching in your code.
- **Animation is declarative.** Glyphs do not own timers; the frame index is derived from a session clock you advance with `gfx.tick()` in `update`. Every glyph drawn in one frame agrees on the frame index, and `view` stays side-effect free.
- **Glyphs render themselves.** A `Glyph` is bound to the session that registered it (registration captures the session pointer), so `spinner.render()` and `spinner.place(col, row)` need no session at the call site. The flip side of that borrow: don't copy the model after `init()` — milktea models are used via pointer, so this holds naturally.
- **Transmission is lazy.** Frames are sent on the first `tick`/`placeholder`/`place` after the alt screen is active — ordering against `1049h` is handled for you.
- **Cleanup is automatic.** Image ids are unique per run, and a blanket delete runs on normal teardown *and* fatal signals, so tiles never outlive the app.

Terminal support: placements work in kitty, WezTerm, Ghostty, Konsole, iTerm2 and Warp; everything else (foot, GNOME Terminal, Windows Terminal, tmux, alacritty) shows the fallback character. Cell pixel size answers on kitty, Ghostty, WezTerm, foot, Konsole, mintty, Windows Terminal and xterm; tmux answers approximately from its own geometry.

---

## Mouse support

Enable mouse tracking by returning a view with mouse mode set:

```c3
return milktea::view(doc)
    .set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);
```

Then handle mouse messages in `update`:

```c3
if (msg.kind == milktea::MsgKind.MOUSE) {
    if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION) {
        self.cursor_x = msg.mouse.col;
        self.cursor_y = msg.mouse.row;
    }
}
```

---

## Paste support

Bracketed paste mode (terminal mode 2004) is enabled automatically when your program starts. When the user pastes text, the terminal wraps it in `ESC[200~` … `ESC[201~` markers. milktea accumulates the raw bytes and delivers them as a single `MsgKind.PASTE` message — no matter how many characters, and regardless of embedded escape sequences.

```c3
if (msg.kind == milktea::MsgKind.PASTE) {
    // msg.paste is a String valid only during this update() call.
    // Copy it if you need it later.
    self.text.insert_string(msg.paste);
}
```

boba widgets accept paste via `handle_paste(String s)`:

- `TextInput.handle_paste(s)` — inserts up to the first newline (single-line semantics).
- `Textarea.handle_paste(s)` — inserts the text as-is, preserving newlines.

```c3
case milktea::MsgKind.PASTE:
    self.input.handle_paste(msg.paste);
```

## Keyboard protocol

milktea automatically pushes the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) (progressive enhancement flag 1, "disambiguate escape codes") when your program starts, and pops it on exit. On supporting terminals (kitty, ghostty, WezTerm, and others) this disambiguates previously-ambiguous key sequences — most notably, a bare `ESC` keypress arrives instantly as a distinct event instead of being held for 50ms to rule out an escape sequence. All other terminals silently ignore the push/pop sequences, so the protocol degrades gracefully with no capability query needed.

---

## View types

A view carries content; whether that content lands on the alternate screen is a
program option, not a property of the view.

| Function | Content |
|----------|---------|
| `milktea::view(s)` | A string, styled with glaze |
| `milktea::cell_view(cells, w, h)` | A cell grid you own |
| `buf.view()` | The grid inside an `xray::ScreenBuffer` |
| `milktea::draw(root)` | A solved node tree |

Run full-screen by passing the option to `@run`:

```c3
return milktea::@run(&model, { .alt_screen = true });
```

Most real apps want that. Leave it off for one-shot tools that should print
inline and leave the scrollback intact.

---

## Cleanup

If your model allocates heap memory, implement `on_destroy` and it will be called when the program exits:

```c3
fn void Model.on_destroy(&self) @dynamic {
    self.input.free();
    self.output.free();
}
```

---

## Examples

The `examples/` directory has runnable demos for most features:

| Example | What it shows |
|---------|---------------|
| `counter` | Minimal TEA loop, key handling |
| `spinner` | Timed ticks, custom messages |
| `timer` | `boba::Timer` component, pause/resume |
| `inputbox` | Layout with `layout::vertical`, text input |
| `split-editors` | `layout_h`, multiple panes, tab focus |
| `dos-app` | Complex nested layout, modals, menus |
| `color-swatches` | Color spaces, mouse motion |
| `doom-fire` | Fullscreen animation, cell-level rendering |
| `wolf3d` | 3D raycaster in a terminal |

Build and run any example:

```sh
cd examples/counter
c3c run
```

---

## Testing

All tests live in `test/` — unit and integration tests plus snapshot tests for each module. Run them with:

```sh
just test        # or: c3c test
```

Snapshot tests render components and compare the output against the `.snap` files in `snapshots/`. When you intentionally change rendering, re-record them and review the diff:

```sh
just update-snapshots    # or: UPDATE_SNAPSHOTS=1 c3c test
```

---

## Credits

milktea is built on the [Elm Architecture](https://guide.elm-lang.org/architecture/), and its shape for terminal applications follows the approach popularized by [Bubble Tea](https://github.com/charmbracelet/bubbletea) from [Charm](https://charm.sh). milktea is an independent implementation, written from scratch in C3, and is not affiliated with or endorsed by Charmbracelet, Inc.

## License

MIT — see [LICENSE](LICENSE).
