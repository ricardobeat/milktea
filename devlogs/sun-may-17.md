# Wolf3D Server - Sun May 17, 2025

## Summary

Added major features to the Wolf3D server: NAWS terminal size negotiation, tag stacking with author display, random spawn position, welcome screen, and improved rendering.

## Changes

### 1. NAWS Terminal Size Negotiation

**Problem**: Server rendered at fixed 80x24 but clients could have different terminal sizes, causing the right 1/3 of the screen to show leftover content.

**Solution**: Implemented Telnet NAWS (Negotiate About Window Size) support:

```c3
// Telnet option codes
const char TELNET_IAC = 255;
const char TELNET_SB = 250;
const char TELNET_SE = 240;
const char TELNET_NAWS = 31;  // Negotiate About Window Size

fn bool wait_for_naws(TcpSocket* s, int* out_w, int* out_h) {
    // Parse IAC SB NAWS <w_hi> <w_lo> <h_hi> <h_lo> IAC SE
    // ...timeout handling and byte parsing...
}
```

In `handle_client()`:
- Send `IAC DO NAWS` after telnet negotiation
- Wait for response (500ms timeout)
- Reallocate buffers if size differs from default

### 2. Tag Stacking System

**Changes to `Tag` struct**:
```c3
struct Tag {
    int id;
    int wall_x, wall_y;
    int side;
    int tag_offset; // vertical stack offset (0 = first tag at this location)
    char[80] text;
    sz text_len;
    char[32] author;
    sz author_len;
}
```

**Database schema updated**:
```sql
CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    wall_x INTEGER NOT NULL, wall_y INTEGER NOT NULL,
    side INTEGER NOT NULL,
    tag_offset INTEGER NOT NULL DEFAULT 0,
    text TEXT NOT NULL, author TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
```

**New function `db_get_tag_count_at()`**: Counts existing tags at a location to assign offset.

**Rendering changes**: Tags now appear at exact wall center, stacked vertically by offset.

### 3. Author Display

Each tag now renders with author attribution:
- Message line in cyan (0, 255, 255)
- Author line `- [name]` in gray (150, 150, 150) below

### 4. Random Spawn Position

New `init()` logic picks a random open cell and faces away from the nearest wall:

```c3
// Find all open spaces and pick a random one
int[256] open_spaces;
for (int y = 1; y < MAP_HEIGHT - 1; y++) {
    for (int x = 1; x < MAP_WIDTH - 1; x++) {
        if (MAP[y * MAP_WIDTH + x] == 0) {
            open_spaces[open_count++] = y * MAP_WIDTH + x;
        }
    }
}
int idx = open_spaces[rand(open_count)];

// Face away from wall
bool wall_n = (my > 0 && MAP[(my - 1) * MAP_WIDTH + mx] > 0);
// ...check all 4 directions and set direction vector...
```

### 5. Welcome Screen

Added `WELCOME` mode with:
- **Twinkling star background** - pseudo-random based on position + tick_count
- **Dark purple dialog box** with:
  - Shadow offset (2 chars right)
  - Double border (outer `+-|` in lighter purple, inner `+:='` in darker)
  - Title " WELCOME TO THE VOID " in light purple
  - Name input prompt
  - `[ Enter the Void ]` button (inactive until name entered)

New Mode enum:
```c3
enum Mode {
    PLAYING,
    ENTERING_NAME,
    TAG_INPUT,
    WELCOME
}
```

### 6. Help Bar

Added bottom-left corner hint showing available controls:
- `[T] Tag Wall  [Q] Quit` with keys highlighted in cyan

### 7. Wall Color Fix

Changed default wall color from white (255, 255, 255) to brown (128, 80, 80) so text is visible.

## Key Patterns Discovered

### C3 Syntax Gotchas

1. **Variable names cannot start with capital letters**: `char H = '-'` fails, use `char hb = '-'`
2. **If-else braces required**: Even single-statement branches need `{}`:
   ```c3
   if (y == 0 && x == 0) { ch = { tl, '\0' }; }
   else if (y == 0 && x == box_w - 1) { ch = { tr, '\0' }; }
   ```
3. **C-style array syntax not allowed**: `int open_spaces[256]` fails, use `int[256] open_spaces`
4. **rand() requires parameter**: `rand(open_count)` not `rand() % open_count`
5. **No nested structs**: TagSprite struct must be declared outside the view function

### Threading

- `c3_time_ms_long()` available via extern for timestamp-based timeouts
- `thread::sleep_ms()` for delays
- `thread::Mutex` for shared state between player threads

## Files Modified

- `milktea/examples/wolf3d-server/wolf3d-server.c3` - Main changes

## Build Command

```bash
cd milktea && c3c build wolf3d-server
```

## TODO

- [ ] Test welcome screen rendering on various terminal sizes
- [ ] Consider adding a "tag wall" highlight effect when in TAG_INPUT mode
- [ ] Add per-wall unique colors based on map texture ID
- [ ] Implement a simple sprite system for seeing other players on the map