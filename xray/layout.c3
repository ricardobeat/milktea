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
	int value;
	MeasureFn measure; // only used when kind == CFIT
	void* ctx; // passed to measure
}

fn Constraint constraint_len(int n) {
	return { .kind = ConstraintKind.CLEN, .value = n };
}

fn Constraint constraint_min(int n) {
	return { .kind = ConstraintKind.CMIN, .value = n };
}

fn Constraint constraint_max(int n) {
	return { .kind = ConstraintKind.CMAX, .value = n };
}

fn Constraint constraint_percent(int p) {
	return { .kind = ConstraintKind.CPERCENT, .value = p };
}

fn Constraint constraint_fill(int weight) {
	return { .kind = ConstraintKind.CFILL, .value = weight };
}

fn Constraint constraint_fit(MeasureFn measure, void* ctx) {
	return { .kind = ConstraintKind.CFIT, .measure = measure, .ctx = ctx };
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
				sizes[i] = cs[i].value;
				fixed += cs[i].value;

			case ConstraintKind.CPERCENT:
				int pct_sz = available * cs[i].value / 100;
				sizes[i] = pct_sz;
				fixed += pct_sz;

			case ConstraintKind.CFIT:
				int fit_sz = cs[i].measure ? cs[i].measure(cs[i].ctx, cross) : 0;
				if (fit_sz < 0) fit_sz = 0;
				if (fit_sz > available) fit_sz = available;
				sizes[i] = fit_sz;
				fixed += fit_sz;

			case ConstraintKind.CMAX:
				sizes[i] = 0;
				max_caps[i] = cs[i].value;
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
	int remainder = available - final_total;
	if (remainder > 0) {
		for (int i = n - 1; i >= 0; i--) {
			if (cs[i].kind == ConstraintKind.CFILL || cs[i].kind == ConstraintKind.CMAX) {
				sizes[i] += remainder;
				break;
			}
		}
	}

	// Copy to output and clamp
	for (int i = 0; i < n; i++) {
		if (sizes[i] < 0) sizes[i] = 0;
		out_sizes[i] = sizes[i];
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

import std::core::mem;

enum FlexDirection : char {
	ROW,
	COLUMN
}
enum JustifyContent : char {
	JUSTIFY_START,
	JUSTIFY_CENTER,
	JUSTIFY_END,
	JUSTIFY_SPACE_BETWEEN,
	JUSTIFY_SPACE_AROUND,
	JUSTIFY_SPACE_EVENLY
}
enum AlignItems : char {
	ALIGN_STRETCH,
	ALIGN_START,
	ALIGN_CENTER,
	ALIGN_END
}

const int MAX_FLEX_CHILDREN = 32;

struct FlexNode {
	Constraint main_size; // size along main axis (default: CFILL weight=1)
	Constraint cross_size; // size along cross axis (default: CFILL weight=1 = stretch)

	FlexNode*[MAX_FLEX_CHILDREN] children;
	int child_count;

	FlexDirection direction; // ROW or COLUMN
	JustifyContent justify; // default: JUSTIFY_START
	AlignItems align; // default: ALIGN_STRETCH
	int gap; // gap between children in cells

	int pad_top, pad_right, pad_bottom, pad_left;

	Rect computed_rect; // filled by solve()
}

// Constructors - all temp-allocated with sensible defaults
fn FlexNode* flex_node() {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_fill(1);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_row() {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_fill(1);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_col() {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_fill(1);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.COLUMN;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_len(int n) {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_len(n);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_fill(int w) {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_fill(w);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_percent(int p) {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_percent(p);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_min(int n) {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_min(n);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

fn FlexNode* flex_max(int n) {
	FlexNode* node = mem::tnew(FlexNode);
	node.main_size = constraint_max(n);
	node.cross_size = constraint_fill(1);
	node.direction = FlexDirection.ROW;
	node.justify = JustifyContent.JUSTIFY_START;
	node.align = AlignItems.ALIGN_STRETCH;
	return node;
}

// Builder methods - return self for chaining
fn FlexNode* FlexNode.add(&self, FlexNode* child) {
	if (self.child_count < MAX_FLEX_CHILDREN) {
		self.children[self.child_count++] = child;
	}
	return self;
}

fn FlexNode* FlexNode.with_direction(&self, FlexDirection d) {
	self.direction = d;
	return self;
}

fn FlexNode* FlexNode.with_justify(&self, JustifyContent j) {
	self.justify = j;
	return self;
}

fn FlexNode* FlexNode.with_align(&self, AlignItems a) {
	self.align = a;
	return self;
}

fn FlexNode* FlexNode.with_gap(&self, int g) {
	self.gap = g;
	return self;
}

fn FlexNode* FlexNode.with_padding(&self, int top, int right, int bottom, int left) {
	self.pad_top = top;
	self.pad_right = right;
	self.pad_bottom = bottom;
	self.pad_left = left;
	return self;
}

fn FlexNode* FlexNode.with_main_size(&self, Constraint c) {
	self.main_size = c;
	return self;
}

fn FlexNode* FlexNode.with_cross_size(&self, Constraint c) {
	self.cross_size = c;
	return self;
}

// Solve layout for this node and its children
fn void FlexNode.solve(&self, Rect area) {
	self.computed_rect = area;

	if (self.child_count == 0) return;

	// Apply padding
	Rect inner = area.inset(self.pad_top, self.pad_right, self.pad_bottom, self.pad_left);

	// Build constraints and output rects arrays
	Constraint[MAX_FLEX_CHILDREN] constraints;
	Rect[MAX_FLEX_CHILDREN] child_rects;

	for (int i = 0; i < self.child_count; i++) {
		constraints[i] = self.children[i].main_size;
	}

	// Perform layout based on direction
	int cc = self.child_count;
	if (self.direction == FlexDirection.ROW) {
		layout_h_gap(inner, constraints[0:cc], self.gap, child_rects[0:cc]);
	} else {
		layout_v_gap(inner, constraints[0:cc], self.gap, child_rects[0:cc]);
	}

	// Calculate content size along main axis
	int content_size = 0;
	for (int i = 0; i < self.child_count; i++) {
		if (self.direction == FlexDirection.ROW) {
			content_size += child_rects[i].w;
		} else {
			content_size += child_rects[i].h;
		}
	}
	if (self.child_count > 1) {
		content_size += self.gap * (self.child_count - 1);
	}

	// Get main axis total
	int main_total = self.direction == FlexDirection.ROW ? inner.w : inner.h;
	int spare      = main_total - content_size;
	if (spare < 0) spare = 0;

	// Apply JustifyContent offset adjustment
	for (int i = 0; i < self.child_count; i++) {
		int offset = 0;

		switch (self.justify) {
			case JustifyContent.JUSTIFY_START:
				offset = 0;

			case JustifyContent.JUSTIFY_END:
				offset = spare;

			case JustifyContent.JUSTIFY_CENTER:
				offset = spare / 2;

			case JustifyContent.JUSTIFY_SPACE_BETWEEN:
				if (self.child_count > 1) {
					offset = spare * i / (self.child_count - 1);
				}

			case JustifyContent.JUSTIFY_SPACE_AROUND:
				offset = spare * (2 * i + 1) / (2 * self.child_count);

			case JustifyContent.JUSTIFY_SPACE_EVENLY:
				offset = spare * (i + 1) / (self.child_count + 1);

			default:
				break;
		}

		if (self.direction == FlexDirection.ROW) {
			child_rects[i].x += offset;
		} else {
			child_rects[i].y += offset;
		}
	}

	// Apply AlignItems - set cross-axis position and size
	int cross_total = self.direction == FlexDirection.ROW ? inner.h : inner.w;

	for (int i = 0; i < self.child_count; i++) {
		if (self.align == AlignItems.ALIGN_STRETCH) {
			if (self.direction == FlexDirection.ROW) {
				child_rects[i].h = cross_total;
				child_rects[i].y = inner.y;
			} else {
				child_rects[i].w = cross_total;
				child_rects[i].x = inner.x;
			}
		} else {
			// Resolve cross_size constraint
			int cross_size = 0;
			switch (self.children[i].cross_size.kind) {
				case ConstraintKind.CLEN:
					cross_size = self.children[i].cross_size.value;

				case ConstraintKind.CMIN:
					cross_size = self.children[i].cross_size.value;
					if (cross_size < 0) cross_size = 0;

				case ConstraintKind.CMAX:
					cross_size = self.children[i].cross_size.value;
					if (cross_size > cross_total) cross_size = cross_total;

				case ConstraintKind.CPERCENT:
					cross_size = cross_total * self.children[i].cross_size.value / 100;

				case ConstraintKind.CFILL:
					cross_size = cross_total;

				default:
					cross_size = cross_total;
			}

			// Position based on align
			if (self.direction == FlexDirection.ROW) {
				if (self.align == AlignItems.ALIGN_START) {
					child_rects[i].y = inner.y;
					child_rects[i].h = cross_size;
				} else if (self.align == AlignItems.ALIGN_CENTER) {
					int extra = cross_total - cross_size;
					child_rects[i].y = inner.y + extra / 2;
					child_rects[i].h = cross_size;
				} else if (self.align == AlignItems.ALIGN_END) {
					child_rects[i].y = inner.y + cross_total - cross_size;
					child_rects[i].h = cross_size;
				}
			} else {
				if (self.align == AlignItems.ALIGN_START) {
					child_rects[i].x = inner.x;
					child_rects[i].w = cross_size;
				} else if (self.align == AlignItems.ALIGN_CENTER) {
					int extra = cross_total - cross_size;
					child_rects[i].x = inner.x + extra / 2;
					child_rects[i].w = cross_size;
				} else if (self.align == AlignItems.ALIGN_END) {
					child_rects[i].x = inner.x + cross_total - cross_size;
					child_rects[i].w = cross_size;
				}
			}
		}
	}

	// Set child computed rects and recurse
	for (int i = 0; i < self.child_count; i++) {
		self.children[i].solve(child_rects[i]);
	}
}

// Accessors
fn Rect FlexNode.rect(&self) => self.computed_rect;

fn Rect FlexNode.child_rect(&self, int idx) {
	if (idx < 0 || idx >= self.child_count) return { };
	return self.children[idx].computed_rect;
}

fn int FlexNode.count(&self) => self.child_count;