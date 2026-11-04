module xray;

// Zero-initialized metrics retain terminal cell coordinates.
struct LayoutMetrics {
	bool pixels;
	sz cell_w, cell_h;
}

// PixelConstraintFn converts a node's cell constraint into logical pixels.
// pixel_metrics installs it, so a terminal build, which never asks for pixel
// metrics, links none of the pixel layout code.
alias PixelConstraintFn = fn Constraint(Node* n, Constraint c, bool horizontal);

PixelConstraintFn pixel_constraint_hook;

// pixel_metrics returns metrics for laying a tree out in logical pixels, one
// text cell being cell_w by cell_h of them.
fn LayoutMetrics pixel_metrics(sz cell_w, sz cell_h) {
	pixel_constraint_hook = &pixel_constraint;
	return { .pixels = true, .cell_w = cell_w, .cell_h = cell_h };
}

fn sz LayoutMetrics.unit_w(self) => self.pixels && self.cell_w > 0 ? self.cell_w : 1;
fn sz LayoutMetrics.unit_h(self) => self.pixels && self.cell_h > 0 ? self.cell_h : 1;

fn void Node.set_layout_metrics(&self, LayoutMetrics metrics) {
	self.layout_metrics = metrics;
	for (sz i = 0; i < self.child_count; i++) self.children[i].set_layout_metrics(metrics);
}

fn sz Node.layout_gap(&self) {
	return self.gap * (self.direction == NodeDirection.ROW
		? self.layout_metrics.unit_w() : self.layout_metrics.unit_h());
}

fn Constraint Node.layout_constraint(&self, bool horizontal) {
	Constraint c = horizontal ? self.size_w : self.size_h;
	if (c.kind == ConstraintKind.CFIT && c.measure == null) {
		c.measure = horizontal ? &node_measure_w : &node_measure_h;
		c.ctx = self;
	}
	if (!self.layout_metrics.pixels || !pixel_constraint_hook) {
		if (c.pixel_units) c.value = c.cell_fallback;
		return c;
	}
	return pixel_constraint_hook(self, c, horizontal);
}

fn Constraint pixel_constraint(Node* self, Constraint c, bool horizontal) @local {
	sz unit = horizontal ? self.layout_metrics.unit_w() : self.layout_metrics.unit_h();
	sz pad = horizontal ? self.decoration.pad_left + self.decoration.pad_right
		: self.decoration.pad_top + self.decoration.pad_bottom;
	switch (c.kind) {
		case ConstraintKind.CLEN:
		case ConstraintKind.CMIN:
		case ConstraintKind.CMAX:
			c.value = c.value * (c.pixel_units ? 1 : unit) + pad;
		case ConstraintKind.CFIT:
			if (c.measure != null) {
				c.measure = horizontal ? &pixel_measure_w : &pixel_measure_h;
				c.ctx = self;
			}
			if (c.fit_min > 0) c.fit_min = c.fit_min * unit + pad;
			if (c.fit_max > 0) c.fit_max = c.fit_max * unit + pad;
		default:
	}
	return c;
}

fn sz pixel_measure_w(void* ctx, sz height) @local {
	Node* n = (Node*)ctx;
	Constraint c = n.size_w;
	if (c.measure == &node_measure_w && c.ctx == n) return n.content_width(height);
	sz pad = n.decoration.pad_left + n.decoration.pad_right;
	height -= n.decoration.pad_top + n.decoration.pad_bottom;
	if (height < 0) height = 0;
	return (c.measure ? c.measure(c.ctx, height / n.layout_metrics.unit_h()) : 0)
		* n.layout_metrics.unit_w() + pad;
}

fn sz pixel_measure_h(void* ctx, sz width) @local {
	Node* n = (Node*)ctx;
	Constraint c = n.size_h;
	if (c.measure == &node_measure_h && c.ctx == n) return n.content_height(width);
	sz pad = n.decoration.pad_top + n.decoration.pad_bottom;
	width -= n.decoration.pad_left + n.decoration.pad_right;
	if (width < 0) width = 0;
	return (c.measure ? c.measure(c.ctx, width / n.layout_metrics.unit_w()) : 0)
		* n.layout_metrics.unit_h() + pad;
}

// Content still receives whole text cells; its paint origin retains the
// remainder separately, so a four-pixel inset never snaps to a text column.
fn Rect Node.content_layout_rect(&self) {
	Rect r = self.computed_rect;
	if (self.layout_metrics.pixels) {
		r = r.inset(self.decoration.pad_left, self.decoration.pad_top,
			self.decoration.pad_right, self.decoration.pad_bottom);
	}
	return r;
}

fn Rect Node.content_cell_rect(&self) {
	Rect r = self.content_layout_rect();
	sz w = self.layout_metrics.unit_w();
	sz h = self.layout_metrics.unit_h();
	return { .x = floor_cell(r.x, w), .y = floor_cell(r.y, h),
		.w = r.w / w, .h = r.h / h };
}

fn sz floor_cell(sz value, sz unit) {
	return value >= 0 ? value / unit : -((-value + unit - 1) / unit);
}
