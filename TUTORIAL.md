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

### Step 1 — pick colors

The whole UI themes off a single accent that changes with the phase — warm
peach for focus, soft mint for breaks.

```c3
fn milktea::View Model.view(&self) @dynamic {
    bool focus = self.phase == Phase.FOCUS;

    glaze::Color accent = focus
        ? glaze::color_hex("#f3a26d")   // peach for focus
        : glaze::color_hex("#8fcab0");  // mint for break
    glaze::Color dim = glaze::color_hex("#7a6a58");
```

Nothing here reads the terminal size. milktea tracks it, and the layout solves
against it, so the model never stores or passes it around. A model only handles
`MsgKind.WINDOW_SIZE` when a resize means real work — reallocating a grid,
reflowing cached text.

### Step 2 — define styles

A `Style` is a plain value, so a literal says what something looks like without
a chain of calls. The title *inverts* the accent — dark text on an accent
background — and both boxes use a rounded border tinted to match.

```c3
    glaze::Style title_s = {
        .fg = glaze::color_hex("#4a3f35"), .bg = accent, .bold = true,
        .pad_left = 1, .pad_right = 1,
    };
    glaze::Style side_s = {
        .fg = dim, .border = glaze::ROUNDED, .border_color = dim,
        .pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
    };
    glaze::Style timer_s = {
        .fg = accent, .bold = true,
        .border = glaze::ROUNDED, .border_color = accent,
        .pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
        .align_h = glaze::Position.CENTER, .align_v = glaze::Position.CENTER,
    };
    glaze::Style status_s = { .fg = dim };
```

The builder form still works — `glaze::style().with_bold(true)` — and is handy
when a style is derived from another one.

### Step 3 — build the text content

Format the clock, and use glaze's built-in **progress bar** to show how far
through the phase we are:

```c3
    int mins = self.remaining / 60;
    int secs = self.remaining % 60;
    int total = phase_length(self.phase);
    int pct   = total > 0 ? 100 - (self.remaining * 100 / total) : 0;

    String bar = glaze::progress_bar(PROGRESS_CELLS, pct, "█", "░", accent, dim);

    String clock = string::tformat("%s\n\n  %02d:%02d  \n\n%s",
        focus ? "◆ FOCUS ◆" : "♦ BREAK ♦", mins, secs, bar);
    if (!self.running) clock = string::tformat("%s\n\n  -- paused --", clock);

    String side = string::tformat(
        "POMODORO\n────────\nsessions: %d\nphase:    %s\nstate:    %s",
        self.completed,
        focus ? "focus" : "break",
        self.running ? "running" : "paused");
```

### Step 4 — build the tree

Here is where the layout happens. Rather than computing positions, you describe
the shape and each node is given a rect to paint itself into.

Three horizontal bands — a one-line title, a body that takes whatever's left,
and a one-line status bar — with the body split into a fixed sidebar and a
timer panel:

```c3
    return milktea::draw(milktea::root()
        .add(milktea::vstack()
            .add(milktea::text(title_s, " 🍵 milktea pomodoro").height(milktea::cells(1)))
            .add(milktea::hstack()
                .fill(1)
                .with_gap(PANEL_GAP)
                .add(milktea::text(side_s, side).width(milktea::cells(SIDEBAR_COLS)))
                .add(milktea::text(timer_s, clock).fill(1)))
            .add(milktea::text(status_s,
                "  space pause · tab switch · r reset · q quit")
                .height(milktea::cells(1)))));
}
```

The constraint vocabulary:

| constraint | meaning |
|---|---|
| `cells(n)`   | exactly `n` cells |
| `fill(w)`    | share the leftover space, weighted by `w` |
| `percent(p)` | `p`% of the available space |
| `at_least(n)` / `at_most(n)` | clamp to a bound |

`with_gap(1)` puts a column between the two panels. Without it their borders
sit flush and the sidebar's right edge is overwritten — a gap is the layout's
job, not something to fake with padding.

Because everything is solved against the live terminal size, the UI reflows on
resize with no manual math.

`milktea::draw` puts the app on the terminal's alternate screen — the
full-window mode `vim` and `less` use. For a tool that shares the screen with
your scrollback, `milktea::draw_inline` sizes the block to its content
instead.

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
