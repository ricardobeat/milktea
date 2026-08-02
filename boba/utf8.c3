module boba;

// UTF-8 boundary helpers for the byte-indexed text widgets.
//
// TextInput and TextArea store bytes and track the cursor as a byte offset,
// which keeps insertion and rendering simple. The cost is that any operation
// that *moves* or *removes* text has to respect codepoint boundaries — moving
// the cursor one byte into a multi-byte character, or deleting one byte of
// one, leaves invalid UTF-8 that renders as garbage from that point on.
//
// These two functions are the only places that need to know how UTF-8 is
// framed. A continuation byte matches 0b10xxxxxx; every other byte starts a
// character. Both clamp to the ends of the buffer and always make progress,
// so a malformed buffer can never wedge a cursor loop.

// utf8_is_continuation reports whether b is a UTF-8 continuation byte (10xxxxxx).
fn bool utf8_is_continuation(char b) {
	return (b & 0xC0) == 0x80;
}

// utf8_prev_boundary returns the start of the character preceding `pos`,
// or 0 if `pos` is already at or before the start of the buffer.
fn sz utf8_prev_boundary(char[] buf, sz pos) {
	if (pos <= 0) return 0;
	if (pos > buf.len) pos = buf.len;
	sz i = pos - 1;
	// Walk back over continuation bytes to the lead byte. The `i > 0` bound
	// guarantees termination even if the buffer starts mid-sequence.
	while (i > 0 && utf8_is_continuation(buf[i])) i--;
	return i;
}

// utf8_next_boundary returns the start of the character following `pos`,
// or buf.len if `pos` is at or past the end.
fn sz utf8_next_boundary(char[] buf, sz pos) {
	if (pos < 0) return 0;
	if (pos >= buf.len) return buf.len;
	sz i = pos + 1;
	while (i < buf.len && utf8_is_continuation(buf[i])) i++;
	return i;
}
