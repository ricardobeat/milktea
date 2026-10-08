// Lightweight markdown -> ANSI rendering, plus the line arithmetic the log
// pane needs to scroll. Nothing here knows about the harness: it takes
// strings and returns strings, so it is reusable and testable on its own.
module md;

import glaze;
import std::core::dstring;
import std::core::mem;

fn void seg_render(DString* out, glaze::Style style, String s) @local {
	if (s.len == 0) return;
	out.append_string(style.render(s));
}

// plain emits s with the inline emphasis markers stripped. The markers are
// dropped rather than honoured: styling nested runs would need a real parser,
// and the harness only wants the text to read cleanly.
fn void plain(DString* out, glaze::Style style, String s) @local {
	DString clean = dstring::temp();
	for (sz i = 0; i < s.len; i++) {
		char c = s[i];
		if (c == '*' || c == '_') continue;
		clean.append_char(c);
	}
	seg_render(out, style, clean.str_view());
}

// emit_inline splits a line on backticks, styling the odd-numbered runs as
// code and the rest as body text.
fn void emit_inline(DString* out, String line, glaze::Style base, glaze::Style code) @local {
	if (!line.contains_char('`')) {
		plain(out, base, line);
		return;
	}
	bool is_code = false;
	Splitter it = line.tokenize_all("`");
	while (!it.at_end()) {
		String seg = it.next() ?? "";
		if (is_code) {
			seg_render(out, code, seg);
		} else {
			plain(out, base, seg);
		}
		is_code = !is_code;
	}
}

// Styles the renderer paints with. Grouped so a caller can restyle the output
// without the constants being scattered through render().
struct Theme {
	glaze::Style base;
	glaze::Style header;
	glaze::Style code;
	glaze::Style quote;
}

fn Theme default_theme() {
	return {
		.base   = glaze::style().foreground(glaze::color_hex("#aaaaaa")),
		.header = glaze::style().foreground(glaze::color_hex("#00ffcc")).with_bold(true),
		.code   = glaze::style().foreground(glaze::color_hex("#ffcc00")),
		.quote  = glaze::style().foreground(glaze::color_hex("#7f7f7f")),
	};
}

// render turns markdown into an ANSI-styled block. Fenced blocks, ATX
// headings, blockquotes and inline code are recognised; everything else is
// body text.
//
// The returned DString is heap-allocated and owned by the caller.
fn DString render(String markdown, Theme theme = default_theme()) {
	DString o = dstring::new(mem);
	bool in_code = false;
	Splitter lines = markdown.tokenize_all("\n");
	while (!lines.at_end()) {
		String line = lines.next() ?? "";

		if (line.starts_with("```")) {
			in_code = !in_code;
			continue;
		}
		if (in_code) {
			DString ind = dstring::temp();
			ind.append_string("    ");
			ind.append_string(line);
			seg_render(&o, theme.code, ind.str_view());
			o.append_char('\n');
			continue;
		}
		if (line.starts_with("#")) {
			String rest = line;
			while (rest.starts_with("#")) rest = rest.strip_prefix("#");
			rest = rest.trim_left(" \t");
			emit_inline(&o, rest, theme.header, theme.code);
			o.append_char('\n');
			continue;
		}
		if (line.starts_with(">")) {
			String rest = line.strip_prefix(">").trim_left(" \t");
			o.append_string(theme.quote.render("> "));
			emit_inline(&o, rest, theme.quote, theme.code);
			o.append_char('\n');
			continue;
		}
		emit_inline(&o, line, theme.base, theme.code);
		o.append_char('\n');
	}
	return o;
}

// count_lines counts the lines in s, counting a trailing fragment with no
// newline as a line of its own.
fn sz count_lines(String s) {
	sz n = 0;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') n++;
	}
	if (s.len == 0 || s[s.len - 1] != '\n') n++;
	return n;
}

// slice_lines returns the count lines starting at line start, as a slice of
// s — no copy, so the result lives exactly as long as s does. An out-of-range
// start yields an empty slice.
fn String slice_lines(String s, sz start, sz count) {
	if (count <= 0 || start < 0) return (String)s[0:0];
	sz begin = 0;
	sz line = 0;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') {
			line++;
			if (line == start) {
				begin = i + 1;
				break;
			}
		}
	}
	if (line < start) return (String)s[0:0];

	sz end = s.len;
	sz taken = 0;
	for (sz i = begin; i < s.len; i++) {
		if (s[i] == '\n') {
			taken++;
			if (taken == count) {
				end = i + 1;
				break;
			}
		}
	}
	return (String)s[begin:end - begin];
}

// wrap_text hard-wraps at width columns, counting bytes rather than display
// width. Good enough for the ASCII error text the modal shows.
//
// The returned DString is temp-allocated: it dies with the enclosing @pool().
fn DString wrap_text(String s, sz width) {
	DString out = dstring::temp();
	sz col = 0;
	for (sz i = 0; i < s.len; i++) {
		char c = s[i];
		if (c == '\n') {
			out.append_char('\n');
			col = 0;
		} else {
			if (col == width) {
				out.append_char('\n');
				col = 0;
			}
			out.append_char(c);
			col++;
		}
	}
	return out;
}
