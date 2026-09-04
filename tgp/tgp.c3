module tgp;

// Kitty Graphics Protocol (KGP) for milktea TUIs: register glyphs (animated
// RGBA images), then draw them either as text (unicode placeholder cells) or
// at absolute screen coordinates (terminal placements).
//
// Capability is discovered by milktea's startup probe (a=q), never by
// sniffing TERM/TERM_PROGRAM. When the terminal does not support KGP, text
// draws degrade to the glyph's fallback string and placements become no-ops.
//
// Everything goes through milktea::emit, so escapes share the renderer's tty
// path (and the test-mode capture buffer). Image ids are auto-assigned per
// run — no cross-run collisions — and a blanket delete runs on every exit
// path (normal teardown and fatal signals), so tiles never outlive the app.
//
// Usage:
//   struct Model { tgp::Session gfx; tgp::Glyph spin; }
//   init:    self.spin = self.gfx.register({ .draw = &gen_spin, .count = 8,
//                .width = 32, .height = 64, .fps = 12, .fallback = "◌" })!!;
//   update:  self.gfx.tick();                 // advances clock + reconciles
//   view:    content.append(self.spin.render());
//   destroy: self.gfx.destroy();
//
// Registration is lazy: frames are transmitted on the first tick/place call
// after the alt screen is active (images are tied to the screen they
// were sent on — transmitting earlier would lose them at the 1049h switch).

import milktea;
import std::core::string;
import std::core::dstring;
import std::core::mem;

faultdef SESSION_FULL, INVALID_GLYPH, NO_SUCH_INSTANCE;

const sz MAX_GLYPHS = 32;
const sz MAX_INSTANCES = 128;
// Base64 payload bytes per transmission chunk. MUST stay a multiple of 4:
// the protocol requires every chunk except the last to be, since 4 base64
// characters encode one 3-byte group and a split mid-group corrupts the
// image. 4096 is the protocol's recommended maximum.
const sz CHUNK = 4096;
const uint PLACEHOLDER_CP = 0x10EEEE;
const int B64_CHUNK = 3; // bytes per base64 group

// DrawFn renders one animation frame into an RGBA8 buffer of
// width*height*4 bytes. Set GlyphDef.draw for procedural glyphs.
alias DrawFn = fn void(char* buf, int frame);

// Sink receives escape sequences; tests install one to capture output.
alias Sink = fn void(String escape);

struct GlyphDef {
	DrawFn draw;
	// Pre-rendered frames: count * width * height * 4 bytes of RGBA8. When
	// set, draw is ignored.
	char[] frames;
	int count;
	int width;
	int height;
	// Animation rate in frames per second; 0 = static (frame 0 only).
	int fps;
	// Shown when the terminal has no kitty-graphics support.
	String fallback;
}

// Glyph is a value handle bound to the session that registered it: render()
// and place() go through that session's clock, capability state and output
// sink. The session pointer is a borrow — the session (typically a model
// field) must outlive the glyph, which holds naturally since registration
// happens in init() and milktea models are used via pointer, never moved
// while a program runs. Do not copy a model after init().
struct Glyph {
	Session* session;
	uint base_id;
	int count;
	int width;
	int height;
	int fps;
	String fallback;
}

// Identifies a placement within a session, for move/remove.
alias InstId = int;
const InstId NO_INSTANCE = -1;

struct Placement {
	bool active;
	int glyph;
	int col;
	int row;
	// Terminal-side state, tracked for the diff in sync():
	bool shown;
	int shown_col;
	int shown_row;
	int frame;
	uint pid;
}

struct Session {
	uint next_id;
	Glyph[MAX_GLYPHS] glyphs;
	GlyphDef[MAX_GLYPHS] defs;
	bool[MAX_GLYPHS] transmitted;
	int glyph_count;
	Placement[MAX_INSTANCES] placements;
	int placement_count;
	uint next_pid;
	sz born_ms;
	sz clock_ms;
}

// ---- Output plumbing ----

Sink g_test_sink = null;

// Test hook: forces the "supported" query so placement/diff logic can be
// exercised without a kitty-graphics terminal.
bool g_forced_supported = false;

fn void set_supported_override(bool on) {
	g_forced_supported = on;
}

fn bool supported() {
	return g_forced_supported || milktea::kitty_graphics_supported();
}

// set_sink installs a capture sink for tests; null restores milktea::emit.
fn void set_sink(Sink s) {
	g_test_sink = s;
}

fn void emit(String escape) {
	if (g_test_sink != null) {
		g_test_sink(escape);
		return;
	}
	milktea::emit(escape);
}

// ---- Session lifecycle ----

// The exit cleanup is a plain fn pointer (no captures): it emits a blanket
// a=d,d=A, deleting every image and placement the terminal holds. Runs on
// fatal signals too, so tiles never outlive a crashed app.
bool g_cleanup_registered = false;

fn void tgp_cleanup_all() {
	// Async-signal-safe: constant string, write loop only.
	emit("\x1b_Ga=d,d=A,q=2\x1b\\");
}

fn Session new_session() {
	if (!g_cleanup_registered) {
		milktea::register_cleanup(&tgp_cleanup_all);
		g_cleanup_registered = true;
	}
	Session s = { };
	// Auto-assigned ids unique per run: seed from the monotonic clock so a
	// quick restart cannot collide with ids the terminal still holds.
	s.next_id = ((uint)(milktea::monotonic_ms() % 1024) * 4096) + 4096;
	s.born_ms = milktea::monotonic_ms();
	s.next_pid = 1;
	return s;
}

// destroy deletes every image this session transmitted (and their
// placements). Calling it from on_destroy is polite but optional: the
// registered blanket cleanup runs at teardown regardless.
fn void Session.destroy(&self) {
	if (!supported()) return;
	for (int g = 0; g < self.glyph_count; g++) {
		if (!self.transmitted[g]) continue;
		Glyph gl = self.glyphs[g];
		for (int f = 0; f < gl.count; f++) {
			emit(string::tformat("\x1b_Ga=d,d=I,i=%d,q=2\x1b\\", gl.base_id + (uint)f));
		}
		self.transmitted[g] = false;
	}
	for (int p = 0; p < self.placement_count; p++) {
		self.placements[p].shown = false;
	}
}

// ---- Registration ----

fn Glyph? Session.register(&self, GlyphDef def) {
	if (def.width <= 0 || def.height <= 0 || def.count <= 0) return INVALID_GLYPH~;
	if (def.draw == null && def.frames.len == 0) return INVALID_GLYPH~;
	if (self.glyph_count >= MAX_GLYPHS) return SESSION_FULL~;

	int idx = self.glyph_count++;
	Glyph g = {
		.session = self,
		.base_id = self.next_id,
		.count = def.count,
		.width = def.width,
		.height = def.height,
		.fps = def.fps,
		.fallback = def.fallback,
	};
	self.next_id += (uint)def.count;
	self.glyphs[idx] = g;
	self.defs[idx] = def;
	self.transmitted[idx] = false;
	return g;
}

// ---- Animation clock ----

// tick advances the session clock to now, transmits anything pending, and
// reconciles placements. Call it from update() on every animation message
// (it is idempotent and emits nothing when nothing changed).
fn void Session.tick(&self) {
	self.clock_ms = milktea::monotonic_ms() - self.born_ms;
	self.flush();
	self.sync();
}

// glyph_frame derives the current frame of a glyph from the clock: a pure
// function of elapsed time, so view() stays side-effect free and every
// glyph drawn in one frame agrees on the frame index.
fn int glyph_frame(int fps, int count, sz clock_ms) {
	if (fps <= 0 || count <= 0) return 0;
	return (int)((clock_ms * (sz)fps / 1000) % (sz)count);
}

fn int Session.frame_of(&self, Glyph g) {
	return glyph_frame(g.fps, g.count, self.clock_ms);
}

// ---- Transmission ----

fn String base64_encode(char[] input) {
	const String B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	DString out = dstring::temp();

	sz i = 0;
	while (i < input.len) {
		sz remaining = input.len - i;
		int b0 = (int)input[i] & 0xff;
		int b1 = remaining > 1 ? ((int)input[i + 1] & 0xff) : 0;
		int b2 = remaining > 2 ? ((int)input[i + 2] & 0xff) : 0;

		out.append_char(B64[(b0 >> 2) & 0x3f]);
		out.append_char(B64[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)]);
		out.append_char(remaining > 1 ? B64[((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)] : '=');
		out.append_char(remaining > 2 ? B64[b2 & 0x3f] : '=');

		i += 3;
	}

	return out.str_view();
}

fn void base64_emit_chunks(uint id, char[] rgba, int w, int h) {
	String b64 = base64_encode(rgba);
	DString cmd = dstring::temp();

	sz pos = 0;
	bool first = true;
	while (pos < b64.len) {
		sz n = b64.len - pos;
		if (n > CHUNK) n = CHUNK;
		bool more = pos + n < b64.len;
		if (first) {
			cmd.append_string(string::tformat(
				"\x1b_Ga=t,f=32,q=2,i=%d,s=%d,v=%d,m=%d;", id, w, h, more ? 1 : 0));
		} else {
			cmd.append_string(string::tformat("\x1b_Gm=%d;", more ? 1 : 0));
		}
		cmd.append_string(b64[pos:n]);
		cmd.append_string("\x1b\\");
		pos += n;
		first = false;
	}

	emit(cmd.str_view());
}

// transmit_glyph sends every frame of an untransmitted glyph. After the raw
// frames, one 1x1 virtual placement (U=1) is registered per image: ghostty
// does not create implicit virtual placements when a placeholder cell is
// printed (kitty does), and without it placeholders render as tofu there.
fn void Session.transmit_glyph(&self, int idx) {
	GlyphDef* def = &self.defs[idx];
	sz bytes = (sz)(def.width * def.height * 4);
	Glyph g = self.glyphs[idx];

	char* scratch = mem::new_array(char, bytes);
	defer mem::free(scratch);

	for (int f = 0; f < g.count; f++) {
		if (def.frames.len > 0) {
			sz start = (sz)f * bytes;
			base64_emit_chunks(g.base_id + (uint)f, def.frames[start:bytes], def.width, def.height);
		} else {
			for (sz i = 0; i < bytes; i++) scratch[i] = 0;
			def.draw(scratch, f);
			base64_emit_chunks(g.base_id + (uint)f, scratch[:bytes], def.width, def.height);
		}
		emit(string::tformat("\x1b_Ga=p,i=%d,U=1,q=2,c=1,r=1\x1b\\", g.base_id + (uint)f));
	}

	self.transmitted[idx] = true;
}

fn bool Session.flush(&self) {
	if (!supported()) return false;
	// Images are tied to the screen they were transmitted on; defer until
	// the alt screen is active so a 1049h switch cannot drop them.
	if (!milktea::in_alt_screen()) return false;

	bool sent = false;
	for (int i = 0; i < self.glyph_count; i++) {
		if (self.transmitted[i]) continue;
		@pool() {
			self.transmit_glyph(i);
		};
		sent = true;
	}
	return sent;
}

// ---- Inline drawing (unicode placeholders) ----

// Row/column diacritics for placeholder cells. A placeholder cell that
// carries no diacritics inherits its row from the cell to its left and
// INCREMENTS the column, so N identical cells resolve to columns 0..N-1 of
// the image. Each tile is a 1x1 image, so only column 0 exists and every
// cell after the first would render empty. Stamping an explicit
// (row 0, col 0) on every cell pins them all to the image's only cell.
const uint DIACRITIC_0 = 0x0305; // encodes row/column index 0

// placeholder_run encodes one image id across n consecutive cells, all
// resolving to the image's cell (0, 0). The id-carrying foreground color is
// set once for the whole run and reset at the end: a terminal joins adjacent
// placeholder cells into one run only while that color stays set, so
// repeating a self-resetting single-cell placeholder breaks the run apart.
fn String placeholder_run(uint id, int n) {
	if (n <= 0) return "";
	char[4] cp;
	sz cp_len = milktea::utf8_encode(PLACEHOLDER_CP, cp[..]);
	char[4] d0;
	sz d0_len = milktea::utf8_encode(DIACRITIC_0, d0[..]);
	DString d = dstring::temp();
	d.append_string(string::tformat(
		"\x1b[38;2;%d;%d;%dm", (id >> 16) & 0xff, (id >> 8) & 0xff, id & 0xff));
	for (int i = 0; i < n; i++) {
		d.append_string((String)cp[:cp_len]);
		// row 0, then column 0 -- explicit, so nothing is inherited.
		d.append_string((String)d0[:d0_len]);
		d.append_string((String)d0[:d0_len]);
	}
	d.append_string("\x1b[39m");
	return d.str_view();
}

// placeholder_string encodes one image id as a single placeholder cell.
// Shorthand for placeholder_run(id, 1) -- one encoder, so the diacritic
// rules cannot drift between the single-cell and run cases.
fn String placeholder_string(uint id) {
	return placeholder_run(id, 1);
}

// placeholder returns the escape sequence that draws the glyph's current
// frame in the next text cell, or the glyph's fallback when the terminal has
// no kitty graphics. The result is temp-allocated: valid within the caller's
// @pool scope (i.e. inside view()). Prefer the Glyph.render() sugar — a glyph
// is bound to the session that registered it, so it can render itself.
fn String Session.placeholder(&self, Glyph g) {
	if (!supported() || g.count <= 0) return g.fallback;
	self.flush();
	uint img = g.base_id + (uint)self.frame_of(g);
	return placeholder_string(img);
}

// render draws the glyph's current frame in the next text cell (or its
// fallback string on terminals without kitty graphics). Shorthand for
// session.placeholder(self) — see Glyph for the borrowing contract.
fn String Glyph.render(&self) {
	return self.session.placeholder(*self);
}

// place registers an absolute placement of the glyph at a cell coordinate;
// see Session.place(). The placement reaches the terminal on the next
// session tick(). Returns the instance id for move/remove, or NO_INSTANCE.
fn InstId Glyph.place(&self, int col, int row) {
	return self.session.place(*self, col, row);
}

// ---- Absolute placements ----

// place registers an instance of a glyph at a cell coordinate. The placement
// reaches the terminal on the next tick()/sync(). Returns the instance id
// for move/remove, or NO_INSTANCE if the session is full or the glyph is
// unknown.
fn InstId Session.place(&self, Glyph g, int col, int row) {
	if (!supported()) return NO_INSTANCE;
	int glyph_idx = -1;	for (int i = 0; i < self.glyph_count; i++) {
		if (self.glyphs[i].base_id == g.base_id) {
			glyph_idx = i;
			break;
		}
	}
	if (glyph_idx < 0) return NO_INSTANCE;
	if (self.placement_count >= MAX_INSTANCES) return NO_INSTANCE;

	int pid_idx = self.placement_count++;
	self.placements[pid_idx] = {
		.active = true,
		.glyph = glyph_idx,
		.col = col,
		.row = row,
		.shown = false,
		.frame = 0,
		.pid = self.next_pid++,
	};
	return pid_idx;
}

fn void Session.move(&self, InstId id, int col, int row) {
	if (id < 0 || id >= self.placement_count) return;
	if (!self.placements[id].active) return;
	self.placements[id].col = col;
	self.placements[id].row = row;
}

fn void Session.remove(&self, InstId id) {
	if (id < 0 || id >= self.placement_count) return;
	self.placements[id].active = false;
}

// sync diffs the desired placements against what the terminal shows and
// reconciles the terminal to match. Driven by tick(); emits nothing when
// nothing changed.
//
// Positioning: a placement renders at the CURRENT CURSOR POSITION. The
// uppercase X/Y keys are pixel offsets *within* that cell, not screen
// coordinates -- so the cursor is moved with CSI row;col H first and X/Y are
// left off entirely.
//
// Replacement: sending a=p whose image id and placement id are both already
// on screen replaces that placement in place, with no flicker and no delete
// first. An animated glyph changes image id per frame, though, so a frame
// change is a *different* image id under the same placement id, which does
// NOT replace -- that case deletes the old frame's placement explicitly.
// Deleting one placement is d=i with both i= and p=; d=p/d=P deletes by cell
// via x/y and is not what this wants.
fn void Session.sync(&self) {
	if (!supported()) return;
	self.flush();

	for (int p = 0; p < self.placement_count; p++) {
		Placement place = self.placements[p];
		Glyph g = self.glyphs[place.glyph];
		int frame = self.frame_of(g);

		if (!place.active) {
			if (place.shown) {
				emit(string::tformat(
					"\x1b_Ga=d,d=i,i=%d,p=%d,q=2\x1b\\", g.base_id + (uint)place.frame, place.pid));
				self.placements[p].shown = false;
			}
			continue;
		}

		bool unchanged = place.shown && place.frame == frame
			&& place.shown_col == place.col && place.shown_row == place.row;
		if (unchanged) continue;

		// Only a frame change needs the old placement gone: a same-image move
		// is handled by replacement, which avoids a delete/put flicker.
		if (place.shown && place.frame != frame) {
			emit(string::tformat(
				"\x1b_Ga=d,d=i,i=%d,p=%d,q=2\x1b\\", g.base_id + (uint)place.frame, place.pid));
		}
		// Move the cursor to the target cell, then place there. c/r are
		// omitted: the terminal then displays the image at its natural pixel
		// size, which keeps the aspect ratio right without knowing the cell's
		// pixel dimensions.
		emit(string::tformat("\x1b[%d;%dH", place.row + 1, place.col + 1));
		emit(string::tformat(
			"\x1b_Ga=p,i=%d,p=%d,q=2\x1b\\", g.base_id + (uint)frame, place.pid));
		self.placements[p].shown = true;
		self.placements[p].shown_col = place.col;
		self.placements[p].shown_row = place.row;
		self.placements[p].frame = frame;
	}
}
