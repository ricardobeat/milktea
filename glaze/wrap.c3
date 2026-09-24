module glaze;

import std::core::dstring;

// wrap_text breaks s into lines no wider than width display cells, the way a
// CSS box flows text: at spaces where it can, and inside a word only when the
// word alone is wider than the line. Existing newlines are kept, as are the
// spaces that start a line (indentation), but the spaces a break lands on
// are dropped so a wrapped line does not start with one.
//
// ANSI escape sequences take no width and are never split, so text that was
// styled before it was wrapped keeps its styling. A width of 0 or less
// returns s unchanged.
fn String wrap_text(String s, int width) {
	if (width <= 0 || string_width(s) <= width) return s;
	DString out = dstring::temp();
	sz start = 0;
	for (sz i = 0; i <= s.len; i++) {
		if (i < s.len && s[i] != '\n') continue;
		wrap_line(&out, s[start:i - start], width);
		if (i < s.len) out.append_char('\n');
		start = i + 1;
	}
	return out.str_view();
}

// wrapped_line_count is how many lines wrap_text(s, width) produces, for
// sizing a box before it is rendered.
fn int wrapped_line_count(String s, int width) {
	String w = wrap_text(s, width);
	int lines = 1;
	foreach (c : w) if (c == '\n') lines++;
	return lines;
}

fn void wrap_line(DString* out, String line, int width) @local {
	if (string_width(line) <= width) {
		out.append_string(line);
		return;
	}
	int col = 0;
	sz i = 0;
	while (i < line.len) {
		sz sp = i;
		while (i < line.len && line[i] == ' ') i++;
		String spaces = line[sp:i - sp];

		sz ws = i;
		while (i < line.len && line[i] != ' ') {
			i = line[i] == '\x1b' ? skip_escape(line, i) : i + 1;
		}
		String word = line[ws:i - ws];
		int ww = string_width(word);

		if (col > 0 && col + (int)spaces.len + ww > width) {
			out.append_char('\n');
			col = 0;
			spaces = "";
		}
		out.append_string(spaces);
		col += (int)spaces.len;

		if (col + ww <= width) {
			out.append_string(word);
			col += ww;
			continue;
		}

		// A word wider than the line is broken wherever it runs out of room.
		sz j = 0;
		while (j < word.len) {
			if (word[j] == '\x1b') {
				sz e = skip_escape(word, j);
				out.append_string(word[j:e - j]);
				j = e;
				continue;
			}
			sz n = utf8_sequence_len(word, j);
			int cw = utf8_width_at(word, j);
			if (col > 0 && col + cw > width) {
				out.append_char('\n');
				col = 0;
			}
			out.append_string(word[j:n]);
			col += cw;
			j += n;
		}
	}
}

// widest_line is the display width of the widest line in s.
fn int widest_line(String s) {
	int widest = 0;
	sz start = 0;
	for (sz i = 0; i <= s.len; i++) {
		if (i < s.len && s[i] != '\n') continue;
		int w = string_width(s[start:i - start]);
		if (w > widest) widest = w;
		start = i + 1;
	}
	return widest;
}
