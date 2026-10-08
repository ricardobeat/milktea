module xray;

struct Rect {
	sz x, y, w, h;
}

fn Rect new_rect(sz x, sz y, sz w, sz h) {
	return { .x = x, .y = y, .w = w, .h = h };
}

fn sz Rect.right(&self) => self.x + self.w;

fn sz Rect.bottom(&self) => self.y + self.h;

fn bool Rect.contains(&self, sz px, sz py) {
	return px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h;
}

fn Rect Rect.inset(&self, sz left, sz top, sz right, sz bottom) {
	sz new_x = self.x + left;
	sz new_y = self.y + top;
	sz new_w = self.w - left - right;
	sz new_h = self.h - top - bottom;
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
	// No size set. A node starts with this on both axes, and its parent
	// decides: a row or column sizes it to its content along the main axis
	// and stretches it across, a stack fills with it. Rect splitting
	// (layout_v/layout_h) never sees it.
	CAUTO,
}

// MeasureFn is called during layout to size a CFIT child.
// cross is the available size on the cross axis (width when laying out vertically).
// ctx is an arbitrary pointer supplied alongside the constraint.
// Returns the desired size along the main axis.
alias MeasureFn = fn sz(void* ctx, sz cross);

struct Constraint {
	ConstraintKind kind;
	sz value; // CLEN/CMIN/CMAX/CPERCENT/CFILL's one number; unused by CFIT
	MeasureFn measure; // only used when kind == CFIT
	void* ctx; // passed to measure
	// CFIT's own bounds — 0 means unbounded on that side, so a bare fit()
	// (fit_min = fit_max = 0) measures freely. Kept separate from `value`
	// so a CFIT constraint can be floored, capped, or both without a field
	// whose meaning silently changes with `kind`.
	sz fit_min;
	sz fit_max;
}

fn Constraint cells(sz n) {
	return { .kind = ConstraintKind.CLEN, .value = n };
}

fn Constraint min(sz n) {
	return { .kind = ConstraintKind.CMIN, .value = n };
}

fn Constraint max(sz n) {
	return { .kind = ConstraintKind.CMAX, .value = n };
}

fn Constraint percent(sz p) {
	return { .kind = ConstraintKind.CPERCENT, .value = p };
}

fn Constraint fill(sz weight) {
	return { .kind = ConstraintKind.CFILL, .value = weight };
}

// fit sizes a node to its content, the CSS fit-content: a node given
// .width(fit()) or .height(fit()) measures its own content or children on
// that axis.
fn Constraint fit() {
	return { .kind = ConstraintKind.CFIT };
}

// measured sizes to whatever `measure` reports, for a rect that has no node
// to measure — layout_v/layout_h over plain constraints.
fn Constraint measured(MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .measure = measure, .ctx = ctx };
}

// min_measured is measured(), floored: content grows the size past n, but
// never below it. Where min(n) has no content to grow toward at all — a bare
// number can only ever fall back to whatever leftover space nothing else
// on the axis claims — this measures a real Content/child tree (the same
// machinery measured() uses) and floors that measurement, the CSS min-width
// idiom: a short child gets n, a long one gets its own natural size.
fn Constraint min_measured(sz n, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_min = n, .measure = measure, .ctx = ctx };
}

// max_measured is measured(), capped: content shrinks the measured size only
// if it exceeds n — the mirror of min_measured, for a node that should hug
// its content but never grow past some ceiling (a tooltip, a sidebar that
// must not swallow the screen).
fn Constraint max_measured(sz n, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_max = n, .measure = measure, .ctx = ctx };
}

// range_measured combines both: content sizes the node between lo and hi.
fn Constraint range_measured(sz lo, sz hi, MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .fit_min = lo, .fit_max = hi, .measure = measure, .ctx = ctx };
}

// resolve_fit runs a CFIT constraint's measure callback and applies its
// fit_min/fit_max bounds — the one place that logic lives, so min_measured/
// max_measured/range_measured behave identically everywhere a CFIT constraint is
// resolved (layout_axis_cross's two passes, node_solve's resolve_axis).
// fit_max = 0 means unbounded, matching fit_min = 0 meaning no floor.
// no_measure is what a constraint with no measure callback falls back to —
// callers differ (0 for the flex-distribution passes, the full available
// span for a lone stack child) so it isn't baked in here.
fn sz resolve_fit(Constraint c, sz cross, sz no_measure = 0) @private {
	sz size = c.measure ? c.measure(c.ctx, cross) : no_measure;
	if (size < 0) size = 0;
	if (size < c.fit_min) size = c.fit_min;
	if (c.fit_max > 0 && size > c.fit_max) size = c.fit_max;
	return size;
}

fn sz layout_axis_cross(sz total, sz gap, sz cross, Constraint[] cs, sz[] out_sizes) @local {
	sz n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	// Calculate available space after gaps
	sz gap_count = n > 1 ? n - 1 : 0;
	sz available = total - gap * gap_count;
	if (available < 0) available = 0;

	// Initialize sizes array on stack
	sz[64] sizes;
	for (sz i = 0; i < n; i++) {
		sizes[i] = 0;
	}

	sz fixed             = 0;
	sz fill_weight_total = 0;
	sz[64] max_caps;
	bool[64] is_fill;

	// Pass 1: assign fixed sizes and calculate fill weights
	for (sz i = 0; i < n; i++) {
		max_caps[i] = 0;
		is_fill[i] = false;

		switch (cs[i].kind) {
			case ConstraintKind.CLEN:
				sz len_val = cs[i].value;
				if (len_val < 0) len_val = 0;
				if (len_val > available) len_val = available;
				sizes[i] = len_val;
				fixed += len_val;

			case ConstraintKind.CMIN:
				// A floor a sibling fill() doesn't have to compete with: real
				// flexbox/ratatui treat min-width and flex-grow as orthogonal
				// — a min-width item with no grow factor of its own does not
				// expand just because it has a floor, it only ever gets more
				// than its minimum from space nothing else claims (see the
				// remainder pass below, which offers leftovers to CMIN only
				// when no CFILL sibling exists to take them first).
				sz min_val = cs[i].value;
				if (min_val < 0) min_val = 0;
				if (min_val > available) min_val = available;
				sizes[i] = min_val;
				fixed += min_val;

			case ConstraintKind.CPERCENT:
				sz pct_sz = available * cs[i].value / 100;
				sizes[i] = pct_sz;
				fixed += pct_sz;

			case ConstraintKind.CFIT:
				sz fit_sz = resolve_fit(cs[i], cross);
				if (fit_sz > available) fit_sz = available;
				sizes[i] = fit_sz;
				fixed += fit_sz;

			case ConstraintKind.CMAX:
				sizes[i] = 0;
				sz cap_val = cs[i].value;
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

	// Pass 2: distribute remaining space among fill/max children. CMIN sits
	// this out — see the note in Pass 1 — so it never competes here, only
	// CFILL and CMAX (a cap is still a kind of flexibility: it grows until
	// it hits its ceiling).
	for (sz iter = 0; iter < 4; iter++) {
		sz remaining = available - fixed;
		if (remaining <= 0 || fill_weight_total <= 0) break;

		bool clamped = false;

		for (sz i = 0; i < n; i++) {
			if (cs[i].kind == ConstraintKind.CFILL) {
				sz weight = cs[i].value;
				sz share  = remaining * weight / fill_weight_total;
				sizes[i] = share;
			} else if (cs[i].kind == ConstraintKind.CMAX) {
				sz weight = 1;
				sz share  = remaining * weight / fill_weight_total;
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
		for (sz i = 0; i < n; i++) {
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

	// Distribute any remainder to the last fill child — or, when nothing on
	// the axis has a real grow factor at all, to the last CMIN child, so an
	// min(n) row with no fill() sibling still absorbs slack instead of
	// leaving a gap. Real flex-grow always wins when both are present: a
	// min-width item does not expand just because it has a floor, only
	// because nothing else claimed the space (same as CSS/ratatui).
	sz final_total = 0;
	for (sz i = 0; i < n; i++) {
		if (sizes[i] < 0) sizes[i] = 0;
		final_total += sizes[i];
	}
	bool has_fill_or_max = false;
	foreach (c : cs) {
		if (c.kind == ConstraintKind.CFILL || c.kind == ConstraintKind.CMAX) { has_fill_or_max = true; break; }
	}
	// Distribute integer-division leftovers to flexible children, last one
	// first. A CMAX child only absorbs up to its cap, so we keep scanning
	// backwards until the remainder is placed or no candidate has room —
	// dumping it unconditionally on the last flexible child would silently
	// defeat that child's cap.
	sz remainder = available - final_total;
	for (sz i = n - 1; i >= 0 && remainder > 0; i--) {
		if (cs[i].kind == ConstraintKind.CFILL) {
			sizes[i] += remainder;
			remainder = 0;
		} else if (cs[i].kind == ConstraintKind.CMAX) {
			sz room = max_caps[i] - sizes[i];
			if (room <= 0) continue;
			sz take = room < remainder ? room : remainder;
			sizes[i] += take;
			remainder -= take;
		} else if (cs[i].kind == ConstraintKind.CMIN && !has_fill_or_max) {
			sizes[i] += remainder;
			remainder = 0;
		}
	}

	// Copy to output, clamping the running total to the axis budget. Fixed
	// constraints (CLEN/CMIN/CPERCENT/CFIT) are individually capped at
	// `available` but can still oversubscribe it collectively — e.g. two
	// min(40) children in a 30-wide area. Truncating here keeps the
	// caller's invariant that every returned rect lies inside `area`, so
	// downstream drawing never runs past the parent.
	sz used = 0;
	for (sz i = 0; i < n; i++) {
		sz size = sizes[i] < 0 ? 0 : sizes[i];
		sz room = available - used;
		if (room < 0) room = 0;
		if (size > room) size = room;
		out_sizes[i] = size;
		used += size;
	}

	return n;
}

fn sz layout_h(Rect area, Constraint[] cs, Rect[] out_rects) {
	return layout_h_gap(area, cs, 0, out_rects);
}

fn sz layout_v(Rect area, Constraint[] cs, Rect[] out_rects) {
	return layout_v_gap(area, cs, 0, out_rects);
}

fn sz layout_h_gap(Rect area, Constraint[] cs, sz gap, Rect[] out_rects) {
	sz n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	sz[64] sizes;
	sz n_computed = layout_axis_cross(area.w, gap, area.h, cs[0:n], sizes[0:n]);

	sz offset = 0;
	for (sz i = 0; i < n_computed; i++) {
		out_rects[i] = { .x = area.x + offset, .y = area.y, .w = sizes[i], .h = area.h };
		offset += sizes[i] + gap;
	}

	return n_computed;
}

fn sz layout_v_gap(Rect area, Constraint[] cs, sz gap, Rect[] out_rects) {
	sz n = cs.len;
	if (n == 0) return 0;
	if (n > 64) n = 64;

	sz[64] sizes;
	sz n_computed = layout_axis_cross(area.h, gap, area.w, cs[0:n], sizes[0:n]);

	sz offset = 0;
	for (sz i = 0; i < n_computed; i++) {
		out_rects[i] = { .x = area.x, .y = area.y + offset, .w = area.w, .h = sizes[i] };
		offset += sizes[i] + gap;
	}

	return n_computed;
}
