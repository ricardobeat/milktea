module milktea;

import xray;
import std::core::mem;

// ============================================================
// Layer — a rectangular piece of content with position and z-order.
// ============================================================

const sz MAX_CHILDREN = 16;

struct Layer {
	String id;
	String content;
	int x;
	int y;
	int z;
	Layer*[MAX_CHILDREN] children;
	sz child_count;
}

// new_layer creates a new layer with the given content.
fn Layer* new_layer(String content) {
	Layer* l = mem::new(Layer);
	l.content = content;
	l.x = 0;
	l.y = 0;
	l.z = 0;
	l.child_count = 0;
	return l;
}

fn Layer* Layer.set_x(Layer* self, int x) {
	self.x = x;
	return self;
}

fn Layer* Layer.set_y(Layer* self, int y) {
	self.y = y;
	return self;
}

fn Layer* Layer.set_z(Layer* self, int z) {
	self.z = z;
	return self;
}

fn Layer* Layer.set_id(Layer* self, String id) {
	self.id = id;
	return self;
}

fn Layer* Layer.add_layers(Layer* self, Layer* child) {
	if (self.child_count < MAX_CHILDREN) {
		self.children[self.child_count] = child;
		self.child_count++;
	}
	return self;
}

fn int Layer.get_x(&self) => self.x;
fn int Layer.get_y(&self) => self.y;
fn int Layer.get_z(&self) => self.z;
fn String Layer.get_id(&self) => self.id;
fn String Layer.get_content(&self) => self.content;

// ============================================================
// Compositor — composites multiple layers in z-order onto a canvas.
// ============================================================

struct CompositeEntry {
	Layer* layer;
	int abs_x;
	int abs_y;
}

const sz MAX_LAYERS = 32;

struct Compositor {
	Layer* root;
	CompositeEntry[MAX_LAYERS] entries;
	sz entry_count;
	int width;
	int height;
	// Reusable heap-allocated cell grid; resized on demand.
	xray::Cell* cells;
	sz cells_cap;
}

// new_compositor creates a compositor with explicit canvas dimensions.
fn Compositor* new_compositor(int w, int h) {
	Compositor* c = mem::new(Compositor);
	c.root = new_layer("");
	c.entry_count = 0;
	c.width = w;
	c.height = h;
	c.cells = null;
	c.cells_cap = 0;
	return c;
}

fn void Compositor.add_layer(Compositor* self, Layer* layer) {
	self.root.add_layers(layer);
	self.flatten();
}

fn void Compositor.refresh(Compositor* self) {
	self.flatten();
}

// flatten walks the layer tree and builds a sorted flat list.
fn void Compositor.flatten(Compositor* self) {
	self.entry_count = 0;
	self.flatten_recursive(self.root, 0, 0);

	// Sort by z (bubble sort — small N)
	for (sz i = 0; i < self.entry_count; i++) {
		for (sz j = i + 1; j < self.entry_count; j++) {
			if (self.entries[j].layer.z < self.entries[i].layer.z) {
				CompositeEntry tmp = self.entries[i];
				self.entries[i] = self.entries[j];
				self.entries[j] = tmp;
			}
		}
	}
}

fn void Compositor.flatten_recursive(Compositor* self, Layer* layer, int parent_x, int parent_y) {
	int abs_x = layer.x + parent_x;
	int abs_y = layer.y + parent_y;

	// Don't add the invisible root layer
	if (layer != self.root || layer.content.len > 0) {
		if (self.entry_count < MAX_LAYERS) {
			self.entries[self.entry_count] = {
				.layer = layer,
				.abs_x = abs_x,
				.abs_y = abs_y,
			};
			self.entry_count++;
		}
	}

	for (sz i = 0; i < layer.child_count; i++) {
		self.flatten_recursive(layer.children[i], abs_x, abs_y);
	}
}

// render composites all layers onto an xray::Cell grid and returns a View.
// The view uses the direct cell path (alt_screen = true).
// The cell grid is owned by the Compositor and is valid until the next render().
fn View Compositor.render(Compositor* self) {
	int w = self.width;
	int h = self.height;
	if (w <= 0 || h <= 0) return { .alt_screen = true };
	if (self.entry_count == 0) return { .alt_screen = true };

	sz total = (sz)w * (sz)h;

	// Grow the internal cell buffer if needed.
	if (total > self.cells_cap) {
		if (self.cells != null) mem::free(self.cells);
		self.cells = mem::new_array(xray::Cell, total);
		self.cells_cap = total;
	}

	// Initialize all cells to the default empty cell (space, no style).
	xray::Cell empty = xray::empty_cell();
	for (sz i = 0; i < total; i++) {
		self.cells[i] = empty;
	}

	// Draw each layer in z-order.
	for (sz i = 0; i < self.entry_count; i++) {
		CompositeEntry* e = &self.entries[i];
		compositor_draw_layer(self.cells, w, h, e);
	}

	return {
		.cells        = self.cells[:total],
		.cells_width  = (sz)w,
		.cells_height = (sz)h,
		.alt_screen   = true,
	};
}

// compositor_draw_layer paints one layer's ANSI content into the cell grid
// by rendering it into a temporary ScreenBuffer and copying affected cells.
fn void compositor_draw_layer(xray::Cell* grid, int canvas_w, int canvas_h, CompositeEntry* e) @local {
	String content = e.layer.content;
	if (content.len == 0) return;

	int abs_x = e.abs_x;
	int abs_y = e.abs_y;

	// Clamp offset so the layer is at least partially visible.
	if (abs_x >= canvas_w || abs_y >= canvas_h) return;

	// Available space on the canvas from the layer origin.
	int avail_w = canvas_w - abs_x;
	int avail_h = canvas_h - abs_y;
	if (avail_w <= 0 || avail_h <= 0) return;

	// Render the layer ANSI string into a temporary ScreenBuffer.
	xray::ScreenBuffer* tmp = xray::new_screen_buffer((sz)avail_w, (sz)avail_h);
	defer {
		tmp.destroy();
		mem::free(tmp);
	}
	tmp.render_ansi_string(0, 0, content, xray::default_style());

	// Copy written cells into the output grid.
	for (int r = 0; r < avail_h; r++) {
		int dst_row = abs_y + r;
		if (dst_row < 0 || dst_row >= canvas_h) continue;
		for (int c = 0; c < avail_w; c++) {
			int dst_col = abs_x + c;
			if (dst_col < 0 || dst_col >= canvas_w) continue;
			xray::Cell src = tmp.cells[(sz)r * (sz)avail_w + (sz)c];
			// Skip unwritten cells (empty space with no style) so lower
			// layers show through transparent regions.
			if (src.content_len == 1 && src.content[0] == ' ' && src.style.is_empty()) continue;
			grid[(sz)dst_row * (sz)canvas_w + (sz)dst_col] = src;
		}
	}
}
