# xray Layout System + Example Refactors - Mon May 18, 2025

## Summary

Implemented a flexbox-style constraint layout system in the xray module (`xray/layout.c3`), added draw helpers to `ScreenBuffer`, and updated examples to use the new API.

## Changes

### 1. `xray/layout.c3` — New file

#### Rect

```c3
struct Rect { int x, y, w, h; }
fn Rect new_rect(int x, int y, int w, int h)
fn int  Rect.right(&self)
fn int  Rect.bottom(&self)
fn bool Rect.contains(&self, int px, int py)
fn Rect Rect.inset(&self, int left, int top, int right, int bottom)
```

#### Constraints

```c3
enum ConstraintKind : char { CLEN, CMIN, CMAX, CPERCENT, CFILL }
struct Constraint { ConstraintKind kind; int value; }
fn Constraint constraint_len(int n)
fn Constraint constraint_fill(int weight)
fn Constraint constraint_percent(int p)
fn Constraint constraint_min(int n)
fn Constraint constraint_max(int n)
```

#### Standalone split helpers

```c3
fn int layout_h(Rect area, Constraint[] cs, Rect[] out_rects)
fn int layout_v(Rect area, Constraint[] cs, Rect[] out_rects)
fn int layout_h_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects)
fn int layout_v_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects)
```

Two-pass solver: pass 1 assigns `CLEN`/`CPERCENT`/`CMIN`; pass 2 distributes remainder proportionally among `CFILL`/`CMAX` with up to 4 clamping iterations.

#### FlexNode tree

```c3
enum FlexDirection : char { ROW, COLUMN }
enum JustifyContent : char { JUSTIFY_START, JUSTIFY_CENTER, JUSTIFY_END,
                             JUSTIFY_SPACE_BETWEEN, JUSTIFY_SPACE_AROUND, JUSTIFY_SPACE_EVENLY }
enum AlignItems : char { ALIGN_STRETCH, ALIGN_START, ALIGN_CENTER, ALIGN_END }

struct FlexNode { ... }  // temp-allocated via mem::tnew

fn FlexNode* flex_row() / flex_col() / flex_node() / flex_len(n) / flex_fill(w) / flex_percent(p)
fn FlexNode* FlexNode.add(&self, FlexNode* child)        // chainable
fn FlexNode* FlexNode.with_justify / with_align / with_gap / with_padding / ...
fn void      FlexNode.solve(&self, Rect area)            // recursive layout
fn Rect      FlexNode.rect(&self)
fn Rect      FlexNode.child_rect(&self, int idx)
```

### 2. `xray/screen.c3` — Draw helpers added

```c3
fn void ScreenBuffer.fill_rect(&self, Rect r, Style style)
fn void ScreenBuffer.draw_string_in_rect(&self, Rect r, String text, Style style)
fn void ScreenBuffer.blit(&self, sz dst_x, sz dst_y, ScreenBuffer* src, bool transparent)
fn void ScreenBuffer.blit_ansi(&self, sz dst_x, sz dst_y, sz w, sz h, String ansi_text, bool transparent)
```

`blit(transparent: true)` skips source cells where `content == ' '` and `bg.kind == NONE` — the same pattern wolf3d-server used manually for dialog compositing.

### 3. `examples/split-editors/split-editors.c3`

Replaced `self.width / self.count` with `layout_h` using N `constraint_fill(1)` children:

```c3
// Before
int pane_w = self.width / self.count;

// After
xray::Constraint[4] pane_cs;
for (int i = 0; i < self.count; i++) pane_cs[i] = xray::constraint_fill(1);
xray::Rect[4] pane_rects;
xray::layout_h(xray::new_rect(0, 0, self.width, edit_h), pane_cs[0:self.count], pane_rects[0:self.count]);
```

Added `xray/**` to sources in `project.json`.

### 4. `examples/paint/paint.c3`

Replaced hardcoded `canvas_x = 5`, `canvas_y = 1` fields with `palette_rect` and `canvas_rect` (`xray::Rect`):

```c3
// Before
self.canvas_x = 5;
self.canvas_y = 1;
int pixel_w = self.term_width - self.canvas_x;

// After
xray::Rect body = xray::new_rect(0, 1, self.term_width, self.term_height - 1);
xray::Rect[2] cols;
xray::layout_h(body, { xray::constraint_len(5), xray::constraint_fill(1) }, cols[..]);
self.palette_rect = cols[0];
self.canvas_rect  = cols[1];
self.canvas.resize(self.canvas_rect.w, self.canvas_rect.h * 2);
```

Mouse hit-testing now uses `palette_rect.contains()` and `canvas_rect.x/y` for coordinate translation.

### 5. `examples/wolf3d-server/wolf3d-server.c3`

- **Welcome screen composite loop** simplified: removed dead `dlg_x/dlg_y` variables, use `cell_at()` instead of raw index math.
- **Input dialog** (`ENTERING_NAME` / `TAG_INPUT`): replaced hand-drawn blue box with glaze-rendered box (rounded border, purple palette, matching welcome screen style). Centered using `FlexNode` with `JUSTIFY_CENTER` / `ALIGN_CENTER`.
- **Version bumped** to `0.2.6`.

## C3 Syntax Gotchas Discovered

- `[0..n]` is **end-inclusive** in C3 — `cs[0..n]` reads `n+1` elements. Use `cs[0:n]` (start:count) for exclusive-end slices.
- `sz` is a reserved type name — cannot be used as a variable name.
- Method calls require receiver: `sb.fill_rect(...)` not `fill_rect(sb, ...)`.
- `Rect.inset` parameter order: `(left, top, right, bottom)` — matches x/y field order, not CSS convention.

## Build Command

```bash
cd milktea && c3c test
cd milktea && c3c build split-editors
cd milktea && c3c build paint
cd milktea && c3c build wolf3d-server
```

## Files Modified

- `xray/layout.c3` — New file
- `xray/screen.c3` — Draw helpers appended
- `xray/xray_test.c3` — 23 new tests (all passing, 98 total)
- `examples/split-editors/split-editors.c3`
- `examples/paint/paint.c3`
- `examples/wolf3d-server/wolf3d-server.c3`
- `project.json` — Added `xray/**` to split-editors and paint targets

---

# Mouse Input Parsing & Phantom Keypress Fixes - Mon May 18, 2026

## Summary

Ported mouse support (SGR/X10 protocols, wheel events) into the C3 input parser, then debugged a chain of 5 cascading bugs that caused crashes, phantom keypresses, and missed scroll events during mouse input.

## The Bug Chain

What started as "mouse scroll doesn't work" turned out to be 5 interrelated bugs:

### 1. `parse_csi` busy-loop

`parse_csi` returned `consumed=0` on invalid CSI sequences, causing the input loop to spin at 100% CPU without ever blocking.

**Fix:** `parse_csi` now reports `consumed=pos+1` on unexpected bytes (making forward progress), and `parse_key` consumes those bytes instead of re-emitting them as keypresses.

### 2. DEBUG stderr spam

Unconditional `io::eprintfn("DEBUG ...")` calls flooded stderr on every input event.

**Fix:** All debug logging gated behind `g_debug_log.enabled` (set by `--debug` flag).

### 3. Mouse never enabled

`enable_mouse()` existed but was never called. No mouse escape sequences were sent to the terminal.

**Fix:** Added `MouseMode` enum and `mouse_mode` field to `View`. The renderer now enables/disables mouse mode when the field changes. `JsModel.view()` sets `MOUSE_MODE_CELL_MOTION`.

### 4. Wheel buttons misidentified

SGR and X10 parsers used `btn_code & 3` bitmask, which mapped wheel codes (64/65) to left/middle buttons. Scroll events were silently misclassified.

**Fix:** Wheel button codes (64-67 for SGR, 4/5 for X10) are now checked *before* the bitmask fallback.

### 5. Phantom keypresses on scroll (the hard one)

Two sub-issues working together:

**a) Truncated CSI at ESC boundary:** When two mouse events arrive back-to-back and the read splits at an ESC byte, `parse_csi` consumed the ESC as an "unexpected byte", breaking the second sequence into garbage.

**Fix:** `parse_csi` now stops *before* an ESC byte (`csi.consumed = pos`) since it starts the next escape sequence, rather than consuming it.

**b) Buffer overflow:** The `pending` buffer was only 32 bytes. Multiple mouse events arriving in one read silently overflowed, leaving partial sequences that were parsed as individual keypresses.

**Fix:** `pending` buffer increased from 32 → 512 bytes, `tmp` buffer from 64 → 256 bytes.

## Changes

### `milktea/input.c3`

- `MouseButton` enum: added `MOUSE_WHEEL_UP`, `MOUSE_WHEEL_DOWN`
- `parse_csi`: on unexpected byte — if ESC, stop before it (`csi.consumed = pos`); otherwise consume it (`csi.consumed = pos + 1`)
- X10 mouse parser: wheel buttons (cb==4, cb==5) checked before bitmask
- SGR mouse parser: wheel buttons (btn_code >= 64) checked before bitmask
- `parse_key` CSI invalid branch: returns `NONE` (discard) instead of `ESC` (phantom keypress)

### `milktea/milktea.c3`

- Added `MouseMode` enum (`NONE`, `CELL_MOTION`, `ALL_MOTION`)
- Added `mouse_mode` field to `View` and `Program`
- `pending` buffer: 32 → 512 bytes
- `tmp` buffer: 64 → 256 bytes
- Input loop: tracks `stuck` state, gates INPUT logging behind `self.debug`
- Blocking condition: blocks when stuck (incomplete data) with 100ms cap
- `render_current_view`: enables/disables mouse mode on mode transitions

### `taro/js_model.c3`

- Mouse dispatch: forwards ALL mouse events to viewports with correct button/action names (`"wheel_up"`, `"wheel_down"`, `"press"`, `"release"`, `"motion"`)
- Sets `view.mouse_mode = milktea::MouseMode.MOUSE_MODE_CELL_MOTION` in `JsModel.view()`
- All `io::eprintfn("DEBUG ...")` calls gated behind `g_debug_log.enabled`

### `boba/viewport.c3`

- `handle_mouse`: recognizes `"wheel_up"`/`"wheel_down"` with `"press"` action; kept legacy `"left"`/`"middle"` on `"motion"` as fallback

### `taro/js_view.c3`

- Viewport render loop: added `pos > content.len` guard and bounds-safe `pos` advancement to prevent C3 slice panic after last text line

### `examples/taro/taro.c3`

- Changed from `@run_program` macro to `@program` + `p.debug = debug` + `p.run()` to propagate `--debug` flag to Program's input logging

## Key Findings

- **C3 `String` slicing panics on out-of-bounds** — no graceful degradation, unlike Go's slice semantics. Always guard with length checks.
- **Escape sequence parsing is inherently fragile at read boundaries** — stdin reads are arbitrary-length; sequences can split anywhere. The parser must handle partial data by buffering and blocking, never by consuming ahead.
- **Buffer sizes matter more in C than Go** — Go's `bufio` handles growth transparently; C3's fixed buffers silently drop data on overflow, which surfaces as mysterious downstream bugs.
- **The `btn_code & 3` bitmask is a legacy X10 convention** — modern SGR mouse protocol encodes buttons differently (64+ for wheel), and the parser must check these before applying the old mask.

## Build Command

```bash
cd milktea && c3c test tea
cd milktea && c3c build taro
```

98 tests pass (milktea static lib + xray renderer).

---

# Animated Borders & Lipgloss Width/Height Semantics Fix - Mon May 18, 2026

## Summary

Added animated border support (pulse, rainbow, race) as a glaze library feature, and fixed `Style.render()` width/height semantics to match Go glaze v2 — where `set_width(N)` and `set_height(N)` both mean **total outer size** (border + padding + content = N).

## Changes

### 1. `glaze/border_anim.c3` — New file

`BorderAnimation` enum with four modes:

- `NONE` — static border (default)
- `PULSE` — border brightness oscillates (~60fps)
- `RAINBOW` — hue shifts along perimeter over time (~60fps)
- `RACE` — single bright highlight laps counterclockwise (~20fps)

Core API:

```c3
fn BorderAnimation border_anim_from_string(String s)
fn int             border_anim_tick_ms(BorderAnimation anim)
fn String          Border.wrap_animated(int content_w, int content_h, BorderAnimation anim, Style* style, long time_ms)
```

`wrap_animated` walks the perimeter in a continuous counterclockwise loop, assigns each border cell a truecolor SGR code based on position + time, and returns a raw ANSI string. Uses HSL→RGB conversion and sine approximation — no external color library needed.

Perimeter formula: `2 * (content_w + content_h) + 4` (includes 4 corners). Top row flows right-to-left for continuous motion.

### 2. `glaze/style.c3` — Animation fields + height fix

- Added `border_anim` and `border_anim_speed` fields to `Style` struct
- Setters: `set_border_anim()`, `set_border_anim_speed()`, `with_border_anim()`, `with_border_anim_speed()`
- Added `Style.render_content_only()` — renders styled content without border (used by animated path)
- **Height semantics fix**: `render()` now subtracts `border_v` from `self.height` before filling, matching Go glaze v2 behavior
- **`measure_height()` fix**: passes `outer_width` directly to `set_width()` instead of double-subtracting border

### 3. `taro/js_view.c3` — JS wiring

- `props_to_style()`: parses `borderAnimation` and `borderAnimSpeed` props
- All bordered component paths (box, textarea, viewport) pass full `area.w` / `area.h` to `set_width` / `set_height` instead of subtracting border+padding
- Animated border overlay: static frame rendered first via `style.render("")`, then `Border.wrap_animated()` overwrites border cells with animated colors
- `request_render_tick()` called to schedule next animation frame

### 4. `examples/inputbox/inputbox.c3`

Updated `set_width` / `set_height` calls to pass full area dimensions (removed manual border subtraction), matching corrected semantics.

## Architecture Decisions

1. **Animation lives in glaze, not taro** — `Border.wrap_animated()` is a library function any C3 code can use. JS layer just wires props.
2. **Per-character ANSI SGR** — each border character gets its own `\x1b[38;2;R;G;Bm` prefix. Works with both the glaze string pipeline and the screen buffer's `render_ansi_string()` parser.
3. **Static frame + animated overlay** — slightly wasteful (border drawn twice) but simple and correct. Avoids duplicating the border layout logic.
4. **Go glaze v2 semantics** — `set_width(N)` means total outer width. `render()` subtracts internally. Callers just pass the area size.

## C3 Gotchas

- `math::fmod` doesn't exist — use `h - 2.0 * (double)(int)(h / 2.0)` pattern
- `math::sin`/`math::cos` are macros using `$$sin`/`$$cos` builtins, not real functions
- Multiple variable declarations can't use initialization (`double r = 0, g = 0` is illegal)
- Initializers must use all named OR all unnamed fields (no mixing)

## Build Targets

All 10 pass: `taro`, `tea`, `counter`, `spinner`, `inputbox`, `canvas`, `split-editors`, `viewport`, `timer`, `list`.

```bash
cd milktea && c3c build taro
cd milktea && c3c build tea
```

## Files Modified

- `glaze/border_anim.c3` — New file (animated border renderer)
- `glaze/style.c3` — Animation fields, height fix, `render_content_only()`
- `taro/js_view.c3` — Prop parsing, width/height call sites, animated overlay
- `examples/inputbox/inputbox.c3` — Width/height call fix

---

# Textarea Cursor: Native Block + OSC 12 Color - Tue May 19, 2026

## Summary

Added a blinking block cursor to focused textareas via two complementary mechanisms: (1) native terminal cursor positioned via CUP sequences with color set via OSC 12, and (2) an optional fake cursor rendered directly in the textarea content using ANSI SGR.

## Changes

### Option 1 — Native cursor with color (OSC 12)

- `milktea::Cursor` gained a `color` field (hex string, e.g. `"#ff6600"`)
- `render.c3`: added `cursor_color_seq()` (`\x1b]12;color\x1b\\`) and `OSC_CURSOR_COLOR_RESET` (`\x1b]112\x1b\\`)
- Both render paths (legacy `render_view_to` and the xray path in `milktea.c3`) emit OSC 12 before the cursor shape sequence; `OSC_CURSOR_COLOR_RESET` is emitted in the cleanup defer on exit
- `View.set_cursor_color(color String)` builder added
- `js_view.c3`: on render, the focused textarea's screen-space cursor position and `cursorColor` prop are stored in a `g_focused_cursor` global; `js_model.c3` reads it after `render_vnode` and calls `view.set_cursor_shape(..., CURSOR_BLOCK, blink: true)` + `view.set_cursor_color()`
- `hardwired.js`: `cursorColor: "#ff6600"` on the input textarea

### Option 2 — Fake cursor in content (SGR)

- `Textarea` struct gained `show_cursor: bool`
- `Textarea.view()` now renders the character at `cursor_col`/`cursor_row` using `cursor_style` when `focused && show_cursor`; handles cursor-at-end (appends a highlighted space) and cursor on empty lines
- `js_view.c3`: reads `showCursor`, `cursorBg`, `cursorFg` props to opt in and override the default white-on-black style

---

## drawCursor: Custom Cursor Overlays - Tue May 19, 2026

A `drawCursor` prop on textarea/input vnodes lets JS (and native C3) supply an arbitrary string to render at the cursor position each frame, replacing the native block cursor.

### JS API

```js
h("textarea", {
  drawCursor: (x, y, blink) => blink ? "🔥" : null,
  cursorInterval: 400,  // ms per blink phase
})
```

`drawCursor` is a `fn(x, y, blink) -> string | null`. When it returns null or empty the cell is left untouched — the underlying text character shows through, so the "off" phase blinks on top of content rather than blanking it.

### Native C3 API

`ScreenBuffer.overlay_char(col, row, text, style)` — renders the first character of `text` (including ANSI SGR sequences) into exactly one cell slot. Neighbors are never touched, so wide chars (emoji, CJK) can't shift the rest of the line.

`examples/cursors` demonstrates both approaches:
- Section A (draw-cursor): fire 🔥, skull 💀, crosshair ✛, dissolving block, rainbow, matrix katakana
- Section B (native): block/underline/bar shapes with OSC 12 custom colors

### xray fixes

- `render_diff` (both full and differential paths) now skips the placeholder slot after a wide cell — previously the blank placeholder was emitted as an extra space, shifting everything after a wide char by one column
- `render_ansi_string` writes an `empty_cell()` placeholder at `col+1` after any width-2 cell so stale content in that slot isn't output by a later diff pass
- OSC sequences (`\x1b]...\x1b\\`) are now skipped by the ANSI parser instead of leaking as literal characters
- `input.c3`: `\x1b[Z` (shift+tab) now correctly parsed as `TAB` with `shift=true` instead of falling through to ESC and quitting

### Debug helpers added to `ScreenBuffer`

- `render_frame()` — plain-text snapshot of all rows (wide chars counted correctly)
- `render_frame_row(row)` — single-row version
- `render_diff_str()` — raw escape output as a string for assertions
- 8 new `@test` functions covering wide char layout, placeholder, border displacement, OSC skipping, and overlay_char

Both options can be used independently or together. OSC 12 cursor color resets to terminal default on app exit.
