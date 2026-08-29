module xray;

// Natural sizing.
//
// A node's natural size is what it wants when nothing constrains it: for a
// leaf, whatever its Content reports; for a column, the sum of its children's
// heights and the width of its widest child; for a row, the other way around.
//
// It is used in two places — CFIT sizing, which is what place() and center()
// produce, and draw_inline, which has to know how tall a tree is before it
// can pick a rect to solve against.
//
// A fill child has no natural size of its own, so it contributes what its
// content needs instead of expanding. That is what makes fill degrade to
// fit-to-content in a container with no fixed size: there is no leftover
// space to divide when the container's own size came from its children.

fn int constraint_natural(Constraint c, int other, int fallback) @local {
	switch (c.kind) {
		case ConstraintKind.CLEN:
		case ConstraintKind.CMIN:
			return c.value;
		case ConstraintKind.CMAX:
			return c.value < fallback ? c.value : fallback;
		case ConstraintKind.CPERCENT:
			// A percentage of an unknown total is unknowable, so fall back to
			// what the content wants.
			return fallback;
		case ConstraintKind.CFIT:
			return resolve_fit(c, other, fallback);
		default:
			return fallback;
	}
}

// natural_width is how wide this node wants to be, given the height available.
fn int Node.natural_width(&self, int height) {
	return constraint_natural(self.size_w, height, self.content_width(height));
}

// natural_height is how tall this node wants to be, given the width available.
fn int Node.natural_height(&self, int width) {
	return constraint_natural(self.size_h, width, self.content_height(width));
}

// content_width measures what is inside this node, ignoring the node's own
// width constraint.
fn int Node.content_width(&self, int height) {
	int pad_x = self.pad_left + self.pad_right;
	int inner_h = height - self.pad_top - self.pad_bottom;
	if (inner_h < 0) inner_h = 0;

	if (self.child_count == 0) {
		int n = 0;
		if (self.content != null && &self.content.measure_width) {
			n = self.content.measure_width(inner_h);
		}
		return n + pad_x;
	}

	int total = 0;
	if (self.direction == NodeDirection.ROW) {
		// Side by side: widths add up.
		for (int i = 0; i < self.child_count; i++) {
			total += self.children[i].natural_width(inner_h);
		}
		if (self.child_count > 1) total += self.gap * (self.child_count - 1);
	} else {
		// Stacked or layered: as wide as the widest child.
		for (int i = 0; i < self.child_count; i++) {
			int n = self.children[i].natural_width(inner_h);
			if (n > total) total = n;
		}
	}
	return total + pad_x;
}

// content_height measures what is inside this node, ignoring the node's own
// height constraint.
fn int Node.content_height(&self, int width) {
	int pad_y = self.pad_top + self.pad_bottom;
	int inner_w = width - self.pad_left - self.pad_right;
	if (inner_w < 0) inner_w = 0;

	if (self.child_count == 0) {
		int n = 0;
		if (self.content != null && &self.content.measure) {
			n = self.content.measure(inner_w);
		}
		return n + pad_y;
	}

	int total = 0;
	if (self.direction == NodeDirection.COLUMN) {
		// Stacked: heights add up.
		for (int i = 0; i < self.child_count; i++) {
			total += self.children[i].natural_height(inner_w);
		}
		if (self.child_count > 1) total += self.gap * (self.child_count - 1);
	} else {
		// Side by side or layered: as tall as the tallest child.
		for (int i = 0; i < self.child_count; i++) {
			int n = self.children[i].natural_height(inner_w);
			if (n > total) total = n;
		}
	}
	return total + pad_y;
}

// MeasureFn adapters, so a CFIT constraint can point back at the node it
// belongs to. The solver passes the size available on the other axis.
fn int node_measure_w(void* ctx, int height) {
	return ((Node*)ctx).content_width(height);
}

fn int node_measure_h(void* ctx, int width) {
	return ((Node*)ctx).content_height(width);
}

// solve assigns every node in the tree a rect inside area.
fn void Node.solve(&self, Rect area) {
	self.computed_rect = area;

	if (self.child_count == 0) return;

	Rect inner = area.inset(self.pad_left, self.pad_top, self.pad_right, self.pad_bottom);

	// A stack gives each child the full inner rect, subject to that child's
	// own constraints and its own justify/align — which is how a centered
	// modal ends up sized to its content in the middle of the screen.
	if (self.direction == NodeDirection.STACK) {
		for (int i = 0; i < self.child_count; i++) {
			self.children[i].solve(self.stack_child_rect(inner, self.children[i]));
		}
		return;
	}

	bool row = self.direction == NodeDirection.ROW;
	int cc = self.child_count;

	Constraint[MAX_NODE_CHILDREN] constraints;
	Rect[MAX_NODE_CHILDREN] child_rects;

	// The main axis belongs to the parent, so it picks which of each child's
	// two constraints applies along it.
	for (int i = 0; i < cc; i++) {
		constraints[i] = row ? self.children[i].size_w : self.children[i].size_h;
	}

	if (row) {
		layout_h_gap(inner, constraints[0:cc], self.gap, child_rects[0:cc]);
	} else {
		layout_v_gap(inner, constraints[0:cc], self.gap, child_rects[0:cc]);
	}

	// Main-axis justification: shift the solved rects within whatever space
	// the children did not claim.
	int content_size = 0;
	for (int i = 0; i < cc; i++) {
		content_size += row ? child_rects[i].w : child_rects[i].h;
	}
	if (cc > 1) content_size += self.gap * (cc - 1);

	int spare = (row ? inner.w : inner.h) - content_size;
	if (spare < 0) spare = 0;

	for (int i = 0; i < cc; i++) {
		int offset = justify_offset(self.justify, spare, i, cc);
		if (row) {
			child_rects[i].x += offset;
		} else {
			child_rects[i].y += offset;
		}
	}

	// Cross-axis alignment and sizing.
	int cross_total  = row ? inner.h : inner.w;
	int cross_origin = row ? inner.y : inner.x;

	for (int i = 0; i < cc; i++) {
		Constraint cross = row ? self.children[i].size_h : self.children[i].size_w;
		int main_size = row ? child_rects[i].w : child_rects[i].h;

		// ALIGN_STRETCH means "fill the cross axis", but a child that asked
		// for a specific cross size still gets it — otherwise .with_width(30)
		// inside a vstack would be silently ignored, since stretch is the
		// default alignment.
		int size = cross_total;
		if (self.align != AlignItems.ALIGN_STRETCH || cross.kind != ConstraintKind.CFILL) {
			size = resolve_axis(cross, cross_total, main_size);
		}
		if (size > cross_total) size = cross_total;
		if (size < 0) size = 0;

		int pos = cross_origin + align_offset(self.align, cross_total - size);

		if (row) {
			child_rects[i].y = pos;
			child_rects[i].h = size;
		} else {
			child_rects[i].x = pos;
			child_rects[i].w = size;
		}
	}

	for (int i = 0; i < cc; i++) {
		self.children[i].solve(child_rects[i]);
	}
}

// stack_child_rect sizes and places one child of a zstack inside area. A
// child that fills gets the whole rect; one with a real constraint on either
// axis gets that size, positioned by its own justify (horizontally) and align
// (vertically) — which is what place() sets both of.
fn Rect Node.stack_child_rect(&self, Rect area, Node* child) {
	int w = resolve_axis(child.size_w, area.w, area.h);
	int h = resolve_axis(child.size_h, area.h, area.w);
	if (w > area.w) w = area.w;
	if (h > area.h) h = area.h;
	if (w < 0) w = 0;
	if (h < 0) h = 0;

	// A pinned child names its own offset; everything else is placed by its
	// justify and align within the space it did not fill.
	int x = child.pinned
		? child.offset_x
		: justify_offset(child.justify, area.w - w, 0, 1);
	int y = child.pinned
		? child.offset_y
		: align_offset(child.align, area.h - h);

	return { .x = area.x + x, .y = area.y + y, .w = w, .h = h };
}

// resolve_axis turns one constraint into a size. avail is the space on this
// axis, other the space on the perpendicular one, which CFIT measures against.
fn int resolve_axis(Constraint c, int avail, int other) @local {
	switch (c.kind) {
		case ConstraintKind.CLEN:
		case ConstraintKind.CMIN:
			return c.value;
		case ConstraintKind.CMAX:
			return c.value < avail ? c.value : avail;
		case ConstraintKind.CPERCENT:
			return avail * c.value / 100;
		case ConstraintKind.CFIT:
			return resolve_fit(c, other, avail);
		default:
			return avail;
	}
}

fn int justify_offset(JustifyContent j, int spare, int i, int n) @local {
	if (spare < 0) spare = 0;
	switch (j) {
		case JustifyContent.JUSTIFY_END:
			return spare;
		case JustifyContent.JUSTIFY_CENTER:
			return spare / 2;
		case JustifyContent.JUSTIFY_SPACE_BETWEEN:
			return n > 1 ? spare * i / (n - 1) : 0;
		case JustifyContent.JUSTIFY_SPACE_AROUND:
			return spare * (2 * i + 1) / (2 * n);
		case JustifyContent.JUSTIFY_SPACE_EVENLY:
			return spare * (i + 1) / (n + 1);
		default:
			return 0;
	}
}

fn int align_offset(AlignItems a, int spare) @local {
	if (spare < 0) spare = 0;
	switch (a) {
		case AlignItems.ALIGN_CENTER:
			return spare / 2;
		case AlignItems.ALIGN_END:
			return spare;
		default:
			return 0;
	}
}
