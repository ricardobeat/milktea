# Tutorial: building a Pomodoro timer

The [README](README.md) gets you to a counter. This tutorial goes a step
further and builds something you might actually leave running: a **Pomodoro
focus timer**. Along the way you'll touch most of milktea:

- **constraint layouts** — a title bar, a sidebar, a main panel, a status line
- **timers** — a once-a-second countdown locked to the wall clock
- **styling** — borders, colors, padding, alignment, a progress bar
- **state & keys** — pause, reset, and switching phases

The finished program lives in [`examples/pomodoro`](examples/pomodoro/pomodoro.c3).
Build and run it any time:

```sh
c3c run examples/pomodoro
```

```
╭────────────────────────────────────────────────────╮
│ 🍵 milktea pomodoro                                 │
├──────────────────────┬─────────────────────────────┤
│ ╭──────────────────╮ │ ╭─────────────────────────╮ │
│ │ POMODORO         │ │ │        ◆ FOCUS ◆        │ │
│ │ ────────         │ │ │                         │ │
│ │ sessions: 2      │ │ │         24:51           │ │
│ │ phase:    focus  │ │ │                         │ │
│ │ state:    running│ │ │  [████████░░░░░░░░░░░░]  │ │
│ ╰──────────────────╯ │ ╰─────────────────────────╯ │
├──────────────────────┴─────────────────────────────┤
│ space pause · tab switch · r reset · q quit         │
╰────────────────────────────────────────────────────╯
```

Every milktea program is the same three things: a **model** (your state), an
**update** function (react to events), and a **view** function (draw). Let's
build each in turn.

---

## 1. The model

Your model is your whole app. Keep it flat. Ours tracks which phase we're in,
how many seconds are left, whether the clock is running, how many focus
sessions we've finished, and the terminal size.

```c3
module pomodoro;

import milktea;
import glaze;
import xray::layout;
import std::io;

enum Phase : int {
    FOCUS,
    BREAK,
}

struct Model {
    Phase phase;
    int   remaining;   // seconds left in the current phase
    bool  running;
    int   completed;   // focus sessions finished
    int   width;
    int   height;
}

const int FOCUS_SECS = 25 * 60;
const int BREAK_SECS  = 5 * 60;

fn int phase_length(Phase p) {
    return p == Phase.FOCUS ? FOCUS_SECS : BREAK_SECS;
}
```

That's it — no callbacks, no shared mutable state. Everything the view needs to
draw a frame is right here in the struct.

---

## 2. init — starting the clock

`init` runs once at startup. We set our opening state and return a `Cmd` to kick
off the timer.

```c3
fn milktea::Cmd Model.init(&self) @dynamic {
    self.phase     = Phase.FOCUS;
    self.remaining = phase_length(self.phase);
    self.running   = true;
    return milktea::every(1000);
}
```

milktea gives you two timer commands, and the difference matters:

| | what it does | use for |
|---|---|---|
| `tick(ms)`  | fires `ms` after you call it | animations — you care about the *gap* between frames |
| `every(ms)` | fires on the next wall-clock multiple of `ms` | clocks & countdowns — stays locked to real time |

We want a countdown that ticks exactly on the second and never drifts, so we use
`every(1000)`. A timer is **one-shot**: it fires once, then it's up to us to
re-arm it from `update`.

---

## 3. update — reacting to the world

`update` is where every event lands: window resizes, timer ticks, and key
presses all arrive as a `Msg`. We `switch` on `msg.kind`.

```c3
fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
    switch (msg.kind) {
        case milktea::MsgKind.WINDOW_SIZE:
            self.width  = msg.window_size.width;
            self.height = msg.window_size.height;
            return null;

        case milktea::MsgKind.TICK:
            if (self.running && self.remaining > 0) {
                self.remaining--;
                if (self.remaining == 0) self.advance_phase();
            }
            return milktea::every(1000);   // re-arm for the next second

        case milktea::MsgKind.KEY:
            return self.handle_key(msg.key);

        default:
            return null;
    }
}
```

Three things worth noticing:

- **Window size** is sent on startup and on every resize. Stash it; the view
  uses it to lay things out.
- **The tick re-arms itself.** Each `TICK` decrements the clock and then returns
  `every(1000)` again. Stop returning it and the countdown stops — which is one
  way you could implement "pause," though here we just gate on `self.running`.
- **Returning `null`** means "nothing more to do, wait for the next event."

When the clock hits zero we roll over to the next phase:

```c3
fn void Model.advance_phase(&self) {
    if (self.phase == Phase.FOCUS) {
        self.completed++;
        self.phase = Phase.BREAK;
    } else {
        self.phase = Phase.FOCUS;
    }
    self.remaining = phase_length(self.phase);
}
```

### Keys

Pulling key handling into its own function keeps `update` readable. `space`
toggles running, `r` resets the phase, `tab` switches phase, and `q`/`esc`/`^C`
quit by returning `milktea::quit()`.

```c3
fn milktea::Cmd Model.handle_key(&self, milktea::KeyMsg k) {
    switch (k.code) {
        case milktea::KeyCode.CTRL_C:
        case milktea::KeyCode.ESC:
            return milktea::quit();
        case milktea::KeyCode.TAB:
            self.phase     = self.phase == Phase.FOCUS ? Phase.BREAK : Phase.FOCUS;
            self.remaining = phase_length(self.phase);
        case milktea::KeyCode.RUNE:
            switch (k.rune) {
                case 'q': return milktea::quit();
                case ' ': self.running = !self.running;
                case 'r': self.remaining = phase_length(self.phase);
                default:
            }
        default:
    }
    return null;
}
```

Printable characters arrive as `KeyCode.RUNE`, with the actual character in
`k.rune`. Special keys (arrows, tab, enter, escape) have their own `KeyCode`.

---

## 4. view — drawing the screen

This is the fun part, and where layout and styling come together. The view runs
after every update and returns a `View`.

### Step 1 — fall back to a sane size

Before the first `WINDOW_SIZE` arrives, width and height are `0`. Guard against
that:

```c3
fn milktea::View Model.view(&self) @dynamic {
    int w = self.width  > 0 ? self.width  : 80;
    int h = self.height > 0 ? self.height : 24;

    bool focus = self.phase == Phase.FOCUS;
```

### Step 2 — pick colors

We theme the whole UI off a single accent that changes with the phase — warm
peach for focus, soft mint for breaks.

```c3
    glaze::Color accent = focus
        ? glaze::color_hex("#f3a26d")   // peach for focus
        : glaze::color_hex("#8fcab0");  // mint for break
    glaze::Color dim = glaze::color_hex("#7a6a58");
```

### Step 3 — solve the layout

This is the heart of the tutorial. Instead of computing positions by hand, you
hand `xray::layout` a list of **constraints** and it fills in a `Rect` for each
slot.

First split the screen into three horizontal bands — a one-line title, a body
that fills whatever's left, and a one-line status bar:

```c3
    xray::Rect title_r, body_r, status_r;
    layout::vstack(layout::screen(w, h), {
        layout::slot(layout::len(1),  &title_r),
        layout::slot(layout::fill(1), &body_r),
        layout::slot(layout::len(1),  &status_r),
    });
```

Then split the body into two columns — a fixed-width sidebar and a timer panel
that takes the rest:

```c3
    xray::Rect side_r, timer_r;
    layout::hstack(body_r, {
        layout::slot(layout::len(22), &side_r),
        layout::slot(layout::fill(1), &timer_r),
    });
```

The constraint vocabulary:

| constraint | meaning |
|---|---|
| `len(n)`     | exactly `n` cells |
| `fill(w)`    | share the leftover space, weighted by `w` |
| `percent(p)` | `p`% of the available space |
| `min(n)` / `max(n)` | clamp to a bound |

Because everything is solved against `w` and `h`, the UI reflows correctly when
the terminal is resized — no manual math.

### Step 4 — define styles

Styles are plain values: build one, chain methods, reuse it. Note how the title
*inverts* the accent (dark text on an accent background), and both boxes use a
rounded border tinted to match.

```c3
    glaze::Style title_s = glaze::style()
        .foreground(glaze::color_hex("#4a3f35")).background(accent)
        .bold(true).padding(0, 1, 0, 1);

    glaze::Style side_s = glaze::style()
        .foreground(dim)
        .border(glaze::rounded_border()).border_fg(dim).padding(1, 2, 1, 2);

    glaze::Style timer_s = glaze::style()
        .foreground(accent).bold(true)
        .border(glaze::rounded_border()).border_fg(accent)
        .padding(1, 2, 1, 2)
        .align(glaze::Position.CENTER, glaze::Position.CENTER);

    glaze::Style status_s = glaze::style().foreground(dim);
```

### Step 5 — build the text content

Format the clock, and use glaze's built-in **progress bar** to show how far
through the phase we are:

```c3
    int mins  = self.remaining / 60;
    int secs  = self.remaining % 60;
    int total = phase_length(self.phase);
    int pct   = total > 0 ? 100 - (self.remaining * 100 / total) : 0;

    String bar = glaze::progress_bar(28, pct, "█", "░", accent, dim);

    String clock = string::tformat("%s\n\n  %02d:%02d  \n\n%s",
        focus ? "◆ FOCUS ◆" : "♦ BREAK ♦", mins, secs, bar);
    if (!self.running) clock = string::tformat("%s\n\n  -- paused --", clock);

    String side = string::tformat(
        "POMODORO\n────────\nsessions: %d\nphase:    %s\nstate:    %s",
        self.completed,
        focus ? "focus" : "break",
        self.running ? "running" : "paused");
```

### Step 6 — render into the rects and stack

Now the bridge between geometry and styling: `rect.render(style, content)` sizes
a styled block to fill its slot. Then we glue the pieces together with
`join_horizontal` and `join_vertical`, which understand strings that already
contain ANSI color codes.

```c3
    String title_v  = title_r.render(title_s,  " 🍵 milktea pomodoro");
    String side_v   = side_r.render(side_s,     side);
    String timer_v  = timer_r.render(timer_s,   clock);
    String status_v = status_r.render(status_s,
        "  space pause · tab switch · r reset · q quit");

    String body = glaze::join_horizontal(side_v, timer_v, 0);
    String doc  = glaze::join_vertical(glaze::Position.LEFT, title_v, body);
    doc = glaze::join_vertical(glaze::Position.LEFT, doc, status_v);

    return milktea::new_alt_screen_view(doc);
}
```

`new_alt_screen_view` puts the app on the terminal's alternate screen (the
full-window mode `vim` and `less` use) and hides the cursor. For a simple
scrolling tool you'd use `new_view` instead.

---

## 5. main

Wire it up and run. `@run` takes a pointer to your model, runs the loop, and
restores the terminal on exit.

```c3
fn int main() {
    Model m = { };
    milktea::@run(&m);
    return 0;
}
```

That's the whole program — one struct and four functions.

---

## Where to go next

- Drop the phase lengths to something like `5` and `3` seconds to watch the
  rollover and progress bar without waiting.
- Reach for **boba** components instead of hand-rolling: `boba::progress` for an
  animated bar, `boba::list` for a session history, `boba::help` for the hint
  line.
- Add a soft animated border with glaze's `border_anim` (a `PULSE` or `RAINBOW`)
  by returning `tick(16)` alongside your `every(1000)` to drive ~60fps frames.
- Read the [README](README.md) for the full API, and browse
  [`examples/`](examples/) — `dos-app` shows nested layouts and modals,
  `doom-fire` and `wolf3d` push cell-level rendering.

Happy hacking. ☕
