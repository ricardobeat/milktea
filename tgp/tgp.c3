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

// zlib. The protocol accepts a deflate-compressed payload with o=z, which the
// terminal inflates. RGBA tiles are mostly flat fill and smooth ramps, so this
// is worth an order of magnitude on the wire -- measured ~11x on antialiased
// rounded-box tiles, far more on flat ones. Compression is optional: if it
// fails or does not help, the raw bytes go out instead.
extern fn int compress2(char* dest, sz* dest_len, char* src, sz src_len, int level);
const int Z_OK = 0;
const int Z_LEVEL = 6;

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
	// Target size in cells. 0 means "natural size": the terminal shows the
	// image at its own pixel dimensions. Non-zero scales the image to exactly
	// that many columns/rows, which is how a small gradient strip stretches to
	// fill a box of any size -- a resize is then just a replacement placement,
	// with no image data retransmitted.
	int cols;
	int rows;
	// Vertical stacking order. Negative values draw the image UNDER the text
	// layer, so ordinary text written over those cells shows through with the
	// image behind it -- the only way to get text on top of an image, since a
	// unicode-placeholder cell is consumed by the placeholder itself and
	// cannot also carry a glyph. Below Z_UNDER_BG the image also goes under
	// cells with a non-default background.
	int z;
	// Terminal-side state, tracked for the diff in sync():
	bool shown;
	int shown_col;
	int shown_row;
	int shown_z;
	int shown_cols;
	int shown_rows;
	int frame;
	uint pid;
}

// Z_UNDER_TEXT puts an image beneath the text layer while staying above the
// default background: text drawn over it shows through.
const int Z_UNDER_TEXT = -1;
// Z_UNDER_BG additionally puts it under cells that set their own background
// colour (the protocol's INT32_MIN/2 threshold).
const int Z_UNDER_BG = -1073741825;

struct Session {
	uint next_id;
	Glyph[MAX_GLYPHS] glyphs;
	GlyphDef[MAX_GLYPHS] defs;
	bool[MAX_GLYPHS] transmitted;
	// A released slot is reusable by register(); its images are already
	// deleted from the terminal.
	bool[MAX_GLYPHS] freed;
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
	// Reuse a released slot before growing: an app whose glyphs are one point
	// in a style space (radius x border x fill x ...) cycles through far more
	// glyphs than MAX_GLYPHS over a run, but holds only a few at a time.
	int idx = -1;
	for (int i = 0; i < self.glyph_count; i++) {
		if (self.freed[i]) { idx = i; break; }
	}
	if (idx < 0) {
		if (self.glyph_count >= MAX_GLYPHS) return SESSION_FULL~;
		idx = self.glyph_count++;
	}
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
	self.freed[idx] = false;
	return g;
}

// release deletes a glyph's images from the terminal and frees its slot for a
// later register(). Any placement still referencing it must be removed first;
// inline placeholders for it simply stop resolving. Use it when a glyph leaves
// the screen for good -- a style the user navigated away from, say -- rather
// than holding every variant a session ever showed.
fn void Session.release(&self, Glyph g) {
	for (int i = 0; i < self.glyph_count; i++) {
		if (self.glyphs[i].base_id != g.base_id || self.freed[i]) continue;
		if (self.transmitted[i] && supported()) {
			for (int f = 0; f < self.glyphs[i].count; f++) {
				emit(string::tformat(
					"\x1b_Ga=d,d=I,i=%d,q=2\x1b\\", self.glyphs[i].base_id + (uint)f));
			}
		}
		self.transmitted[i] = false;
		self.freed[i] = true;
		return;
	}
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
	// Try deflate first; fall back to raw on any failure or if it does not
	// actually shrink the payload.
	sz cap = rgba.len + rgba.len / 100 + 64;
	char* zbuf = mem::talloc_array(char, cap);
	sz zlen = cap;
	bool compressed = false;
	if (compress2(zbuf, &zlen, &rgba[0], rgba.len, Z_LEVEL) == Z_OK && zlen < rgba.len) {
		compressed = true;
	}

	String b64 = compressed ? base64_encode(zbuf[:zlen]) : base64_encode(rgba);
	DString cmd = dstring::temp();

	sz pos = 0;
	bool first = true;
	while (pos < b64.len) {
		sz n = b64.len - pos;
		if (n > CHUNK) n = CHUNK;
		bool more = pos + n < b64.len;
		if (first) {
			// o=z marks the payload as deflate-compressed; s/v stay the
			// IMAGE dimensions, not the compressed byte count.
			cmd.append_string(compressed
				? string::tformat(
					"\x1b_Ga=t,f=32,o=z,q=2,i=%d,s=%d,v=%d,m=%d;", id, w, h, more ? 1 : 0)
				: string::tformat(
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
		if (self.transmitted[i] || self.freed[i]) continue;
		@pool() {
			self.transmit_glyph(i);
		};
		sent = true;
	}
	return sent;
}

// ---- Inline drawing (unicode placeholders) ----

// Row/column diacritics. The Nth entry encodes the number N; the table is
// kitty's rowcolumn-diacritics.txt (combining class 230, no decomposition
// mappings, so normalization cannot fuse them into the base character).
//
// A placeholder cell is <U+10EEEE><row><column>[<high id byte>]. Omitting the
// diacritics makes a cell inherit its row from the left neighbour and
// INCREMENT the column, which is convenient for a single run but silently
// wrong anywhere else -- so every cell here is explicit.
const uint[297] DIACRITICS = {
	0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
	0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
	0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
	0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
	0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
	0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
	0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
	0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
	0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
	0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
	0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
	0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
	0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
	0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
	0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
	0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
	0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
	0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
	0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
	0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
	0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
	0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
	0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
	0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
	0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
	0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
	0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
	0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
	0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
	0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
	0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
	0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
	0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
	0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
	0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
	0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
	0x1D244,
};

// placeholder_cell encodes one cell of an image: the codepoint, then the
// row and column of the cell within the image's c x r grid. The image id
// travels in the foreground colour, which the caller sets around a run of
// these.
fn void append_placeholder_cell(DString* d, int row, int col) {
	char[4] cp;
	sz cp_len = milktea::utf8_encode(PLACEHOLDER_CP, cp[..]);
	d.append_string((String)cp[:cp_len]);
	char[4] enc;
	sz n = milktea::utf8_encode(DIACRITICS[row % 297], enc[..]);
	d.append_string((String)enc[:n]);
	n = milktea::utf8_encode(DIACRITICS[col % 297], enc[..]);
	d.append_string((String)enc[:n]);
}

// placeholder_row renders one row of an image that spans several cells: cells
// (row, col0) through (row, col0 + n - 1). This is how a multi-cell image is
// displayed -- the terminal fits the image to the whole c x r grid declared by
// its virtual placement, and each cell shows its own portion.
//
// The id-carrying foreground colour is set once for the run and reset after:
// the terminal only joins adjacent placeholder cells while that colour holds.
fn String placeholder_row(uint id, int row, int col0, int n) {
	if (n <= 0) return "";
	DString d = dstring::temp();
	d.append_string(string::tformat(
		"\x1b[38;2;%d;%d;%dm", (id >> 16) & 0xff, (id >> 8) & 0xff, id & 0xff));
	for (int i = 0; i < n; i++) append_placeholder_cell(&d, row, col0 + i);
	d.append_string("\x1b[39m");
	return d.str_view();
}

// placeholder_run encodes one image id across n consecutive cells that all
// show the image's cell (0, 0) -- the right call when each tile is its own
// 1x1 image. For one image spanning many cells use placeholder_row.
fn String placeholder_run(uint id, int n) {
	if (n <= 0) return "";
	DString d = dstring::temp();
	d.append_string(string::tformat(
		"\x1b[38;2;%d;%d;%dm", (id >> 16) & 0xff, (id >> 8) & 0xff, id & 0xff));
	for (int i = 0; i < n; i++) append_placeholder_cell(&d, 0, 0);
	d.append_string("\x1b[39m");
	return d.str_view();
}

// placeholder_string encodes one image id as a single placeholder cell.
// Shorthand for placeholder_run(id, 1) -- one encoder, so the diacritic rules
// cannot drift between the single-cell and run cases.
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
fn InstId Glyph.place(&self, int col, int row, int z = 0, int cols = 0, int rows = 0) {
	return self.session.place(*self, col, row, z, cols, rows);
}

// ---- Absolute placements ----

// place registers an instance of a glyph at a cell coordinate. The placement
// reaches the terminal on the next tick()/sync(). Returns the instance id
// for move/remove, or NO_INSTANCE if the session is full or the glyph is
// unknown.
fn InstId Session.place(&self, Glyph g, int col, int row, int z = 0, int cols = 0, int rows = 0) {
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
		.z = z,
		.cols = cols,
		.rows = rows,
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

// resize changes a placement's target size in cells. The image itself is not
// retransmitted: the next sync() replaces the placement at the new size.
fn void Session.resize(&self, InstId id, int cols, int rows) {
	if (id < 0 || id >= self.placement_count) return;
	if (!self.placements[id].active) return;
	self.placements[id].cols = cols;
	self.placements[id].rows = rows;
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
			&& place.shown_col == place.col && place.shown_row == place.row
			&& place.shown_z == place.z
			&& place.shown_cols == place.cols && place.shown_rows == place.rows;
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
		DString put = dstring::temp();
		put.append_string(string::tformat(
			"\x1b_Ga=p,i=%d,p=%d,q=2", g.base_id + (uint)frame, place.pid));
		if (place.z != 0) put.append_string(string::tformat(",z=%d", place.z));
		// c/r omitted means natural pixel size, which keeps the aspect ratio
		// right without knowing the cell's pixel dimensions.
		if (place.cols > 0) put.append_string(string::tformat(",c=%d", place.cols));
		if (place.rows > 0) put.append_string(string::tformat(",r=%d", place.rows));
		put.append_string("\x1b\\");
		emit(put.str_view());
		self.placements[p].shown = true;
		self.placements[p].shown_col = place.col;
		self.placements[p].shown_row = place.row;
		self.placements[p].shown_z = place.z;
		self.placements[p].shown_cols = place.cols;
		self.placements[p].shown_rows = place.rows;
		self.placements[p].frame = frame;
	}
}
