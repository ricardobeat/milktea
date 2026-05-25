# Dev Log — Thu May 15, 2026

## C3 Splash Example — SIGTRAP on `@optional` Methods

### Problem
The splash example crashed with `SIGTRAP` (trace trap) when run in a real terminal. In non-TTY environments (e.g., piped), it failed with `milktea::TTY_GETATTR_FAILED` instead.

### Root Cause
`enable_focus()` at `milktea.c3:421` tells the terminal to send focus gain/loss events. When a focus event arrives, the event loop calls `self.model.on_focus()` / `self.model.on_blur()` — but `SplashModel` doesn't implement those `@optional` methods. In C3, calling an unimplemented optional method dereferences a null vtable entry, which traps.

**All 4 call sites were unguarded:**
- `milktea.c3:431` — `self.model.on_destroy()` (in defer block)
- `milktea.c3:465` — `self.model.on_mount()` (after init)
- `milktea.c3:530` — `self.model.on_focus()` (on FOCUS message)
- `milktea.c3:533` — `self.model.on_blur()` (on BLUR message)

### Fix
The C3 idiom for safe optional method calls is `if (&self.model.on_method)` — the `&` operator checks if the vtable entry is non-null:

```c3
if (&self.model.on_mount) self.model.on_mount();
if (&self.model.on_destroy) self.model.on_destroy();
if (&self.model.on_focus) self.model.on_focus();
if (&self.model.on_blur) self.model.on_blur();
```

Also added `on_focus`/`on_blur` stubs to `splash.c3` for completeness. All 37 tests pass.

### Key C3 Pattern
```c3
interface VeryOptional {
    fn void do_something() @optional;
}

fn void safe_call(VeryOptional z) {
    if (&z.do_something) {
        z.do_something();  // only called if implemented
    }
}
```
Source: `github.com/c3lang/c3-web/docs/generic-programming/anyinterfaces.md`

---

## C3 Threading and Synchronization Primitives

### std::thread Module (`/opt/homebrew/Cellar/c3c/0.8.0/lib/c3/std/threads/`)

**Core types:**
```c3
typedef Thread = inline NativeThread;       // POSIX: wraps pthread_t
typedef Mutex = NativeMutex;                // POSIX: wraps pthread_mutex_t
typedef RecursiveMutex = inline Mutex;      // Mutex with .recursive flag
typedef ConditionVariable = NativeConditionVariable;
alias ThreadFn = fn int(void* arg);
```

**Thread API:**
```c3
Thread.create(&thread, thread_fn, arg, settings)  // start thread
Thread.join(&thread)                                // wait for completion
Thread.detach(&thread)                              // no join needed
Thread.current()                                    // get current thread
Thread.yield()                                      // yield CPU
Thread.sleep(duration)                              // sleep
```

**Mutex API:**
```c3
Mutex.init(&mu)       // initialize
Mutex.lock(&mu)       // lock (blocking)
Mutex.try_lock(&mu)   // non-blocking lock
Mutex.unlock(&mu)     // unlock
Mutex.destroy(&mu)    // cleanup
```

**Channels (generic, parameterized):**
- `BufferedChannel{Type}` — bounded queue with send/read blocking
- `UnbufferedChannel{Type}` — rendezvous channel (sender blocks until receiver ready)
- `OneShotChannel{Type}` — single value, single sender/receiver

**Thread Pools:**
- `ThreadPool{SIZE}` — compile-time sized pool with `Mutex` + `ConditionVariable`
- `FixedThreadPool` — runtime-sized pool (marked "do not use in production")

**Atomic operations** (`std::atomic`):
```c3
Atomic{Type}.load(&self, ordering)
Atomic{Type}.store(&self, value, ordering)
Atomic{Type}.exchange(&self, value, ordering)
Atomic{Type}.compare_exchange(&self, expected, desired, ...)
```
Orderings: `RELAXED`, `ACQUIRE`, `RELEASE`, `ACQUIRE_RELEASE`, `SEQ_CONSISTENT`

---

## Go Bubbletea Key Input Flow

### Architecture (stdin → KeyMsg)

```
stdin → [cancelReader] → [ultraviolet.TerminalReader] → [chan Msg] → eventLoop → model.Update()
```

1. **`tty.go:79`** — `go p.readLoop()` launches reader goroutine
2. **`tty.go:84-93`** — `readLoop` calls `p.inputScanner.StreamEvents(ctx, p.msgs)` which blocks on stdin, parses ANSI sequences via ultraviolet, and pushes `uv.Event`s into `p.msgs`
3. **`tea.go` event loop** — receives from `p.msgs` channel (non-blocking select with other channels)
4. **`input.go`** — `translateInputEvent()` maps `uv.KeyEvent` → `KeyPressMsg`, `uv.MouseEvent` → `MouseClickMsg`, etc.

**Key insight:** stdin reading is fully decoupled from rendering. The read goroutine writes to an unbuffered channel; the event loop selects on it. Rendering happens in a separate goroutine (`cursedRenderer`) on a ticker. A slow stdout write never blocks stdin reading.

### Test Pattern (Go)
```go
var buf bytes.Buffer
var in bytes.Buffer

p := NewProgram(model,
    WithInput(&in),       // inject fake stdin
    WithOutput(&buf),     // capture output
    WithWindowSize(80, 24),
)

go p.Send(sequenceMsg{...cmds..., Quit})
p.Run()
```

Tests inject `bytes.Buffer` for both input and output, avoiding any TTY dependency. `Program.Send()` pushes messages directly into the event loop channel.

---

## milktea Testability Patterns

### Current C3 Architecture
```
Reader thread (milktea.c3:224)  →  g_input_queue (ring buffer, mutex-protected)
Main event loop (milktea.c3:400) →  drains queue, processes, renders
```

The C3 port mirrors Go's architecture: a separate reader thread polls stdin every 50ms, pushes bytes into a ring buffer. The main loop drains the buffer non-blocking.

### Test Infrastructure
- `@test_program` macro creates a `Program` in test mode with a capture buffer
- `@test_dispatch` macro tests input parsing without a full program
- `keyprobe_test.c3` — 37 tests verifying key parsing (Ctrl+C, ESC, Enter, space, runes, UTF-8)
- `integration_test.c3` — full lifecycle tests (init → update → view → quit)
- `test_render.c3` — render output snapshot tests

---

## Findings

- **C3 `@optional` methods trap on null vtable entry** — must guard with `if (&obj.method)` before calling
- **Go bubbletea's read loop is goroutine-based** — `readLoop()` runs in a goroutine, pushes to unbuffered channel, event loop selects on it
- **C3 port uses ring buffer + mutex** instead of Go channels — equivalent pattern, different primitives
- **C3 has rich threading stdlib** — Mutex, ConditionVariable, channels, atomics, thread pools (all in `std::thread`)
- **C3's `@dynamic` attribute** marks interface method implementations; the compiler generates vtable entries
- **C3 doesn't support function overloading** — use default parameters instead
