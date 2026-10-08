module xray;

// Zero-initialized metrics retain terminal cell coordinates.
struct LayoutMetrics {
	bool pixels;
	int cell_w, cell_h;
}

fn int LayoutMetrics.unit_w(self) => self.pixels && self.cell_w > 0 ? self.cell_w : 1;
fn int LayoutMetrics.unit_h(self) => self.pixels && self.cell_h > 0 ? self.cell_h : 1;

fn void Node.set_layout_metrics(&self, LayoutMetrics metrics) {
	self.layout_metrics = metrics;
	for (int i = 0; i < self.child_count; i++) self.children[i].set_layout_metrics(metrics);
}

fn int Node.layout_gap(&self) {
	return self.gap * (self.direction == NodeDirection.ROW
		? self.layout_metrics.unit_w() : self.layout_metrics.unit_h());
}

fn Constraint Node.layout_constraint(&self, bool horizontal) {
	Constraint c = horizontal ? self.size_w : self.size_h;
	if (!self.layout_metrics.pixels) {
		if (c.pixel_units) c.value = c.cell_fallback;
		return c;
	}
	int unit = horizontal ? self.layout_metrics.unit_w() : self.layout_metrics.unit_h();
	int pad = horizontal ? self.decoration.pad_left + self.decoration.pad_right
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

fn int pixel_measure_w(void* ctx, int height) @local {
	Node* n = (Node*)ctx;
	Constraint c = n.size_w;
	if (c.measure == &node_measure_w && c.ctx == n) return n.content_width(height);
	int pad = n.decoration.pad_left + n.decoration.pad_right;
	height -= n.decoration.pad_top + n.decoration.pad_bottom;
	if (height < 0) height = 0;
	return (c.measure ? c.measure(c.ctx, height / n.layout_metrics.unit_h()) : 0)
		* n.layout_metrics.unit_w() + pad;
}

fn int pixel_measure_h(void* ctx, int width) @local {
	Node* n = (Node*)ctx;
	Constraint c = n.size_h;
	if (c.measure == &node_measure_h && c.ctx == n) return n.content_height(width);
	int pad = n.decoration.pad_top + n.decoration.pad_bottom;
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
	int w = self.layout_metrics.unit_w();
	int h = self.layout_metrics.unit_h();
	return { .x = floor_cell(r.x, w), .y = floor_cell(r.y, h),
		.w = r.w / w, .h = r.h / h };
}

fn int floor_cell(int value, int unit) {
	return value >= 0 ? value / unit : -((-value + unit - 1) / unit);
}
