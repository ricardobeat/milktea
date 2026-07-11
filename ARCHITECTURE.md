# Architecture

Internals of milktea: how the modules fit together, how a frame gets from a
model's `view()` to the terminal, and the conventions the code relies on.
For usage, see `README.md`. For a quick API map, see `AGENTS.md`.

## Module map

Five modules, one-way dependency chain:

```
xray    — cell grid, diff renderer, layout solver, color        (no internal deps)
glaze   — styles, borders, gradients → ANSI strings              (no internal deps)
milktea — event loop, input parsing, TTY control, View/Cmd       (depends on xray)
boba    — widget collection (list, textinput, viewport, ...)     (depends on milktea, glaze, xray)
taro    — QuickJS bridge (JS models drive milktea from taro.js)  (depends on milktea, glaze, xray, boba)
```

`xray` and `glaze` don't depend on each other or on milktea and are usable
standalone. `glaze` produces ANSI-styled strings; `xray` owns the persistent
cell grid and the diffing renderer. `milktea` composites the two: a `View`
carries either a plain string (parsed by xray's ANSI parser) or a direct
`Cell[]` grid. Package manifests (`*/manifest.json`) encode this same order.

`taro/taro.c` and `vendor/quickjs/*.c` are C sources pulled in via
`c-sources`; `taro/taro.c3` declares `extern fn` bindings into that C layer.
`milktea/tty_winsize.c` is the only other C dependency, providing
`ioctl(TIOCGWINSZ)` portably.

## Core types (milktea/milktea.c3)

- `Model` — interface apps implement: `init() -> Cmd`, `update(Msg) -> Cmd`,
  `view() -> View`, plus optional lifecycle hooks `on_mount`, `on_destroy`,
  `on_focus`, `on_blur` (`@optional`, checked with `&self.model.on_x` before
  calling).
- `Msg` — tagged union (`MsgKind`: NONE, KEY, WINDOW_SIZE, FOCUS, BLUR,
  MOUSE, QUIT, TICK, USER) carrying a `KeyMsg`, `WindowSizeMsg`, or
  `MouseMsg` payload plus a free `tag`/`user` pointer for app messages.
- `Cmd` — `alias Cmd = fn Msg()`. `null` means "no command." There is no
  batch-command buffer in the current code: `update()` returns one `Cmd`,
  which `dispatch()` calls and chains through `update()` again.
- `View` — either `content: String` (parsed by xray's ANSI parser) or a
  direct `cells: Cell[]` grid (`cells_width`/`cells_height`), plus cursor
  state, alt-screen flag, mouse mode, and up to `MAX_OVERLAYS` (8)
  `Overlay` entries for floating content (menus, shadows) over the base
  view. Built fluently: `new_view(s).set_cursor(x, y).set_alt_screen(true)`.
- `Program` — all mutable state for one run: the `Model`, a fixed
  `TimerEntry[MAX_TIMERS=32]` array, alt-screen/mouse-mode flags, the
  pending input byte buffer (`char[512]`), a `send_queue`
  (`Msg[MAX_BATCH=16]` ring buffer for `Program.send()`), the reader
  thread handle, and a pointer to the `xray::Renderer`. A single
  `Program* g_program` global is set for the duration of `run()` (cleared
  via `defer`) so free functions like `tick()`, `every()`, `cancel()` can
  reach the active program. Safe because only one `Program` runs at a
  time — `run()` is not reentrant.

## Event-loop lifecycle (`Program.run`)

1. **Setup** (skipped in test mode): enter raw mode, hide the cursor,
   enable focus reporting, install `SIGWINCH`/`SIGINT`/`SIGTERM` handlers,
   spawn the input reader thread (`thread::Thread.create`).
2. **Model init**: call `model.init()`; if it returns a `Cmd`, invoke it
   and dispatch the resulting `Msg` (can already quit). Call `on_mount()`.
3. **Initial size**: from `with_window_size()` injection, a real
   `get_window_size()` query, or `80x24` in test mode. `WINDOW_SIZE` is
   dispatched before the first render. The `xray::Renderer` is created
   here (non-test mode), with `set_sync_supported()` enabled when
   `should_support_sync_output()` heuristically detects a capable terminal
   (`SSH_TTY`, `WT_SESSION`, `TERM_PROGRAM`, `TMUX`, `STY`).
4. **First render**: `render_current_view()`.
5. **Main loop**, each iteration: fire expired timers; drain input (from
   `inject_input` in test mode, or `g_input_queue` fed by the reader
   thread); drain `send_queue`; handle `SIGWINCH` (resize renderer,
   dispatch `WINDOW_SIZE`); append new bytes to `self.pending` and loop
   `parse_key()` over it, dispatching `KEY`/`MOUSE`/`FOCUS`/`BLUR` as
   parsed; re-render if anything changed. When idle, block on
   `input_queue_wait()` up to the soonest timer deadline (capped at
   1000ms, or 100ms if input parsing is stuck on an incomplete sequence)
   to avoid busy-waiting.
6. **Shutdown** (via `defer`, LIFO): exit alt screen if active, call
   `on_destroy()`, then (non-test mode) destroy the renderer, tear down
   the input queue, disable mouse/focus reporting, show the cursor, reset
   OSC cursor-color/mouse-cursor sequences, restore the original termios.

`dispatch()` is the single message-processing primitive: calls
`model.update(m)`, and if the returned `Cmd` is non-null, calls it and
feeds the resulting `Msg` back into `update()`, chaining up to `MAX_BATCH`
(16) times or until a `Cmd` returns `NONE`/`QUIT`. `QUIT` anywhere in the
chain makes `dispatch()` return `true`, which `run()` treats as "stop."

## Render pipeline

`render_current_view()` wraps `model.view()` in `@pool()` (temp allocator
freed at block exit):

1. Toggles alt-screen SGR sequences on transition, and mouse-reporting
   sequences when `View.mouse_mode` changes.
2. In test mode, renders the `View` into a `DString` capture buffer
   instead of stdout.
3. In real mode, drives the `xray::Renderer`:
   - **Direct-cell path**: if `View.cells.ptr != null`, cells are copied
     straight into `r.screen` via `set_cell()`, clamped to the smaller of
     the view's and renderer's dimensions — no string building or ANSI
     parsing.
   - **String path**: otherwise `View.content` is split on `\n`, each line
     parsed via `screen.render_ansi_string()` (understands SGR and CUP,
     skips other CSI).
   - Overlays are composited: shadow → content (alpha-blended via
     `Color.blend_over` for `0 < alpha < 255`, or `blit_ansi` when opaque)
     → inner shadow.
   - `r.end_frame()`: diffs `cells` against `prev_cells`
     (`ScreenBuffer.render_diff`), wraps the diff in synchronized-output
     markers (`ESC[?2026h`/`l`, mode 2026) when supported, hides the
     cursor for the duration, writes via the injected `WriteFn`, then
     `screen.swap()`.
   - Cursor position/shape/color/blink and OSC 22 mouse-cursor shape are
     emitted once, after `end_frame()`.

`render_diff` has two modes: a full redraw (first frame or after
`resize()`) and a differential mode that, per dirty line, finds the
contiguous span of changed cells and emits only that span with one cursor
move. `Style.diff_sgr()` further limits output to SGR codes that changed
since the last cell painted. `ColorKind.TRANSPARENT` is a compositing
primitive: `set_cell()` resolves it by inheriting the existing cell's
channel, letting overlays paint partial cells.

## Threading model

Two threads exist during a real run:

- **Main thread** — the event loop: timers, dispatch, rendering,
  signal-flag polling (`g_win_resized`).
- **Reader thread** (`input_reader_fn`) — polls stdin with a 50ms timeout
  and pushes raw bytes into `g_input_queue`, a `char[4096]` ring buffer
  guarded by a `Mutex` + `ConditionVariable`, so a blocking `read()` never
  stalls rendering or timers.

The only cross-thread shared state is `InputQueue`; all access goes
through `input_queue_push`/`drain`/`wait`, each taking the mutex.
`g_program` and `g_win_resized` are touched from the main thread and from
signal handlers (main thread's signal-delivery context), never from the
reader thread.

Shutdown: `run()`'s `defer` blocks close alt-screen state and call
`on_destroy()` first, then `input_queue_destroy()` sets `closed = true`
and broadcasts the condition variable so the reader thread's loop exits;
the `Thread` handle is not explicitly joined. `SIGINT`/`SIGTERM` are
handled directly in `fatal_signal_handler` (`tty.c3`), which restores
termios and alt-screen state synchronously before re-raising the signal —
this bypasses the normal `defer` unwind since it can fire mid-render.

## Memory conventions

- **Per-frame temp allocation**: the whole render runs inside `@pool()`.
  Anything from the temp allocator (`dstring::temp()`, `string::tformat()`)
  is freed at block exit — models must not stash temp-allocated strings
  across frames.
- **Heap ownership**: `xray::new_screen_buffer`, `xray::new_renderer`, and
  `xray::new_layer` return heap pointers the caller owns.
  `Program.run()` frees the renderer in its shutdown `defer`. Temporary
  `ScreenBuffer`s created mid-render for overlay blending always pair
  their allocation with `defer { tmp.destroy(); mem::free(tmp); }`.
- **Fixed-capacity buffers over dynamic allocation**: `Program.timers`
  (32), `Program.send_queue` (16), `Program.pending` (512 bytes),
  `InputQueue.buf` (4096 bytes), and `View.overlays` (8) are fixed-size
  arrays scanned linearly or treated as ring buffers — no heap churn per
  event/frame on the hot path.

## Testing strategy

- **Unit tests** (`fn void test_x() @test`) live alongside the code they
  test (`milktea/integration_test.c3`, `keyprobe_test.c3`,
  `test_render.c3`, `xray/xray_test.c3`, etc.), plus `test/snapshot.c3` for
  shared snapshot infrastructure. Over 200 `@test`-annotated functions
  exist across the codebase.
- **Test-mode injection** (`Program.test_mode`): `with_test_mode(&output)`
  routes rendered output into a `DString` and skips raw-mode/signal/TTY
  setup, making `run()` deterministic and TTY-free.
  `with_window_size(w, h)` fixes the reported terminal size;
  `with_input(bytes)` feeds a fixed byte sequence through
  `drain_inject_input()` instead of the reader thread. The
  `@test_program`/`@test_program_input` macros (`milktea/macros.c3`) wire
  these together for test bodies.
- **Snapshot tests**: `snapshot::assert_snapshot(subdir, name, actual)`
  compares output against `snapshots/{subdir}/{name}.snap`. Setting
  `UPDATE_SNAPSHOTS=1` regenerates the golden file instead of asserting.
  Golden files live under `snapshots/milktea/`, `snapshots/xray/`,
  `snapshots/glaze/`, `snapshots/boba/` — one directory per module.
- **Render-frame assertions**: `ScreenBuffer.render_frame()`/
  `render_frame_row()` dump the cell grid as plain text, and
  `render_diff_str()` exposes the raw diff — letting tests assert on
  rendering without a real terminal.
