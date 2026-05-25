# C3 Bubbletea Architecture Improvements

## Overview

All C3 code updated from 0.7.x to 0.8.0 (`usz`/`isz` → `sz`), plus nine architectural improvements making the framework more idiomatic, type-safe, and ergonomic.

## 1. Program Struct (replaces globals)

All mutable runtime state (`batch_cmds`, `batch_count`, `timers`, `pending` buffer) moved from globals into a `Program` struct. Enables sequential multi-instance use and proper testability.

```c3
struct Program {
    Model model;
    Cmd[MAX_BATCH] batch_cmds;
    int batch_count;
    TimerEntry[MAX_TIMERS] timers;
    bool in_alt_screen;
    char[256] pending;
    sz pending_len;
}
```

A global `Program* g_program` pointer is set during `run()` and cleared on exit. Safe because only one program can run at a time (one terminal). The `batch()` and `tick()` functions use this pointer to store state.

## 2. Cross-Platform `$if`

Removed hardcoded macOS `TIOCGWINSZ` constant (was dead code — the C interop layer in `tty_winsize.c` handles it via `<sys/ioctl.h>`). `SIGWINCH` is 28 on both macOS and Linux. The C interop layer already supports both platforms.

## 3. Component Lifecycle Interface

Extended the `Model` interface with optional lifecycle hooks:

```c3
interface Model {
    fn Cmd init();
    fn Cmd update(Msg msg);
    fn View view();
    fn void on_mount() @optional;    // called after init + first render
    fn void on_destroy() @optional;  // called on program exit
    fn void on_focus() @optional;    // terminal gained focus
    fn void on_blur() @optional;     // terminal lost focus
}
```

Hooks are called by the framework at the appropriate times. Existing models don't need to implement them (`@optional`).

## 4. View Builder Methods

Fluent methods on `View` for declarative construction:

```c3
// Before:
View v = new_alt_screen_view(content);
v.has_cursor = true;
v.cursor = new_cursor(5, 3);
return v;

// After:
return new_view(content).set_cursor(5, 3).set_alt_screen(true);
```

Added: `set_cursor(x, y)`, `set_cursor_shape(x, y, shape, blink)`, `set_alt_screen(bool)`.

Also added `viewf(fmt, ...)` and `view_alto(fmt, ...)` for formatted content.

## 5. ViewBuf — Chained String Builder

New `ViewBuf` type wrapping `DString` with chaining methods:

```c3
ViewBuf buf = new_view_buf();
buf.write(title.render("Hello")).writeln("").write(content);
return milktea::new_view(buf.str());
```

Methods: `write(s)`, `writeln(s)`, `writec(c)`, `writef(fmt, ...)`, `str()`.

## 6. Layout Helper

New `Layout` type that tracks rows and auto-computes cursor position:

```c3
Layout l = new_alt_layout();
l.write_line(title.render("Sign Up"));
l.write_line("");
l.write_input_line("Nickname:", input.view(), focused, input.cursor_x(), 10);
l.write_line("");
l.write_line(hint.render("TAB to switch"));
return l.view();  // cursor position computed automatically
```

Eliminates manual row counting — the #1 source of bugs in TUI code.

## 7. Style Shorthand Methods

Shorter names for common style operations (coexist with longer names):

| Long | Short |
|------|-------|
| `foreground(color_hex("#00d7ff"))` | `with_fg("#00d7ff")` |
| `background(color_hex("#ff0000"))` | `with_bg("#ff0000")` |
| `set_bold(true)` | `with_bold(true)` |
| `set_italic(true)` | `with_italic(true)` |
| `set_underline(true)` | `with_underline(true)` |
| `set_border(b)` | `with_border(b)` |
| `set_width(w)` | `with_width(w)` |

Note: `with_` prefix required because C3 doesn't allow methods with the same name as struct fields.

## 8. `@program` / `@run_program` Macros

Eliminates the unsafe `(milktea::Model)&` cast in every example:

```c3
// Before:
Counter c = {};
Program p = { .model = (milktea::Model)&c };
if (catch err = p.run()) { ... }

// After:
Counter c = {};
if (catch err = milktea::@run_program(&c)) { ... }
```

The macro handles the cast internally. `@program(&c)` creates a `Program`; `@run_program(&c)` creates and runs it.

## 9. Contracts

Added `@require`/`@ensure` contracts to core functions:

- `batch()` — `@require cmds.len > 0, cmds.len <= MAX_BATCH`
- `dispatch()` — `@ensure return == true || m.kind == MsgKind.QUIT`
- `tick()` — `@require delay_ms > 0, callback != null`
- `parse_key()` — `@ensure return.consumed <= buf.len`

In release mode these become optimizer hints. In safe mode they're runtime assertions.

## Files Changed

### New files
- `milktea/viewbuf.c3` — ViewBuf string builder
- `milktea/layout.c3` — Layout with auto cursor tracking
- `milktea/macros.c3` — `@program` / `@run_program` macros

### Modified files
- `milktea/milktea.c3` — Program struct, lifecycle hooks, view builders, contracts
- `milktea/input.c3` — Contract on `parse_key()`
- `milktea/tty.c3` — Removed dead constant, cleaned up
- `glaze/style.c3` — `with_*` shorthand methods

### Unchanged (0.8.0 migration only)
- All 13 files with `usz`/`isz` → `sz` replacements

## Build Status

- Library: builds clean
- 24 example targets: all link
- 21 tests: all pass
