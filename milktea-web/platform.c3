module milktea @feat(MILKTEA_WEB);

// Browser imports. Monotonic time starts at instantiation, fitting wasm32 sz.
extern fn double web_now_ms() @wasm("milktea", "now");
extern fn double web_wall_ms() @wasm("milktea", "wall");
extern fn void web_log(char* ptr, sz len) @wasm("milktea", "log");
fn sz time_ms() => (sz)web_now_ms();
fn sz wall_time_ms() => (sz)(web_wall_ms() % 2147483647.0);
fn void write_stdout(char[] bytes) { web_log(bytes.ptr, bytes.len); }

struct WinSize {
	ushort ws_row, ws_col, ws_xpixel, ws_ypixel;
	ushort cell_w_px, cell_h_px;
	bool cell_px_known;
}
fn WinSize get_window_size() => g_program ? g_program.cached_ws : (WinSize){ .ws_col = 80, .ws_row = 24 };

sz g_cell_w_px = 10;
sz g_cell_h_px = 20;
bool g_cell_px_known = true;
bool g_tgp_replied;
int g_term_bg_r;
int g_term_bg_g;
int g_term_bg_b;
bool g_term_bg_known;
fn void report_cell_size_reply(sz h, sz w) @private {}
extern fn char* getenv(char* name);
// Existing examples call these shim names directly.
extern fn double c3_sin(double x);
extern fn double c3_cos(double x);
extern fn long c3_time_ms_long();
extern fn int rand();
extern fn void srand(uint seed);
alias CleanupFn = fn void();
CleanupFn web_cleanup;
fn void register_cleanup(CleanupFn cb) { web_cleanup = cb; }
