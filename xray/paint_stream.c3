module xray;

// Recorded before cell compositing, so transparent backgrounds keep the
// vector surface beneath them instead of inheriting a flattened cell colour.
enum PaintKind : char { CELL, DECORATION, TINT }

struct PaintOp {
	PaintKind kind;
	sz col, row;
	bool pixels;
	sz bg_w, bg_h;
	Cell cell;
	Decoration decoration;
	Color tint;
}

// The recorder is reached only through these hooks, which record_paints
// installs, so a terminal build that never records links none of it.
alias RecordBeginFn = fn void(ScreenBuffer* buf);
alias RecordCellFn = fn void(ScreenBuffer* buf, sz col, sz row, Cell cell);
alias RecordTintFn = fn void(ScreenBuffer* buf, sz col, sz row, Color tint);
alias RecordDecorationFn = fn void(ScreenBuffer* buf, Node* n);

struct PaintRecorder {
	RecordBeginFn begin;
	RecordCellFn cell;
	RecordTintFn tint;
	RecordDecorationFn decoration;
}

PaintRecorder paint_recorder;

// enable_paint_recording installs the recorder. A buffer records once its
// record_paint is also set; record_paints does both.
fn void enable_paint_recording() {
	paint_recorder = { &recorder_begin, &recorder_cell, &recorder_tint, &recorder_decoration };
}

fn void ScreenBuffer.record_paints(&self, bool on = true) {
	enable_paint_recording();
	self.record_paint = on;
}

fn bool ScreenBuffer.recording(&self) @inline => self.record_paint && paint_recorder.cell != null;

fn void ScreenBuffer.record_begin(&self) @inline {
	if (self.recording()) paint_recorder.begin(self);
}

fn void ScreenBuffer.record_cell(&self, sz col, sz row, Cell cell) @inline {
	if (self.recording()) paint_recorder.cell(self, col, row, cell);
}

fn void ScreenBuffer.record_tint(&self, sz col, sz row, Color tint) @inline {
	if (self.recording()) paint_recorder.tint(self, col, row, tint);
}

fn void ScreenBuffer.record_decoration(&self, Node* n) @inline {
	if (self.recording() && n.decoration.kind != DecorationKind.NONE) paint_recorder.decoration(self, n);
}

fn void recorder_begin(ScreenBuffer* self) @local {
	if (!self.paint_ops.is_initialized()) self.paint_ops.init(mem);
	self.paint_ops.clear();
}

fn void recorder_decoration(ScreenBuffer* self, Node* n) @local {
	Decoration d = n.decoration;
	d.rect = n.computed_rect;
	d.pixel_rect = n.layout_metrics.pixels;
	self.paint_ops.push({ .kind = PaintKind.DECORATION, .decoration = d });
}

fn void recorder_cell(ScreenBuffer* self, sz col, sz row, Cell cell) @local {
	if (self.decorated_content) cell.style.bg = color_transparent();
	sz w = self.paint_metrics.unit_w();
	sz h = self.paint_metrics.unit_h();
	sz x = (sz)col * w + self.paint_dx;
	sz y = (sz)row * h + self.paint_dy;
	sz bg_w = w;
	sz bg_h = h;
	// The last whole text cell carries the background into the unused pixel strip.
	if (self.paint_metrics.pixels) {
		if (x + w <= self.paint_extent.right() && x + w * 2 > self.paint_extent.right()) {
			bg_w = self.paint_extent.right() - x;
		}
		if (y + h <= self.paint_extent.bottom() && y + h * 2 > self.paint_extent.bottom()) {
			bg_h = self.paint_extent.bottom() - y;
		}
	}
	if (self.paint_metrics.pixels) {
		sz glyph_w = cell.width > 1 ? w * (sz)cell.width : w;
		sz visible_w = glyph_w > bg_w ? glyph_w : bg_w;
		if (x + visible_w <= 0 || y + bg_h <= 0
			|| x >= self.width * w || y >= self.height * h) return;
	}
	self.paint_ops.push({ .kind = PaintKind.CELL, .col = x,
		.row = y, .cell = cell, .pixels = self.paint_metrics.pixels,
		.bg_w = bg_w, .bg_h = bg_h });
}

fn void recorder_tint(ScreenBuffer* self, sz col, sz row, Color tint) @local {
	self.paint_ops.push({ .kind = PaintKind.TINT, .col = col * self.paint_metrics.unit_w() + self.paint_dx,
		.row = row * self.paint_metrics.unit_h() + self.paint_dy, .tint = tint,
		.pixels = self.paint_metrics.pixels });
}
