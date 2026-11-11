// Numbers as decimal text, for every module that writes escape sequences:
// without the general formatter, which costs a program tens of kilobytes.
module num;

import std::core::dstring;

// write appends v in decimal.
fn void write(DString* out, sz v) {
	char[24] b;
	sz i = b.len;
	ulong u = v < 0 ? (ulong)-(v + 1) + 1 : (ulong)v;
	do {
		b[--i] = (char)('0' + u % 10);
		u /= 10;
	} while (u != 0);
	if (v < 0) b[--i] = '-';
	out.append_string((String)b[i..]);
}

// str is v in decimal, on tmem.
fn String str(sz v) {
	DString s = dstring::temp();
	write(&s, v);
	return s.str_view();
}

// csi is the control sequence ESC [ n final, on tmem: "\e[3A" for (3, 'A').
fn String csi(sz n, char final) {
	DString s = dstring::temp();
	s.append_string("\e[");
	write(&s, n);
	s.append_char(final);
	return s.str_view();
}
