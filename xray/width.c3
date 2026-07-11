module xray;

// char_width returns the terminal display width of a Unicode codepoint.
// Follows wcwidth semantics as commonly expected by terminal emulators:
//   0 — combining marks, zero-width characters, and the NUL codepoint
//   1 — ordinary single-column characters
//   2 — East Asian Wide / Fullwidth characters and wide emoji
//
// This is the single authoritative implementation; all width-decision
// sites in xray (and the glaze string_width algorithm) must agree with
// these rules. The ranges are derived from Unicode EastAsianWidth data
// and the de-facto terminal behaviour of popular emulators (kitty, alacritty,
// iTerm2, gnome-terminal).
fn int char_width(uint cp) {
	// NUL is zero-width by convention.
	if (cp == 0) return 0;

	// Zero-width and combining ranges — must not advance the cursor.
	// Combining Diacritical Marks
	if (cp >= 0x0300 && cp <= 0x036F) return 0;
	// Combining Diacritical Marks Extended
	if (cp >= 0x1AB0 && cp <= 0x1AFF) return 0;
	// Combining Diacritical Marks Supplement
	if (cp >= 0x1DC0 && cp <= 0x1DFF) return 0;
	// Combining Diacritical Marks for Symbols
	if (cp >= 0x20D0 && cp <= 0x20FF) return 0;
	// Variation Selectors (VS1–VS16, narrow/wide selector hints)
	if (cp >= 0xFE00 && cp <= 0xFE0F) return 0;
	// Combining Half Marks
	if (cp >= 0xFE20 && cp <= 0xFE2F) return 0;
	// Zero-width space, non-joiner, joiner, left-to-right mark, right-to-left mark
	if (cp >= 0x200B && cp <= 0x200F) return 0;
	// Word-Joiner
	if (cp == 0x2060) return 0;
	// Zero-width no-break space (BOM when not at start)
	if (cp == 0xFEFF) return 0;

	// Fast path: plain ASCII (most common case in practice)
	if (cp < 0x1100) return 1;

	// Wide / Fullwidth ranges — 2 terminal columns.
	// The order here is roughly Unicode block order; a binary-search
	// range table would be faster for very hot paths, but the cascading
	// ifs are readable and branch-predicted well in practice.

	// Hangul Jamo (leading consonants/vowels rendered wide)
	if (cp >= 0x1100 && cp <= 0x115F) return 2;

	// CJK Radicals Supplement … CJK Symbols and Punctuation (excl. halfwidth)
	if (cp >= 0x2E80 && cp <= 0x303E) return 2;

	// Hiragana, Katakana, Bopomofo, Hangul Compatibility Jamo,
	// Kanbun, Bopomofo Extended, CJK Unified Ideo. Ext A, Yijing
	if (cp >= 0x3041 && cp <= 0x33FF) return 2;

	// CJK Unified Ideographs Extension A
	if (cp >= 0x3400 && cp <= 0x4DBF) return 2;

	// CJK Unified Ideographs (the main block)
	if (cp >= 0x4E00 && cp <= 0x9FFF) return 2;

	// Yi Syllables + Radicals
	if (cp >= 0xA000 && cp <= 0xA4CF) return 2;

	// Hangul Syllables
	if (cp >= 0xAC00 && cp <= 0xD7A3) return 2;

	// CJK Compatibility Ideographs
	if (cp >= 0xF900 && cp <= 0xFAFF) return 2;

	// CJK Compatibility Forms (fullwidth punctuation)
	if (cp >= 0xFE30 && cp <= 0xFE4F) return 2;

	// Fullwidth Latin and other fullwidth forms (FF01–FF60)
	// NOTE: FF61–FFDC is halfwidth Katakana/Hangul — width 1, so we
	// must NOT include those in the wide range.
	if (cp >= 0xFF00 && cp <= 0xFF60) return 2;

	// Fullwidth currency and signs (FFE0–FFE6)
	// NOTE: FFE8–FFEE are halfwidth forms — narrow.
	if (cp >= 0xFFE0 && cp <= 0xFFE6) return 2;

	// --- Supplementary Plane wide ranges ---

	// Miscellaneous Symbols and Pictographs, Emoticons
	if (cp >= 0x1F300 && cp <= 0x1F64F) return 2;

	// Transport and Map Symbols
	if (cp >= 0x1F680 && cp <= 0x1F6FF) return 2;

	// Supplemental Symbols and Pictographs
	if (cp >= 0x1F900 && cp <= 0x1F9FF) return 2;

	// Symbols and Pictographs Extended-A
	if (cp >= 0x1FA70 && cp <= 0x1FAFF) return 2;

	// CJK Unified Ideographs Extensions B–F and CJK Compatibility Ideographs Supp.
	if (cp >= 0x20000 && cp <= 0x3FFFD) return 2;

	return 1;
}
