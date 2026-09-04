module tgp_test;

import tgp;
import milktea;
import std::core::dstring;

// ============================================================
// tgp: pure helpers (base64, placeholder encoding, frame math)
// and placement reconciliation, exercised through a capture
// sink so no real terminal I/O happens.
// ============================================================

fn void test_base64_vectors() @test {
	assert(tgp::base64_encode((char[])"Man") == (String)"TWFu");
	assert(tgp::base64_encode((char[])"Ma") == (String)"TWE=");
	assert(tgp::base64_encode((char[])"M") == (String)"TQ==");
}

fn void test_placeholder_encoding() @test {
	String s = tgp::placeholder_string(0x010203);
	// ESC [ 38;2;1;2;3 m + U+10EEEE (4 bytes) + two U+0305 diacritics
	// (2 bytes each, encoding row 0 and column 0) + ESC [ 39 m.
	assert(s.len == 2 + 11 + 4 + 4 + 5);
	assert(s[2] == '3' && s[3] == '8');
	assert(s[7] == '1' && s[9] == '2' && s[11] == '3');
	// U+10EEEE = F4 8E BB AE in UTF-8.
	assert((char)s[13] == (char)0xf4 && (char)s[14] == (char)0x8e);
	assert((char)s[15] == (char)0xbb && (char)s[16] == (char)0xae);
	// Explicit (row 0, col 0): without these a run of cells inherits an
	// incrementing column and every cell but the first renders blank.
	assert((char)s[17] == (char)0xcc && (char)s[18] == (char)0x85);
	assert((char)s[19] == (char)0xcc && (char)s[20] == (char)0x85);
}

fn void test_glyph_frame_math() @test {
	// Static glyphs stay on frame 0.
	assert(tgp::glyph_frame(0, 8, 0) == 0);
	assert(tgp::glyph_frame(0, 8, 99999) == 0);
	// 12 fps: frame = elapsed_ms * 12 / 1000 % count.
	assert(tgp::glyph_frame(12, 8, 0) == 0);
	assert(tgp::glyph_frame(12, 8, 83) == 0);   // 83*12/1000 = 0
	assert(tgp::glyph_frame(12, 8, 84) == 1);   // 84*12/1000 = 1
	// 8 frames at 12fps loop in ~667ms, so the counter wraps back to 0.
	assert(tgp::glyph_frame(12, 8, 667) == 0);
}

// ---- Capture sink ----

DString g_captured_buf;
bool g_capturing = false;

fn void capture(String escape) {
	g_captured_buf.append_string(escape);
}

fn int count_occurrences(String hay, String needle) {
	int count = 0;
	for (sz i = 0; i + needle.len <= hay.len; i++) {
		bool match = true;
		for (sz j = 0; j < needle.len; j++) {
			if (hay[i + j] != needle[j]) {
				match = false;
				break;
			}
		}
		if (match) count++;
	}
	return count;
}

fn void test_place_move_remove_diff() @test {
	@pool() {
		g_captured_buf = dstring::temp();
		tgp::set_sink(&capture);
		defer tgp::set_sink(null);

		tgp::set_supported_override(true);
		defer tgp::set_supported_override(false);

		tgp::Session s = tgp::new_session();

		char[16] pixels;
		tgp::Glyph g = s.register({
			.frames = pixels[..],
			.count = 1, .width = 2, .height = 2,
			.fps = 0, .fallback = "x",
		})!!;

		// flush() defers outside the alt screen (correct behavior), so call
		// the transmit step directly to verify the encoding.
		s.transmit_glyph(0);

		tgp::InstId id = s.place(g, 3, 4);
		assert(id != tgp::NO_INSTANCE);
		s.sync();
		// One transmit (4 bytes RGBA -> one chunk) + one put.
		String out = g_captured_buf.str_view();
		assert(count_occurrences(out, "\x1b_Ga=t,") == 1);
		// A placement lands at the CURSOR: the cell is chosen by a CSI H
		// before the put, not by X/Y (which are within-cell pixel offsets).
		// col 3, row 4 is 1-based row 5, col 4.
		assert(count_occurrences(out, "\x1b[5;4H") == 1);
		// transmit_glyph emits its own U=1 virtual placement, so match the
		// screen placement by its placement id rather than the bare action.
		assert(count_occurrences(out, ",p=1,q=2") == 1);
		assert(count_occurrences(out, "X=") == 0);

		// Unchanged: sync emits nothing new.
		String before = g_captured_buf.str_view();
		s.sync();
		assert(g_captured_buf.str_view().len == before.len);

		// Move: the image id is unchanged, so re-issuing a=p with the same
		// placement id REPLACES it. No delete, hence no flicker.
		s.move(id, 5, 4);
		s.sync();
		// str_view() is a view into the (possibly reallocated) buffer, so
		// re-fetch after each round of appends.
		out = g_captured_buf.str_view();
		assert(count_occurrences(out, "\x1b[5;6H") == 1); // row 4 -> 5, col 5 -> 6
		assert(count_occurrences(out, ",p=1,q=2") == 2);
		assert(count_occurrences(out, "a=d,") == 0);

		// Remove: delete the placement by image id + placement id. d=p/d=P
		// would delete by cell coordinates instead, which is a different
		// operation entirely.
		s.remove(id);
		s.sync();
		out = g_captured_buf.str_view();
		assert(count_occurrences(out, "a=d,d=i,") == 1);
		assert(count_occurrences(out, "a=d,d=P,") == 0);
	};
}

fn void test_glyph_render_and_place_sugar() @test {
	@pool() {
		g_captured_buf = dstring::temp();
		tgp::set_sink(&capture);
		defer tgp::set_sink(null);
		tgp::set_supported_override(true);
		defer tgp::set_supported_override(false);

		tgp::Session s = tgp::new_session();
		char[16] pixels;
		tgp::Glyph g = s.register({
			.frames = pixels[..],
			.count = 1, .width = 2, .height = 2,
			.fps = 0, .fallback = "f",
		})!!;

		// render() returns the placeholder for the glyph's current frame.
		String cell = g.render();
		assert(count_occurrences(cell, "[38;2;") == 1);

		// place() goes through the owning session and appears in the diff.
		tgp::InstId id = g.place(1, 2);
		assert(id != tgp::NO_INSTANCE);
		s.sync();
		String out = g_captured_buf.str_view();
		// col 1, row 2 -> CSI 3;2 H (1-based).
		assert(count_occurrences(out, "\x1b[3;2H") == 1);
	};
}
