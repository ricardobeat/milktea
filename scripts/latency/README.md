# latency

Tools for measuring input-to-frame latency in the GUI backend. Kept as the
starting point for a timeline inspector.

- `gui/backend.m`, "latency probe" section: `MILKTEA_DEBUG_LATENCY=1` times
  each mouse move through input → wait for frame → CPU → GPU done and prints
  percentiles to stderr (every 200 samples, on exit, on SIGTERM).
  `CAMetalDrawable.presentedTime` is always 0 for a windowed `CAMetalLayer`,
  so compositing and scan-out cannot be timed and are reported as an estimate.
- `gui/backend.m`, "fake input" section: `MILKTEA_FAKE_INPUT` runs a script
  of mouse steps (`wait`, `move`, `sweep`, `down`, `up`, `click`, `quit`) as
  NSEvents posted to the app's own queue. They take the same AppKit → sokol →
  milktea path as real input, minus the WindowServer, and the real pointer
  never moves. The probe also counts how many frames redrew.
- `mover.c`: posts real mouse-moved events (through the HID event tap) along
  the top row of a process's window. It moves the real cursor; use it only to
  include the WindowServer leg.

```
just latency                # fake input over dos-app's menu bar, 4 s at 120 Hz
just latency y=200          # over the content, where nothing reacts to hover
just latency-real           # real events, moves the cursor
```

Measured on a 60 Hz display (Nov 2026, dos-app-gui, 242 samples): event →
GPU done p50 15.2 ms, of which CPU 1.5 ms and GPU 0.5 ms; the rest is waiting
for the next frame.

## Late latching

The GUI keeps handling events until 5 ms before the display link's
`targetTimestamp` and draws then, instead of right after the vsync.
`MILKTEA_LATE_LATCH_MS=<n>` sets another budget; 0 turns it off. Measured on the same setup (p50, "→target" is a move's age when its
frame is due on screen; "late" is GPU done after the target):

| n | newest move → target | oldest move → target | slack | late |
|---|---|---|---|---|
| 0 | 19.4 ms | 29.3 ms | 15.3 ms | 0 / 209 |
| 5 | 7.8 ms | 20.1 ms | 3.4 ms | 0 / 329 |
| 3 | 5.9 ms | 18.2 ms | 1.4 ms | 4 / 340 |

Finishing before the target is not proof the frame made its vsync: the
compositor's own deadline is earlier and cannot be timed from the app.
