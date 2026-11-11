// UTF-8, once, for every module: decoding, encoding, and the byte framing
// that cursor movement needs.
module utf8;

// U+FFFD REPLACEMENT CHARACTER, substituted for any byte sequence that is
// well-formed in shape but does not encode a valid Unicode scalar value.
const uint REPLACEMENT = 0xFFFD;
// Highest valid Unicode codepoint.
const uint MAX = 0x10FFFF;

// seq_len is how many bytes the sequence a lead byte starts says it has: 1
// for ASCII, and also 1 for a byte that cannot start one (a continuation, or
// 0xF8 and above), so a caller stepping by it always makes progress.
fn sz seq_len(char lead) {
	if (lead < 0x80) return 1;
	if ((lead & 0xE0) == 0xC0) return 2;
	if ((lead & 0xF0) == 0xE0) return 3;
	if ((lead & 0xF8) == 0xF0) return 4;
	return 1;
}

// is_lead reports whether b can start a sequence: ASCII or a multi-byte lead.
fn bool is_lead(char b) => b < 0x80 || ((b & 0xC0) == 0xC0 && b < 0xF8);

// is_cont reports whether b is a continuation byte (10xxxxxx).
fn bool is_cont(char b) => (b & 0xC0) == 0x80;

// decode reads one sequence from s, storing the codepoint in cp and returning
// how many bytes it took (0 only for an empty s).
//
// A sequence cut short by the end of s, or a byte that cannot start one,
// reads as '?' and takes one byte. Sequences that are well-formed in shape
// but not valid — overlong encodings (C0 80 for NUL), UTF-16 surrogate halves
// (ED A0 80), values above U+10FFFF — read as U+FFFD, so a terminal cannot
// smuggle a rune == 0 that never came from a NUL byte, and re-encoding the
// value never emits bytes that are not UTF-8.
fn sz decode(String s, uint* cp) {
	if (s.len == 0) {
		*cp = 0;
		return 0;
	}
	char b = s[0];
	sz n = seq_len(b);
	if (n == 1) {
		*cp = b < 0x80 ? (uint)b : '?';
		return 1;
	}
	if (s.len < n) {
		*cp = '?';
		return 1;
	}
	uint v = (uint)(b & (0x7F >> n));
	for (sz i = 1; i < n; i++) v = (v << 6) | (uint)(s[i] & 0x3F);
	// The smallest value each length may hold; anything less is overlong.
	uint least = n == 2 ? 0x80 : n == 3 ? 0x800 : 0x10000;
	if (v < least || v > MAX || (v >= 0xD800 && v <= 0xDFFF)) v = REPLACEMENT;
	*cp = v;
	return n;
}

// encode writes cp into out, which must have room for 4 bytes, and returns
// how many bytes it wrote. A value that is not a Unicode scalar — above
// U+10FFFF, or a surrogate half — is written as U+FFFD.
fn sz encode(uint cp, char[] out) {
	if (cp > MAX || (cp >= 0xD800 && cp <= 0xDFFF)) cp = REPLACEMENT;
	if (cp < 0x80) {
		out[0] = (char)cp;
		return 1;
	}
	sz n = cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
	for (sz i = n - 1; i > 0; i--) {
		out[i] = (char)(0x80 | (cp & 0x3F));
		cp >>= 6;
	}
	out[0] = (char)((0xF00 >> n) | cp);
	return n;
}

// prev is where the character before byte pos starts, or 0 at the start. It
// walks back over continuation bytes, and stops at 0 even in a buffer that
// starts mid-sequence.
fn sz prev(char[] buf, sz pos) {
	if (pos <= 0) return 0;
	if (pos > buf.len) pos = buf.len;
	sz i = pos - 1;
	while (i > 0 && is_cont(buf[i])) i--;
	return i;
}

// next is where the character after the one at byte pos starts, or buf.len
// at the end. It always moves at least one byte.
fn sz next(char[] buf, sz pos) {
	if (pos < 0) return 0;
	if (pos >= buf.len) return buf.len;
	sz i = pos + 1;
	while (i < buf.len && is_cont(buf[i])) i++;
	return i;
}
