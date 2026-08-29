module xray;

struct Rect {
	int x, y, w, h;
}

fn Rect new_rect(int x, int y, int w, int h) {
	return { .x = x, .y = y, .w = w, .h = h };
}

fn int Rect.right(&self) => self.x + self.w;

fn int Rect.bottom(&self) => self.y + self.h;

fn bool Rect.contains(&self, int px, int py) {
	return px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h;
}

fn Rect Rect.inset(&self, int left, int top, int right, int bottom) {
	int new_x = self.x + left;
	int new_y = self.y + top;
	int new_w = self.w - left - right;
	int new_h = self.h - top - bottom;
	if (new_w < 0) new_w = 0;
	if (new_h < 0) new_h = 0;
	return { .x = new_x, .y = new_y, .w = new_w, .h = new_h };
}

enum ConstraintKind : char {
	CLEN,
	CMIN,
	CMAX,
	CPERCENT,
	CFILL,
	CFIT, // measure content; requires a MeasureFn + context pointer
}

// MeasureFn is called during layout to size a CFIT child.
// cross is the available size on the cross axis (width when laying out vertically).
// ctx is an arbitrary pointer supplied alongside the constraint.
// Returns the desired size along the main axis.
alias MeasureFn = fn int(void* ctx, int cross);

struct Constraint {
	ConstraintKind kind;
	int value; // CLEN/CMIN/CMAX/CPERCENT/CFILL's one number; unused by CFIT
	MeasureFn measure; // only used when kind == CFIT
	void* ctx; // passed to measure
	// CFIT's own bounds — 0 means unbounded on that side, so a bare fit()
	// (fit_min = fit_max = 0) measures freely. Kept separate from `value`
	// so a CFIT constraint can be floored, capped, or both without a field
	// whose meaning silently changes with `kind`.
	int fit_min;
	int fit_max;
}

fn Constraint cells(int n) {
	return { .kind = ConstraintKind.CLEN, .value = n };
}

fn Constraint at_least(int n) {
	return { .kind = ConstraintKind.CMIN, .value = n };
}

fn Constraint at_most(int n) {
	return { .kind = ConstraintKind.CMAX, .value = n };
}

fn Constraint percent(int p) {
	return { .kind = ConstraintKind.CPERCENT, .value = p };
}

fn Constraint fill(int weight) {
	return { .kind = ConstraintKind.CFILL, .value = weight };
}

fn Constraint fit(MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .measure = measure, .ctx = ctx };
}

// min_fit is fit(), floored: content grows the size past n, but never below
// it. Where at_least(n) has no content to grow toward at all — a bare
// number can only ever fall back to whatever leftover space nothing else
// on the axis claims — this measures a real Content/child tree (the same
// machinery fit() uses) and floors that measurement, the CSS min-width
// idiom: a short child gets n, a long one gets its own natural size.
fn Constraint min_fit(int n, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_min = n, .measure = measure, .ctx = ctx };
}

// max_fit is fit(), capped: content shrinks the measured size only if it
// exceeds n — the mirror of min_fit, for a node that should hug its content
// but never grow past some ceiling (a tooltip, a sidebar that must not
// swallow the screen).
fn Constraint max_fit(int n, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_max = n, .measure = measure, .ctx = ctx };
}

// range_fit combines both: content sizes the node between lo and hi.
fn Constraint range_fit(int lo, int hi, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_min = lo, .fit_max = hi, .measure = measure, .ctx = ctx };
}

// resolve_fit runs a CFIT constraint's measure callback and applies its
// fit_min/fit_max bounds — the one place that logic lives, so min_fit/
// max_fit/range_fit behave identically everywhere a CFIT constraint is
// resolved (layout_axis_cross's two passes, node_solve's resolve_axis).
// fit_max = 0 means unbounded, matching fit_min = 0 meaning no floor.
// no_measure is what a constraint with no measure callback falls back to —
// callers differ (0 for the flex-distribution passes, the full available
// span for a lone stack child) so it isn't baked in here.
fn int resolve_fit(Constraint c, int cross, int no_measure = 0) {
	int size = c.measure ? c.measure(c.ctx, cross) : no_measure;
	if (size < 0) size = 0;
	if (size < c.fit_min) size = c.fit_min;
	if (c.fit_max > 0 && size > c.fit_max) size = c.fit_max;
	return size;
}

fn int layout_axis_cross(int total, int gap, int cross, Constraint[] cs, int[] out_sizes) @local {
	int n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	// Calculate available space after gaps
	int gap_count = n > 1 ? n - 1 : 0;
	int available = total - gap * gap_count;
	if (available < 0) available = 0;

	// Initialize sizes array on stack
	int[64] sizes;
	for (int i = 0; i < n; i++) {
		sizes[i] = 0;
	}

	int fixed             = 0;
	int fill_weight_total = 0;
	int[64] max_caps;
	bool[64] is_fill;

	// Pass 1: assign fixed sizes and calculate fill weights
	for (int i = 0; i < n; i++) {
		max_caps[i] = 0;
		is_fill[i] = false;

		switch (cs[i].kind) {
			case ConstraintKind.CLEN:
				int len_val = cs[i].value;
				if (len_val < 0) len_val = 0;
				if (len_val > available) len_val = available;
				sizes[i] = len_val;
				fixed += len_val;

			case ConstraintKind.CMIN:
				int min_val = cs[i].value;
				if (min_val < 0) min_val = 0;
				if (min_val > available) min_val = available;
				sizes[i] = min_val;
				fixed += min_val;

			case ConstraintKind.CPERCENT:
				int pct_sz = available * cs[i].value / 100;
				sizes[i] = pct_sz;
				fixed += pct_sz;

			case ConstraintKind.CFIT:
				int fit_sz = resolve_fit(cs[i], cross);
				if (fit_sz > available) fit_sz = available;
				sizes[i] = fit_sz;
				fixed += fit_sz;

			case ConstraintKind.CMAX:
				sizes[i] = 0;
				int cap_val = cs[i].value;
				if (cap_val < 0) cap_val = 0;
				if (cap_val > available) cap_val = available;
				max_caps[i] = cap_val;
				fill_weight_total += 1;

			case ConstraintKind.CFILL:
				sizes[i] = 0;
				is_fill[i] = true;
				fill_weight_total += cs[i].value;

			default:
				break;
		}
	}

	// Pass 2: distribute remaining space among fill/max children
	for (int iter = 0; iter < 4; iter++) {
		int remaining = available - fixed;
		if (remaining <= 0 || fill_weight_total <= 0) break;

		bool clamped = false;

		for (int i = 0; i < n; i++) {
			if (cs[i].kind == ConstraintKind.CFILL) {
				int weight = cs[i].value;
				int share  = remaining * weight / fill_weight_total;
				sizes[i] = share;
			} else if (cs[i].kind == ConstraintKind.CMAX) {
				int weight = 1;
				int share  = remaining * weight / fill_weight_total;
				if (share > max_caps[i]) {
					sizes[i] = max_caps[i];
					clamped = true;
				} else {
					sizes[i] = share;
				}
			}
		}

		if (!clamped) break;

		// Recalculate fixed and fill_weight_total
		fixed = 0;
		fill_weight_total = 0;
		for (int i = 0; i < n; i++) {
			switch (cs[i].kind) {
				case ConstraintKind.CLEN:
				case ConstraintKind.CMIN:
				case ConstraintKind.CPERCENT:
				case ConstraintKind.CFIT:
					fixed += sizes[i];

				case ConstraintKind.CMAX:
					if (sizes[i] == max_caps[i]) {
						fixed += sizes[i];
					} else {
						fill_weight_total += 1;
					}

				case ConstraintKind.CFILL:
					fill_weight_total += cs[i].value;

				default:
					break;
			}
		}
	}

	// Distribute any remainder to the last fill child
	int final_total = 0;
	for (int i = 0; i < n; i++) {
		if (sizes[i] < 0) sizes[i] = 0;
		final_total += sizes[i];
	}
	// Distribute integer-division leftovers to flexible children, last one
	// first. A CMAX child only absorbs up to its cap, so we keep scanning
	// backwards until the remainder is placed or no candidate has room —
	// dumping it unconditionally on the last flexible child would silently
	// defeat that child's cap.
	int remainder = available - final_total;
	for (int i = n - 1; i >= 0 && remainder > 0; i--) {
		if (cs[i].kind == ConstraintKind.CFILL) {
			sizes[i] += remainder;
			remainder = 0;
		} else if (cs[i].kind == ConstraintKind.CMAX) {
			int room = max_caps[i] - sizes[i];
			if (room <= 0) continue;
			int take = room < remainder ? room : remainder;
			sizes[i] += take;
			remainder -= take;
		}
	}

	// Copy to output, clamping the running total to the axis budget. Fixed
	// constraints (CLEN/CMIN/CPERCENT/CFIT) are individually capped at
	// `available` but can still oversubscribe it collectively — e.g. two
	// at_least(40) children in a 30-wide area. Truncating here keeps the
	// caller's invariant that every returned rect lies inside `area`, so
	// downstream drawing never runs past the parent.
	int used = 0;
	for (int i = 0; i < n; i++) {
		int size = sizes[i] < 0 ? 0 : sizes[i];
		int room = available - used;
		if (room < 0) room = 0;
		if (size > room) size = room;
		out_sizes[i] = size;
		used += size;
	}

	return n;
}

fn int layout_h(Rect area, Constraint[] cs, Rect[] out_rects) {
	return layout_h_gap(area, cs, 0, out_rects);
}

fn int layout_v(Rect area, Constraint[] cs, Rect[] out_rects) {
	return layout_v_gap(area, cs, 0, out_rects);
}

fn int layout_h_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects) {
	int n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	int[64] sizes;
	int n_computed = layout_axis_cross(area.w, gap, area.h, cs[0:n], sizes[0:n]);

	int offset = 0;
	for (int i = 0; i < n_computed; i++) {
		out_rects[i] = { .x = area.x + offset, .y = area.y, .w = sizes[i], .h = area.h };
		offset += sizes[i] + gap;
	}

	return n_computed;
}

fn int layout_v_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects) {
	int n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	int[64] sizes;
	int n_computed = layout_axis_cross(area.h, gap, area.w, cs[0:n], sizes[0:n]);

	int offset = 0;
	for (int i = 0; i < n_computed; i++) {
		out_rects[i] = { .x = area.x, .y = area.y + offset, .w = area.w, .h = sizes[i] };
		offset += sizes[i] + gap;
	}

	return n_computed;
}
