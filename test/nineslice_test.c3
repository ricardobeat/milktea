module nineslice_test;
import tgp;

// A tiled edge is a run of placeholder cells sharing one image id. The
// terminal only joins them into a run while the id-carrying fg color stays
// set, so the run must carry exactly one color span -- repeating a
// single-cell placeholder (which resets after every cell) leaves the edge
// blank. Regression for the missing top/bottom edges.
fn void test_placeholder_run_single_color_span() @test {
	String s = tgp::placeholder_run(4096, 5);
	// One color set, one reset, five placeholder codepoints.
	int sets = 0; int resets = 0; int cells = 0;
	for (sz i = 0; i < s.len; i++) {
		if (i + 7 < s.len && s[i] == 0x1b && s[i+1] == '[' && s[i+2] == '3' && s[i+3] == '8') sets++;
		if (i + 4 < s.len && s[i] == 0x1b && s[i+1] == '[' && s[i+2] == '3' && s[i+3] == '9') resets++;
		// U+10EEEE encodes as F4 8E BB AE
		if (i + 3 < s.len && (s[i] & 0xff) == 0xf4 && (s[i+1] & 0xff) == 0x8e) cells++;
	}
	assert(sets == 1, "expected exactly one color set");
	assert(resets == 1, "expected exactly one reset");
	assert(cells == 5, "expected five placeholder cells");
}
