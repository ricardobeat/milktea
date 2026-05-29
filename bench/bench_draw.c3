module bench_draw;
import xray;
import std::io;
import std::core::mem;

extern fn long clock();

fn long now_ms() @local {
	return (long)clock() / 1000;
}

const int W = 80;
const int H = 48;
const int ITERS = 200;
const sz TOTAL = W * H;

fn void bench_cell_copy() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);

	long t0 = now_ms();
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
	long t1 = now_ms();
	io::printfn("cell_copy:   %dms  (%d iters × %d cells)", t1 - t0, ITERS, (int)TOTAL);
	screen.destroy();
	mem::free(screen);
}

fn void bench_cell_direct() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);

	long t0 = now_ms();
	for (int iter = 0; iter < ITERS; iter++) {
		for (int r = 0; r < H; r++) {
			sz row_base = (sz)r * (sz)W;
			for (sz ci = 0; ci < W; ci++) {
				xray::Cell* dst = &screen.cells[row_base + ci];
				dst.content[0] = (char)0xe2;
				dst.content[1] = (char)0x96;
				dst.content[2] = (char)0x80;
				dst.content_len = 3;
				dst.width = 1;
				dst.style.fg = { .kind = xray::ColorKind.TRUECOLOR, .r = (char)(ci * 3), .g = (char)(r * 5), .b = (char)iter };
				dst.style.bg = { .kind = xray::ColorKind.TRUECOLOR, .r = (char)ci, .g = (char)r, .b = 0 };
			}
		}
	}
	long t1 = now_ms();
	io::printfn("cell_direct: %dms  (%d iters × %d cells)", t1 - t0, ITERS, (int)TOTAL);
	screen.destroy();
	mem::free(screen);
}

fn void bench_cache_store() {
	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)W, (sz)H);

	for (int r = 0; r < H; r++) {
		sz row_base = (sz)r * (sz)W;
		for (sz ci = 0; ci < W; ci++) {
			xray::Cell* dst = &screen.cells[row_base + ci];
			dst.content[0] = (char)0xe2;
			dst.content_len = 1;
			dst.width = 1;
			dst.style.fg = { .kind = xray::ColorKind.TRUECOLOR, .r = (char)ci, .g = (char)r, .b = 0 };
		}
	}

	xray::Cell* cache = mem::new_array(xray::Cell, TOTAL);
	defer mem::free(cache);

	long t0 = now_ms();
	for (int iter = 0; iter < ITERS; iter++) {
		for (sz i = 0; i < TOTAL; i++) {
			cache[i] = screen.cells[i];
		}
	}
	long t1 = now_ms();
	io::printfn("cache_elem:  %dms  (%d iters × %d cells)", t1 - t0, ITERS, (int)TOTAL);

	long t2 = now_ms();
	for (int iter = 0; iter < ITERS; iter++) {
		sz bytes = TOTAL * xray::Cell::size;
		mem::copy(cache, &screen.cells[0], bytes);
	}
	long t3 = now_ms();
	io::printfn("cache_bulk:  %dms  (%d iters × %d cells, memcopy)", t3 - t2, ITERS, (int)TOTAL);

	screen.destroy();
	mem::free(screen);
}

fn int main(String[] args) {
	io::printfn("bench: %dx%d screen, %d iterations", W, H, ITERS);
	bench_cell_copy();
	bench_cell_direct();
	bench_cache_store();
	return 0;
}
