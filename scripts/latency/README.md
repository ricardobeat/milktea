# latency

Tools for measuring input-to-frame latency in the GUI backend. Kept as the
starting point for a timeline inspector.

- `gui/backend.m`, "latency probe" section: `MILKTEA_DEBUG_LATENCY=1` times
  each mouse move through input → wait for frame → CPU → GPU done and prints
  percentiles to stderr (every 200 samples, on exit, on SIGTERM).
  `CAMetalDrawable.presentedTime` is always 0 for a windowed `CAMetalLayer`,
  so compositing and scan-out cannot be timed and are reported as an estimate.
- `mover.c`: posts real mouse-moved events (through the HID event tap) along
  the top row of a process's window, so a run needs no hands. It moves the
  real cursor and puts it back afterwards.

```
just latency            # dos-app-gui, 6 s at 120 Hz
```

Measured on a 60 Hz display (Nov 2026, dos-app-gui, 242 samples): event →
GPU done p50 15.2 ms, of which CPU 1.5 ms and GPU 0.5 ms; the rest is waiting
for the next frame.
