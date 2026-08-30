module bench_draw;
import xray;
import std::io;
import std::core::mem;

extern fn long clock();

fn long now_us() @local {
	return (long)clock();
}

const int W = 120;
const int H = 40;
const int ITERS = 5000;
const sz TOTAL = W * H;

fn void bench_cell_copy() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);

	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		for (int r = 0; r < H; r++) {
			sz row_base = (sz)r * (sz)W;
			for (sz ci = 0; ci < W; ci++) {
				xray::Cell cell;
				cell.content[0] = (char)0xe2;
				cell.content[1] = (char)0x96;
				cell.content[2] = (char)0x80;
				cell.content_len = 3;
				cell.width = 1;
				cell.style.fg = { .kind = xray::ColorKind.TRUECOLOR, .r = (char)(ci * 3), .g = (char)(r * 5), .b = (char)iter };
				cell.style.bg = { .kind = xray::ColorKind.TRUECOLOR, .r = (char)ci, .g = (char)r, .b = 0 };
				screen.cells[row_base + ci] = cell;
			}
		}
	}
	long t1 = now_us();
	double us_per_iter = (double)(t1 - t0) / (double)ITERS;
	io::printfn("cell_copy (write):     %6.1fus/frame (%d iters)", us_per_iter, ITERS);
	screen.destroy();
	mem::free(screen);
}

// Benchmark 1: Current transfer path (element-by-element with set_cell logic)
fn void bench_transfer_set_cell() {
	xray::ScreenBuffer* user_buf = xray::new_screen_buffer((sz)W, (sz)H);
	xray::ScreenBuffer* renderer_buf = xray::new_screen_buffer((sz)W, (sz)H);
	defer {
		user_buf.destroy();
		mem::free(user_buf);
		renderer_buf.destroy();
		mem::free(renderer_buf);
	}

	// Populate user buffer
	for (sz i = 0; i < TOTAL; i++) {
		user_buf.cells[i] = xray::new_cell("A", 1, xray::default_style());
	}

	sz total_bytes = TOTAL * xray::Cell::size;
	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		sz cols = (sz)W;
		sz rows = (sz)H;
		for (sz row = 0; row < rows; row++) {
			bool prev_wide = false;
			for (sz col = 0; col < cols; col++) {
				xray::Cell c = user_buf.cells[row * cols + col];
				if (prev_wide) {
					renderer_buf.put_raw_cell(col, row, c);
					prev_wide = false;
				} else {
					renderer_buf.set_cell(col, row, c);
					prev_wide = c.width == 2;
				}
			}
		}
	}
	long t1 = now_us();
	long elapsed_us = t1 - t0;
	if (elapsed_us <= 0) elapsed_us = 1;
	double us_per_frame = (double)elapsed_us / (double)ITERS;
	double total_gb = (double)(ITERS * total_bytes) / 1e9;
	double sec = (double)elapsed_us / 1e6;
	double bandwidth_gb_s = total_gb / sec;

	io::printfn("Transfer: set_cell loop:   %6.1fus/frame | Bandwidth: %6.2f GB/s | Total: %dms",
		us_per_frame, bandwidth_gb_s, (int)(elapsed_us / 1000));
}

// Benchmark 2: Bulk memcpy transfer path
fn void bench_transfer_bulk_memcpy() {
	xray::ScreenBuffer* user_buf = xray::new_screen_buffer((sz)W, (sz)H);
	xray::ScreenBuffer* renderer_buf = xray::new_screen_buffer((sz)W, (sz)H);
	defer {
		user_buf.destroy();
		mem::free(user_buf);
		renderer_buf.destroy();
		mem::free(renderer_buf);
	}

	// Populate user buffer
	for (sz i = 0; i < TOTAL; i++) {
		user_buf.cells[i] = xray::new_cell("A", 1, xray::default_style());
	}

	sz total_bytes = TOTAL * xray::Cell::size;
	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		sz rows = (sz)H;
		mem::copy(renderer_buf.cells.ptr, user_buf.cells.ptr, total_bytes);
		for (sz r = 0; r < rows; r++) {
			renderer_buf.dirty_lines[r] = true;
		}
	}
	long t1 = now_us();
	long elapsed_us = t1 - t0;
	if (elapsed_us <= 0) elapsed_us = 1;
	double us_per_frame = (double)elapsed_us / (double)ITERS;
	double total_gb = (double)(ITERS * total_bytes) / 1e9;
	double sec = (double)elapsed_us / 1e6;
	double bandwidth_gb_s = total_gb / sec;

	io::printfn("Transfer: bulk mem::copy:  %6.1fus/frame | Bandwidth: %6.2f GB/s | Total: %dms",
		us_per_frame, bandwidth_gb_s, (int)(elapsed_us / 1000));
}

// Benchmark 3: ScreenBuffer.swap (Full copy)
fn void bench_swap_full_copy() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);
	defer {
		screen.destroy();
		mem::free(screen);
	}

	sz total_bytes = TOTAL * xray::Cell::size;
	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		screen.swap();
	}
	long t1 = now_us();
	long elapsed_us = t1 - t0;
	if (elapsed_us <= 0) elapsed_us = 1;
	double us_per_frame = (double)elapsed_us / (double)ITERS;
	double total_gb = (double)(ITERS * total_bytes) / 1e9;
	double sec = (double)elapsed_us / 1e6;
	double bandwidth_gb_s = total_gb / sec;

	io::printfn("Swap: full mem::copy:      %6.1fus/frame | Bandwidth: %6.2f GB/s | Total: %dms",
		us_per_frame, bandwidth_gb_s, (int)(elapsed_us / 1000));
}

// Benchmark 4: ScreenBuffer.swap (Dirty lines only - e.g. 10% dirty)
fn void bench_swap_dirty_lines() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);
	defer {
		screen.destroy();
		mem::free(screen);
	}

	sz row_bytes = (sz)W * xray::Cell::size;
	sz dirty_count = (sz)H / 10;
	if (dirty_count < 1) dirty_count = 1;
	sz copied_bytes = dirty_count * row_bytes;

	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		// Mark 10% rows dirty
		for (sz r = 0; r < dirty_count; r++) {
			screen.dirty_lines[r] = true;
		}
		// Dirty copy
		for (sz r = 0; r < (sz)H; r++) {
			if (screen.dirty_lines[r]) {
				mem::copy(screen.prev_cells.ptr + r * (sz)W, screen.cells.ptr + r * (sz)W, row_bytes);
				screen.dirty_lines[r] = false;
			}
		}
	}
	long t1 = now_us();
	long elapsed_us = t1 - t0;
	if (elapsed_us <= 0) elapsed_us = 1;
	double us_per_frame = (double)elapsed_us / (double)ITERS;
	double total_gb = (double)(ITERS * copied_bytes) / 1e9;
	double sec = (double)elapsed_us / 1e6;
	double bandwidth_gb_s = total_gb / sec;

	io::printfn("Swap: 10%% dirty rows:     %6.1fus/frame | Bandwidth: %6.2f GB/s | Total: %dms",
		us_per_frame, bandwidth_gb_s, (int)(elapsed_us / 1000));
}

// Benchmark 5: ScreenBuffer.swap (Pointer swap)
fn void bench_swap_pointer() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);
	defer {
		screen.destroy();
		mem::free(screen);
	}

	long t0 = now_us();
	for (int iter = 0; iter < ITERS; iter++) {
		xray::Cell[] tmp = screen.cells;
		screen.cells = screen.prev_cells;
		screen.prev_cells = tmp;
		mem::set(screen.dirty_lines.ptr, 0, (sz)H * bool::size);
		screen.full_redraw = false;
	}
	long t1 = now_us();
	long elapsed_us = t1 - t0;
	if (elapsed_us <= 0) elapsed_us = 1;
	double us_per_frame = (double)elapsed_us / (double)ITERS;

	io::printfn("Swap: pointer swap:        %6.1fus/frame | (zero copy)          | Total: %dms",
		us_per_frame, (int)(elapsed_us / 1000));
}

fn int main(String[] args) {
	io::printfn("=== ScreenBuffer & Cell Transfer Microbenchmark ===");
	io::printfn("Grid: %dx%d (%d cells, %d bytes/cell, %d KB/buffer) | Iterations: %d",
		W, H, (int)TOTAL, (int)xray::Cell::size, (int)(TOTAL * xray::Cell::size / 1024), ITERS);
	io::printfn("----------------------------------------------------------------------");
	bench_cell_copy();
	io::printfn("--- Transfer to Renderer Buffer (View.cells -> ScreenBuffer.cells) ---");
	bench_transfer_set_cell();
	bench_transfer_bulk_memcpy();
	io::printfn("--- Buffer Swap (ScreenBuffer.swap) ----------------------------------");
	bench_swap_full_copy();
	bench_swap_dirty_lines();
	bench_swap_pointer();
	io::printfn("======================================================================");
	return 0;
}
