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
| `xray::layout` | `vstack` / `hstack` layout helpers |

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
        .bold(true)
        .padding(1, 3, 1, 3)
        .border(glaze::rounded_border());

    String content = string::tformat("Counter: %d\nUse ↑↓ to change, q to quit", self.value);
    return milktea::new_view(box.render(content));
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
    .bold(true)
    .italic(true)
    .padding(1, 2, 1, 2)
    .border(glaze::rounded_border());

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
glaze::rounded_border()         // ╭─╮╰─╯
glaze::normal_border()          // ┌─┐└─┘
glaze::double_border()          // ╔═╗╚═╝
glaze::thick_border()           // ┏━┓┗━┛
glaze::hidden_border()          // invisible (takes up space)
glaze::no_border()              // none
```

Set individual colors per side:

```c3
glaze::style()
    .border(glaze::rounded_border())
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

## Layout with xray::layout

For real apps with multiple panels, use `xray::layout`. It solves a list of size constraints against an available area and gives you back a `Rect` for each slot. Then render into those rects.

```c3
import xray;
import xray::layout;
```

### Constraints

```c3
layout::len(n)       // exactly n cells
layout::fill(weight) // fills remaining space (proportional to weight)
layout::percent(p)   // percentage of available space
layout::min(n)       // at least n cells
layout::max(n)       // at most n cells
```

### vstack / hstack

```c3
xray::Rect top, body, bottom;

layout::vstack(layout::screen(w, h), {
    layout::slot(layout::len(1),  &top),
    layout::slot(layout::fill(1), &body),
    layout::slot(layout::len(1),  &bottom),
});
```

`layout::screen(w, h)` is shorthand for `xray::new_rect(0, 0, w, h)`.

Add a gap between slots with the options struct:

```c3
layout::vstack(area, slots, { .gap = 1 });
```

### A full layout example

A terminal app with a title bar, sidebar, main content, and status bar:

```c3
fn milktea::View Model.view(&self) @dynamic {
    int w = self.width > 0 ? self.width : 80;
    int h = self.height > 0 ? self.height : 24;

    // Solve the layout
    xray::Rect title_r, main_r, status_r;
    layout::vstack(layout::screen(w, h), {
        layout::slot(layout::len(1),  &title_r),
        layout::slot(layout::fill(1), &main_r),
        layout::slot(layout::len(1),  &status_r),
    });

    xray::Rect sidebar_r, content_r;
    layout::hstack(main_r, {
        layout::slot(layout::len(24),  &sidebar_r),
        layout::slot(layout::fill(1),  &content_r),
    });

    // Render into each rect
    glaze::Style title_s  = glaze::style().foreground(glaze::color_hex("#00d7ff")).bold(true);
    glaze::Style side_s   = glaze::style().foreground(glaze::color_hex("#888888"));
    glaze::Style body_s   = glaze::style().foreground(glaze::color_hex("#ffffff"));
    glaze::Style status_s = glaze::style().foreground(glaze::color_hex("#555555"));

    String title   = title_r.render(title_s,   "  My App");
    String sidebar = sidebar_r.render(side_s,   "  Navigation\n  ──────────\n  > Home\n  Files\n  Settings");
    String content = content_r.render(body_s,   self.body);
    String status  = status_r.render(status_s,  "  Ready");

    // Stack into a single string and return
    String doc = glaze::join_vertical(glaze::Position.LEFT, title, glaze::join_horizontal(sidebar, content, 0));
    doc = glaze::join_vertical(glaze::Position.LEFT, doc, status);

    return milktea::new_alt_screen_view(doc);
}
```

### Rendering into rects

When you have a layout rect, prefer `rect.render(style, content)` over `style.render_in(rect, content)`. Both do the same thing — size the rendered block to fit the rect — but the rect-as-receiver form reflects the mental model better: you have a slot, and you're filling it with styled content.

```c3
// preferred
String title  = title_r.render(title_s,  "  My App");
String body   = body_r.render(body_s,    self.body);
String status = status_r.render(status_s, "  Ready");

// also available, style-first
String title  = title_s.render_in(title_r, "  My App");
```

Both methods are provided by `milktea` (not `glaze`), so they are only available when you `import milktea`. This keeps `glaze` and `xray` independent of each other — `glaze` handles styling, `xray` handles geometry, and `milktea` bridges them.

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

The runtime sends a `WINDOW_SIZE` message on startup and whenever the terminal is resized. Track it in your model:

```c3
struct Model { int width; int height; /* ... */ }

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
        self.width  = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    // ...
}
```

Then use it in `view`:

```c3
int w = self.width > 0 ? self.width : 80;
int h = self.height > 0 ? self.height : 24;
```

The fallback handles the brief moment before the first size message arrives.

---

## Mouse support

Enable mouse tracking by returning a view with mouse mode set:

```c3
return milktea::new_alt_screen_view(doc)
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

---

## View types

| Function | When to use |
|----------|-------------|
| `milktea::new_view(s)` | Inline output — appended below previous content |
| `milktea::new_alt_screen_view(s)` | Full-screen — uses the alternate buffer, hides cursor |

Most real apps want `new_alt_screen_view`. Use `new_view` for simple one-shot tools.

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
| `inputbox` | Layout with `vstack`, text input |
| `split-editors` | `hstack`, multiple panes, tab focus |
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
