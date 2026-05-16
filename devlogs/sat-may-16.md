# Dev Log — Sat May 16, 2026

## DOOM Fire Rendering Overhaul

### Problem
The C3 doom-fire example was janky as the fire grew — frame drops, tearing, and the fire extended too high leaving no room for red tones.

### Root Causes Found

1. **`clear()` called every frame** — `r.screen.clear()` was called unconditionally before writing cells, wiping all cells to empty and marking every line dirty. The diff engine then had to re-emit the entire screen.

2. **Raw ANSI strings instead of cells** — The fire (and space/splash) examples built `\x1b[38;5;..;48;5;..m▀` strings per pixel, which were then parsed back into cells by xray. Double work for no benefit.

3. **Synchronized output never enabled** — `sync_supported` was hardcoded `false` with no terminal detection. No DECRPM query was ever sent.

4. **Random range mismatch** — The C3 fire used `rand() % 3` (0-2) while the Zig reference used `rand.intRangeAtMost(0, 3)` (0-3). Wider range makes fire spread more erratically, decaying faster and leaving more room for dark tones.

### Fixes Applied

**Framework (`src/tea/tea.c3`):**
- Added cell-based rendering path to `View` struct (`cells`, `cells_width`, `cells_height`)
- Added `new_cell_view()` and `new_alt_cell_view()` constructors
- `render_current_view` now checks `v.cells.ptr != null` — if true, writes cells directly via `set_cell()`, skipping string→CSI→cells parsing
- Skipped `clear()` for the cell path — `set_cell()` handles dirty-line tracking against the previous frame
- Added `should_support_sync_output()` — checks env vars (TERM_PROGRAM, SSH_TTY, WT_SESSION, TMUX, STY) and sets `sync_supported = true` on the renderer at init
- Added `tick_msg()` helper function
- Added `CURSOR_BLOCK`, `CURSOR_UNDERLINE`, `CURSOR_BAR` constants
- Made `tick()` have default params: `tick(delay_ms = 16, callback = &tick_msg)` — `tea::tick()` now just works

**Framework (`src/xray/color.c3`):**
- Added `ANSI256` color kind
- Added `color_256(int idx)` function for 256-color palette support
- Updated `write_sgr_params` to emit `38;5;N` / `48;5;N` for ANSI256

**Examples:**
- `doom-fire` — rewrote to use cell-based rendering, pre-built `fire_cells[26]` table, `rand() % 4`, palette updated for more orange/red
- `space` — rewrote to use cell-based rendering, fixed color computation to match Go version: `((height-y)/height)^2` with random per-pixel offset
- `splash` — rewrote to use cell-based rendering
- `textinputs` — replaced raw `\x1b[38;2;R;G;Bm` with `lipgloss::new_style().foreground(...)`
- `bounce` — replaced manual `╔═╗║╚╝` with `lipgloss::new_style().set_border(...)`, tick rate fixed to 30fps
- `split-editors` — added placeholder "type something" with dim gray, line number display, highlight on focused editor
- `chat` — eliminated per-wrap-iteration `DString temp()` allocation
- All simple examples — removed `on_tick` boilerplate, using `tea::tick()` or `tea::tick(N)` directly
- All tick examples — replaced `MSG_TICK = 1` constants with `tea::MsgKind.TICK` (new enum value)

### API Changes

**`MsgKind` enum** — added `TICK`:
```c3
enum MsgKind : char {
    NONE, KEY, WINDOW_SIZE, FOCUS, BLUR, MOUSE,
    BATCH, QUIT, TICK, USER,
}
```

**`tick()` defaults:**
```c3
fn Cmd tick(sz delay_ms = 16, Cmd callback = &tick_msg)
```

**`View` struct** — added cell grid fields:
```c3
struct View {
    String content;
    Cursor cursor;
    bool has_cursor;
    bool alt_screen;
    xray::Cell[] cells;
    sz cells_width;
    sz cells_height;
}
```

**`color_256()`** — new in lipgloss:
```c3
fn Color color_256(int idx)  // xterm-256 palette (0-255)
```

### Palette Tuning (doom-fire)

Changed to be more orange/red, less magenta:
| Index | Old | New | Reason |
|-------|-----|-----|--------|
| 3 | 52 (dark brown) | 95 (orange-brown) | Warmer |
| 4 | 53 (dark magenta) | 124 (dark red) | Less magenta |
| 5 | 88 (dark red) | 166 (orange-red) | More orange |
| 6 | 89 (dark red-magenta) | 160 (red) | Less magenta |
| 25 | 7 (pure white) | 230 (near white) | Less washed out |

### Findings

- **Bubbletea/ultraviolet don't use pre-computed escape tables** — they build SGR sequences dynamically via `ansi.Style` builder, with `StyleDiff()` computing minimal deltas between cells.
- **The Zig DOOM-fire uses pre-computed `fg[color]`/`bg[color]` arrays** — simpler and faster for the fixed-palette fire case, just memcpy instead of formatting.
- **xray's `diff_sgr()` resets + re-emits on any color change** — no incremental SGR optimization. For fire where both fg and bg change frequently, this means a full reset per pixel.
- **`swap()` copies ALL cells every frame** — O(width×height) regardless of how few changed. Potential optimization target.
- **C3 supports default function arguments** — discovered during tick() refactoring.
- **C3 doesn't support function overloading** — had to use default params instead.
