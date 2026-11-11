// Left out of a build with -D NO_CONTROL (see control_off.c3).
module milktea @feat(!NO_CONTROL);

// A tiny pattern matcher: literals, '.', \d \w \s, * + ?, ^ $. No groups,
// no alternation, no classes. Matches anywhere unless anchored by ^.

// pm_next: where the element at pi ends; false on a trailing backslash.
fn bool pm_next(String pat, sz pi, sz* next) @local {
	if (pat[pi] == '\\') {
		if (pi + 1 >= pat.len) return false;
		*next = pi + 2;
		return true;
	}
	*next = pi + 1;
	return true;
}

// pm_take: does the element at pi take c?
fn bool pm_take(String pat, sz pi, char c) @local {
	char ch = pat[pi];
	if (ch == '\\') {
		ch = pat[pi + 1];
		switch (ch) {
			case 'd': return c.is_digit();
			case 'w': return c.is_alnum() || c == '_';
			case 's': return c == ' ' || c == '\t' || c == '\n' || c == '\r';
			default: return c == ch;
		}
	}
	return ch == '.' || c == ch;
}

// pm_here: does the pattern from pi match the text from ti? Leaves the
// match's end in end.
fn bool pm_here(String pat, sz pi, String txt, sz ti, sz* end) @local {
	if (pi >= pat.len) { *end = ti; return true; }
	if (pat[pi] == '$') return ti == txt.len && pm_here(pat, pi + 1, txt, ti, end);
	sz next;
	if (!pm_next(pat, pi, &next)) return false;
	char q = 0;
	if (next < pat.len && (pat[next] == '*' || pat[next] == '+' || pat[next] == '?')) {
		q = pat[next];
		next++;
	}
	switch (q) {
		case 0: {
			if (ti < txt.len && pm_take(pat, pi, txt[ti])) {
				return pm_here(pat, next, txt, ti + 1, end);
			}
			return false;
		}
		case '?': {
			if (pm_here(pat, next, txt, ti, end)) return true;
			if (ti < txt.len && pm_take(pat, pi, txt[ti])) {
				return pm_here(pat, next, txt, ti + 1, end);
			}
			return false;
		}
		case '*':
		case '+': {
			// Greedy, then fewer, until the rest matches.
			sz k = 0;
			while (ti + k < txt.len && pm_take(pat, pi, txt[ti + k])) k++;
			sz min = q == '+' ? 1 : 0;
			for (sz n = k + 1; n > min; n--) {
				if (pm_here(pat, next, txt, ti + n - 1, end)) return true;
			}
			return false;
		}
	}
	return false;
}

// pattern_find: the nth match (from 0) of pattern in text; its span goes in
// start and end. Empty patterns and zero-length matches find nothing.
fn bool pattern_find(String pattern, String text, sz nth, sz* start, sz* end) {
	if (pattern.len == 0) return false;
	bool anchored = pattern[0] == '^';
	sz from = anchored ? 1 : 0;
	sz count = 0;
	sz at = 0;
	while (at <= text.len) {
		sz stop;
		if (pm_here(pattern, from, text, at, &stop)) {
			if (stop > at) {
				if (count == nth) {
					*start = at;
					*end = stop;
					return true;
				}
				count++;
				// An anchored pattern matches at the start or not at all.
				if (anchored) break;
				at = stop;
				continue;
			}
		}
		if (anchored) break;
		at++;
	}
	return false;
}
