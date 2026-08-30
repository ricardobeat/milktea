# 0001: Bulk memcpy for cell view transfers

## Context

When rendering cell-backed views (`new_alt_cell_view`), `render_current_view` copies cells from the view slice (`v.cells`) into the renderer screen buffer (`r.screen.cells`) before running the diff pass and swapping buffers.

Previously, this transfer ran as a nested 2D loop calling `set_cell()` per cell:

```c3
for (sz row = 0; row < rows; row++) {
    for (sz col = 0; col < cols; col++) {
        xray::Cell c = v.cells[row * v.cells_width + col];
        if (prev_wide) {
            r.screen.put_raw_cell(col, row, c);
            prev_wide = false;
        } else {
            r.screen.set_cell(col, row, c);
            prev_wide = c.width == 2;
        }
    }
}
```

This introduced significant overhead per cell: coordinate bounds checking, branch checks for color blending and transparency, wide-glyph neighbor splitting, struct equality comparisons, and individual writes.

## Direct Pointer Swap vs Bulk Copy

We evaluated zero-copy pointer swapping (`r.screen.cells = v.cells`), but direct buffer adoption introduces complications:
1. **Buffer ownership**: `ScreenBuffer.resize()` and `destroy()` call `mem::free(self.cells.ptr)`. Borrowing external or temp-allocated (`@pool()`) pointers causes double-frees or invalid frees unless lifetime tracking is redesigned.
2. **Overlay mutations**: Overlays (e.g. shadows and alpha blends) render directly onto `r.screen.cells`. Mutating borrowed buffers would alter the model's canvas in-place.

Replacing the per-cell loop with vectorized `mem::copy` preserves buffer ownership and safety while eliminating the per-cell dispatch overhead.

## Implementation

`render_current_view` now uses bulk memory copying:
- **Matching dimensions**: Single contiguous `mem::copy` for the entire buffer (`rows * cols * Cell::size`).
- **Differing dimensions**: Row-strided `mem::copy` per row (`cols * Cell::size`) with right-side padding.
- **Dirty flags**: `r.screen.dirty_lines` marked dirty per row copied.
- **Trailing space**: Uncovered bottom rows cleared via `r.screen.clear_range()`.

## Benchmark Results

Measured with `bench/bench_draw.c3` on a 120x40 grid (4,800 cells, 29 bytes/cell, 135 KB/buffer, 5,000 iterations):

| Operation | Time / Frame | Bandwidth | Notes |
|---|---|---|---|
| Transfer: `set_cell` loop | 28.6 µs | 4.87 GB/s | Baseline per-cell transfer |
| Transfer: bulk `mem::copy` | 2.5 µs | 55.99 GB/s | **11.4× faster**, cache-bandwidth saturated |
| Swap: full `mem::copy` | 2.7 µs | 51.91 GB/s | Current full buffer swap |
| Swap: 10% dirty rows | 0.2 µs | 83.45 GB/s | Incremental dirty swap |
| Swap: pointer swap | 0.0 µs | N/A | Zero-copy pointer exchange |
