module glaze;

import std::core::string;
import std::core::dstring;

fn sz _utf8_char_len(char b) @local {
	if ((b & 0x80) == 0)    return 1;
	if ((b & 0xe0) == 0xc0) return 2;
	if ((b & 0xf0) == 0xe0) return 3;
	if ((b & 0xf8) == 0xf0) return 4;
	return 1;
}

fn String gradient_text(String text, Color from, Color to, bool bold = true) {
	int width = string_width(text);
	if (width <= 0) return text;

	DString out = dstring::temp();
	sz i = 0;
	int col = 0;
	while (i < text.len) {
		sz clen = _utf8_char_len(text[i]);
		if (clen > text.len - i) clen = text.len - i;
		String ch = text[i..i + clen - 1];
		int ch_w = string_width(ch);

		double t = width > 1 ? (double)col / (double)(width - 1) : 0.0;
		Color c = blend_luv(from, to, t);
		Style s = style().foreground(c);
		if (bold) s = s.with_bold(true);
		out.append_string(s.render(ch));

		col += ch_w > 0 ? ch_w : 1;
		i += clen;
	}
	return out.str_view();
}
