# milktea

A terminal UI library for [C3](https://c3-lang.org), built on the Elm Architecture. Write your app as a data model, an update function, and a view — milktea handles the event loop, rendering, and terminal management.

https://github.com/user-attachments/assets/e5172168-f86b-45c9-bc93-a06d6992c308

## Getting started

These modules provide:

| Module | Role |
|--------|------|
| `milktea` | Runtime, event loop, message types |
| `glaze` | Styles, colors, borders, text layout |
| `xray` | Cell grid, screen buffer, constraint solver |
| `tgp` | Kitty-graphics images (see "Images with tgp") |
| `xray::layout` | `vertical` / `horizontal` rect-splitting helpers |

You only need to import what you use. A simple app needs just `milktea` and `glaze`.

## The model

Every milktea program is a struct that implements `update` and `view`, plus an optional `init`. This is the [Elm Architecture](https://guide.elm-lang.org/architecture/) — also known as TEA.

```c3
module counter;

import milktea;
import glaze;
import std::io;

struct Counter {
    int value;
}
```

Store application state in the model.

## init

`init` is optional. If defined, it runs once when the program starts. Return a `Cmd` to kick off background work (timers, ticks, async IO), or `null` to do nothing.

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

`view` runs after every `update` and returns a node.

```c3
fn milktea::Node* Counter.view(Counter* self) @dynamic {
    glaze::Style box = glaze::style()
        .foreground(glaze::color_hex("#00d7ff"))
        .with_bold(true)
        .padding(1, 3, 1, 3)
        .with_border(glaze::ROUNDED);

    String content = string::tformat("Counter: %d\nUse ↑↓ to change, q to quit", self.value);
    return milktea::text(box.render(content));
}
```

A view can return any of these node types:

| Node | Content |
|------|---------|
| `milktea::text(s)` | A string, styled with glaze |
| `milktea::canvas(buf)` | The grid inside an `xray::ScreenBuffer` |
| `milktea::grid(cells, w, h)` | A cell grid you own |
| `milktea::vstack()`, `root()`, … | A tree of any of these |

`canvas` and `grid` take an optional `milktea::ContentCursor`, relative to the
grid's top left, to position the terminal cursor.

## main

```c3
fn int main() {
    Counter c = { };
    return milktea::@run(&c);
}
```

`@run` handles errors by printing to stderr and returning 1. If you need to do something after the program exits (print a message, free heap memory), write the boilerplate by hand instead.

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

`border_gradient` runs the border from `border_color` on its top row to the
gradient color on its bottom row:

```c3
glaze::Style s = {
    .border = glaze::ROUNDED,
    .border_color = glaze::color_hex("#ffc832"),
    .border_gradient = glaze::color_hex("#ff5a1e"),
};
```

### Joining strings

Join strings containing ANSI codes:

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
fn milktea::Node* Model.view(&self) @dynamic {
    glaze::Style title_s  = { .fg = glaze::color_hex("#00d7ff"), .bold = true };
    glaze::Style body_s   = { .fg = glaze::color_hex("#ffffff") };
    glaze::Style status_s = { .fg = glaze::color_hex("#555555") };

    return milktea::vstack()
        .add(milktea::text("  My App", title_s))
        .add(milktea::text(self.body, body_s).fill(1))
        .add(milktea::text("  Ready", status_s));
}
```

`milktea::root()` is a stack of layers: each child added to it sits over the
ones before, which is how a modal works:

```c3
if (self.confirming_quit) {
    root.add(milktea::text("Really quit? (y/n)", modal_s).center());
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

Any node takes `.style(s)`, which gives it a background, a border and padding
from a glaze style. The background covers the whole node, and the children go
inside the border and the padding:

```c3
glaze::Style panel = { .bg = glaze::color_hex("#1e1e2e"), .border = glaze::ROUNDED, .pad_left = 1 };
milktea::vstack().style(panel)
    .add(milktea::text("Title", title_s))
    .add(milktea::text(self.body, body_s));
```

A translucent background, such as `glaze::color_rgba(10, 14, 28, 178)`,
tints whatever is painted beneath the node and keeps its glyphs.

`text()` styles its own box the same way, and is a leaf: it cannot hold
children.

### Sizing

`.width()` and `.height()` are both optional on every node, and take:

```c3
milktea::cells(n)     // exactly n cells
milktea::percent(p)   // percentage of the parent
milktea::min(n)       // at least n cells
milktea::max(n)       // at most n cells
milktea::fit()        // as big as its content
```

A node given no size follows CSS flexbox. In a `vstack` or `hstack` it is as
big as its content along the stack and stretches across it; in a `zstack` or
`root` it fills the whole layer. `.fill(weight)` makes a node grow into the
space left over, divided among its siblings by weight, and `.fit()` is the
opposite: as big as its content on both axes. `.center()` sizes a node to its
content and puts it in the middle of its parent.

### GUI layout units

The GUI solves the same node tree in logical pixels. `cells(n)`, existing
padding, gaps, and pinned offsets still use text cells; xray converts them
using the current font metrics before solving. Terminal layout stays in cells.
`xray::pixels(n, terminal_cells)` gives a node a fixed GUI size independent of
the font; the optional terminal size defaults to zero cells.

Decoration padding is an additional GUI-only inset, in logical pixels:

```c3
bar.decorate(xray::linear(top_color, bottom_color)
    .padding(4, 4, 4, 4)); // top, right, bottom, left
```

Fixed cell sizes and fit-to-content sizes include this extra inset. A one-row
bar with 4px top and bottom padding is one text row plus 8px tall. Fill and
percentage sizes use their allocated outer box, with padding taken from inside.

Text measurement and rendering still use whole columns and rows. Their pixel
origins, decorations, and mouse targets do not snap to the cell grid. Click and
hover callbacks receive content-local cell coordinates; GUI padding before the
content can produce negative coordinates. Raw `MouseMsg` coordinates and
`screen_width()` / `screen_height()` remain in cells.

For manual geometry, `milktea::layout_area()` and solved `Node.rect()` use the
backend's layout units. `milktea::layout_metrics()` supplies `unit_w()` and
`unit_h()` for conversion. `Content.render`, `Content.cursor`, and custom fit
callbacks retain cell units. Standalone xray callers opt into pixels with
`node.solve(pixel_area, { .pixels = true, .cell_w = 10, .cell_h = 20 })`.

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

Set `.alt_screen = true` for a full-screen UI:

```c3
return milktea::@run(&model, { .alt_screen = true });
```

Omit it for inline output. The tree uses only as many rows as it needs,
leaving the scrollback intact.

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

Use `rect.render(style, content)` to fill a solved rect, or
`style.render_in(rect, content)`. Both methods live in `milktea`.

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

Read the current terminal dimensions from `init`, `update`, `view` or `on_mount`:

```c3
int w = milktea::screen_width();
int h = milktea::screen_height();
```

The dimensions are available before the first `view` and refreshed on every resize. Call these accessors from the main thread only. Outside a running program they return `80x24`.

### Reacting to a resize

Handle `WINDOW_SIZE` when a resize requires work, such as reallocating a grid or reflowing cached text:

```c3
fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
        self.grid.resize(msg.window_size.width, msg.window_size.height);
        return null;
    }
    // ...
}
```

### Cell pixel size

For image sizing, read the pixel dimensions of a character cell. Milktea probes them at startup (`CSI 16 t`, with iTerm2's `ReportCellSize` as a fallback) and updates them on resize:

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

Call `milktea::in_alt_screen()` to check whether the alternate screen is active. With `.alt_screen = true`, it is active before `init()` runs. Transmit graphics after entering it, since switching screens deletes images.

---

## Images with tgp

The `tgp` module wraps the [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/). Register a *glyph* (an animated RGBA image, drawn procedurally or supplied as pre-rendered frames), then draw it inline in text or place it at absolute coordinates.

Do not copy the model after `init()`: registered glyphs retain a pointer to
its session.

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

fn milktea::Node* Model.view(&self) @dynamic {
    String cell = self.spinner.render();          // 1-cell image, in text
    tgp::InstId id = self.spinner.place(0, 0);    // absolute placement
    // ...
}
```

Advance the session clock with `gfx.tick()` in `update`; glyphs do not own timers.

On unsupported terminals, `placeholder` returns the glyph's fallback string and
`place` does nothing. Images are deleted on normal teardown and fatal signals.

Terminal support: placements work in kitty, WezTerm, Ghostty, Konsole, iTerm2 and Warp; everything else (foot, GNOME Terminal, Windows Terminal, tmux, alacritty) shows the fallback character. Cell pixel size answers on kitty, Ghostty, WezTerm, foot, Konsole, mintty, Windows Terminal and xterm; tmux answers approximately from its own geometry.

---

## Mouse support

Turn mouse tracking on with a program option:

```c3
return milktea::@run(&model, { .mouse_mode = milktea::MouseMode.MOUSE_MODE_ALL_MOTION });
```

or while the program runs, from `update`, with
`milktea::set_mouse_mode(...)`. `set_mouse_cursor("crosshair")` changes the
pointer the same way, as does the `.mouse_cursor` option.

Then handle mouse messages in `update`:

```c3
if (msg.kind == milktea::MsgKind.MOUSE) {
    if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION) {
        self.cursor_x = msg.mouse.col;
        self.cursor_y = msg.mouse.row;
    }
}
```

### Hover and focus styles

A node's style can change while the pointer is over it, or while it has
keyboard focus, without any state in the model:

```c3
xray::hstack().style(item, hover: { .bg = th.accent }, focus: { .bg = th.ink, .fg = th.text })
```

Only colours apply, so nothing moves. Text that sets no `fg` of its own
takes the nearest ancestor's, so a hover or focus `fg` recolours a whole row.
Terminal hover needs `MOUSE_MODE_ALL_MOTION`; in a window it always works.

A node with an id takes keyboard focus with `.focusable()`. Tab and
Shift-Tab move focus in paint order, a click focuses the node under it, and
while a node with `.block_pointer()` is on screen focus stays inside it.
Read and set focus from `update` with `milktea::is_focused(ptr)`,
`is_focused_named("id")`, `focus(ptr)`, `focus_named("id")` and `blur()`.
Tab only reaches `update` when nothing on screen is focusable.

---

## Paste support

Pasted text arrives as a single `MsgKind.PASTE` message, including any embedded escape sequences. `msg.paste` is valid only during the current `update` call; copy it to keep it. Bracketed paste mode is enabled automatically.

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

On terminals supporting the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), a bare Escape keypress arrives immediately as a distinct event. Other terminals use legacy escape-sequence parsing, which waits 50ms to distinguish Escape from the start of a sequence.

milktea enables the protocol's disambiguation flag at startup and restores the
previous mode on exit.

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

## Running in a window

The same model runs in a native window instead of a terminal through
`milktea_gui` (macOS for now). It draws on the GPU: text from the system's
font rasteriser, and decorations (fills, gradients, borders, shadows) worked
out per pixel. List it next to milktea:

```json
"dependency-search-paths": ["path/to/milktea/lib"],
"dependencies": ["milktea", "milktea_gui"]
```

and call it from `main` in place of `milktea::@run`:

```c3
milktea_gui::run(&model, {
    .title = "my app",
    .cols = 80, .rows = 24,
    .cell_w = 10, .cell_h = 19, .font_size = 17,
});
```

`MILKTEA_FONT` picks the font (a file or a font name). `MILKTEA_GUI_SHOT=out.png`
draws one frame offscreen, with no window, and writes it out, which is how
`examples/dos-app-gui` and `scripts/gui-paint-test` are checked. See
`gui/gui.c3` for the rest of `GuiOptions`.

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
