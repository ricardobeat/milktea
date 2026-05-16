module xray;

import std::core::dstring;

// ============================================================
// Renderer — wraps ScreenBuffer with synchronized output (mode 2026)
// and manages the render-to-terminal pipeline.
//
// Usage:
//   Renderer r = new_renderer(width, height, &write_stdout_fn);
//   defer r.destroy();
//   // Each frame:
//   r.begin_frame();
//   // ... write content to r.screen ...
//   r.end_frame();  // diffs + flushes to terminal
// ============================================================

// WriteFn is the signature for the terminal output function.
alias WriteFn = fn void(char[] bytes);

const String SYNC_BEGIN = "\x1b[?2026h";
const String SYNC_END   = "\x1b[?2026l";
const String HIDE_CURSOR_SEQ = "\x1b[?25l";
const String SHOW_CURSOR_SEQ = "\x1b[?25h";

struct Renderer {
	ScreenBuffer* screen;
	WriteFn write_fn;     // function to write bytes to terminal
	Style pen_style;      // current terminal SGR state
	bool sync_supported;  // terminal supports mode 2026
	sz width;
	sz height;
}

// new_renderer creates a new renderer with the given dimensions and output function.
fn Renderer* new_renderer(sz width, sz height, WriteFn write_fn) {
	Renderer* r = mem::new(Renderer);
	r.screen = new_screen_buffer(width, height);
	r.write_fn = write_fn;
	r.pen_style = default_style();
	r.sync_supported = false;
	r.width = width;
	r.height = height;
	return r;
}

// destroy frees all resources.
fn void Renderer.destroy(&self) {
	self.screen.destroy();
	mem::free(self.screen);
}

// resize changes the renderer dimensions.
fn void Renderer.resize(&self, sz width, sz height) {
	self.screen.resize(width, height);
	self.width = width;
	self.height = height;
}

// set_sync_supported enables or disables synchronized output.
fn void Renderer.set_sync_supported(&self, bool supported) {
	self.sync_supported = supported;
}

// clear resets the screen buffer and forces a full redraw.
fn void Renderer.clear(&self) {
	self.screen.clear();
}

// begin_frame starts a new frame. Call before writing to the screen buffer.
fn void Renderer.begin_frame(&self) {
	// No-op: the screen buffer is written directly
}

// end_frame finishes the frame: diffs the screen buffer against the
// previous frame, wraps output in synchronized update if supported,
// and flushes to the terminal.
fn void Renderer.end_frame(&self) {
	if (!self.screen.needs_redraw()) return;

	// Build the diff output
	DString diff_buf = dstring::temp();
	self.screen.render_diff(&diff_buf, &self.pen_style);

	String diff_str = diff_buf.str_view();
	if (diff_str.len == 0) {
		self.screen.swap();
		return;
	}

	// Build the final output with sync wrapping
	DString final = dstring::temp();

	if (self.sync_supported) {
		final.append_string(SYNC_BEGIN);
	}

	final.append_string(HIDE_CURSOR_SEQ);
	final.append_string(diff_str);

	if (self.sync_supported) {
		final.append_string(SYNC_END);
	}

	// Flush to terminal
	self.write_fn((char[])final.str_view());

	// Swap buffers for next frame's diff
	self.screen.swap();
}
