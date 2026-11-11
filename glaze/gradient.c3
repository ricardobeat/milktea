module glaze;

import std::core::string;
import std::core::dstring;
import utf8;

fn String gradient_text(String text, Color from, Color to, bool bold = true) {
	sz width = string_width(text);
	if (width <= 0) return text;

	DString out = dstring::temp();
	sz i = 0;
	sz col = 0;
	while (i < text.len) {
		sz clen = utf8::seq_len(text[i]);
		if (clen > text.len - i) clen = text.len - i;
		String ch = text[i..i + clen - 1];
		sz ch_w = string_width(ch);

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
