module glaze;

import std::core::dstring;

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

// NewLayer creates a new layer with the given content.
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
	int width;
	int height;
}

const sz MAX_LAYERS = 32;

struct Compositor {
	Layer* root;
	CompositeEntry[MAX_LAYERS] entries;
	sz entry_count;
	int bounds_x;
	int bounds_y;
	int bounds_w;
	int bounds_h;
}

// NewCompositor creates a compositor from a set of layers.
fn Compositor* new_compositor() {
	Compositor* c = mem::new(Compositor);
	c.root = new_layer("");
	c.entry_count = 0;
	return c;
}

fn void Compositor.add_layer(Compositor* self, Layer* layer) {
	self.root.add_layers(layer);
	self.flatten();
}

fn void Compositor.add_layers_variadic(Compositor* self, Layer* a, Layer* b) {
	self.root.add_layers(a);
	self.root.add_layers(b);
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

	// Compute bounds (union of all layer extents)
	self.bounds_x = 0;
	self.bounds_y = 0;
	self.bounds_w = 0;
	self.bounds_h = 0;
	for (sz i = 0; i < self.entry_count; i++) {
		CompositeEntry* e = &self.entries[i];
		int right         = e.abs_x + e.width;
		int bottom        = e.abs_y + e.height;
		if (right > self.bounds_w) self.bounds_w = right;
		if (bottom > self.bounds_h) self.bounds_h = bottom;
	}
}

fn void Compositor.flatten_recursive(Compositor* self, Layer* layer, int parent_x, int parent_y) {
	int abs_x = layer.x + parent_x;
	int abs_y = layer.y + parent_y;
	int w     = string_width(layer.content);
	int h     = count_lines(layer.content);

	// Don't add the invisible root layer
	if (layer != self.root || layer.content.len > 0) {
		if (self.entry_count < MAX_LAYERS) {
			self.entries[self.entry_count] = {
				.layer = layer,
				.abs_x = abs_x,
				.abs_y = abs_y,
				.width = w,
				.height = h
			};
			self.entry_count++;
		}
	}

	for (sz i = 0; i < layer.child_count; i++) {
		self.flatten_recursive(layer.children[i], abs_x, abs_y);
	}
}

// ============================================================
// Cell-grid compositor canvas — each cell stores its own SGR
// prefix so overlays never affect cells they don't write.
// ============================================================

struct CanvasCell {
	char[8] content;
	char    content_len; // 0 = unwritten (space, no style)
	String  sgr;         // raw SGR sequence active at this cell (temp-alloc)
}

const int MAX_CANVAS_W = 512;
const int MAX_CANVAS_H = 200;

// Render composites all layers onto a canvas and returns the result.
fn String Compositor.render(Compositor* self) {
	if (self.entry_count == 0) return "";

	int w = self.bounds_w;
	int h = self.bounds_h;
	if (w <= 0 || h <= 0) return "";
	if (w > MAX_CANVAS_W) w = MAX_CANVAS_W;
	if (h > MAX_CANVAS_H) h = MAX_CANVAS_H;

	// Allocate cell grid on the heap; freed at end of this function.
	sz total         = (sz)w * (sz)h;
	CanvasCell* grid = mem::new_array(CanvasCell, total);
	defer mem::free(grid);

	// Initialize all cells to space with no style.
	for (sz i = 0; i < total; i++) {
		grid[i].content[0]  = ' ';
		grid[i].content_len = 0; // 0 = default space, no sgr needed
		grid[i].sgr         = "";
	}

	// Draw each layer in z-order onto the cell grid.
	for (sz i = 0; i < self.entry_count; i++) {
		CompositeEntry* e = &self.entries[i];
		draw_layer_cells(grid, w, h, e);
	}

	// Serialize cell grid to ANSI string.
	DString out      = dstring::temp();
	String  prev_sgr = "";
	for (int r = 0; r < h; r++) {
		if (r > 0) out.append_char('\n');
		for (int c = 0; c < w; c++) {
			CanvasCell* cell = &grid[(sz)r * (sz)w + (sz)c];
			// Emit SGR only when it changes.
			if (cell.sgr != prev_sgr) {
				if (cell.sgr.len > 0) {
					out.append_string(cell.sgr);
				} else if (prev_sgr.len > 0) {
					// Transitioning back to plain — emit reset.
					out.append_string("\x1b[0m");
				}
				prev_sgr = cell.sgr;
			}
			if (cell.content_len > 0) {
				out.append_string(canvas_cell_str(cell));
			} else {
				out.append_char(' ');
			}
		}
	}
	// Reset at end so styles don't leak into surrounding output.
	if (prev_sgr.len > 0) out.append_string("\x1b[0m");
	return out.str_view();
}

// draw_layer_cells paints a single layer entry into the cell grid.
// ANSI SGR sequences update a running accumulator; non-SGR escape
// sequences are discarded. Each printable cell gets the current
// accumulator as its self-contained style prefix.
fn void draw_layer_cells(CanvasCell* grid, int canvas_w, int canvas_h, CompositeEntry* e) @local {
	String  content  = e.layer.content;
	sz      i        = 0;
	int     row      = e.abs_y;
	int     col      = e.abs_x;
	DString cur_sgr  = dstring::temp();

	while (i < content.len) {
		char b = content[i];

		// ANSI escape sequence
		if (b == '\x1b' && i + 1 < content.len && content[i + 1] == '[') {
			i += 2; // skip ESC [
			sz param_start = i;
			while (i < content.len && ((content[i] >= '0' && content[i] <= '9') || content[i] == ';')) {
				i++;
			}
			if (i >= content.len) break;
			char final_byte = content[i];
			i++;
			if (final_byte == 'm') {
				String params = content[param_start:i - param_start - 1];
				// Check for reset: bare \x1b[m or any param that is "0"
				bool has_reset = params.len == 0;
				if (!has_reset) {
					sz pi = 0;
					while (pi <= params.len) {
						sz pend = pi;
						while (pend < params.len && params[pend] != ';') pend++;
						String tok = params[pi:pend - pi];
						if (tok.len == 0 || tok == "0") {
							has_reset = true;
							break;
						}
						pi = pend + 1;
					}
				}
				if (has_reset) cur_sgr.clear();
				// Re-append the full original sequence (including params + 'm').
				cur_sgr.append_string("\x1b[");
				cur_sgr.append_string(params);
				cur_sgr.append_char('m');
			}
			// Other CSI sequences (cursor movement etc.) — discard
			continue;
		}

		// Newline
		if (b == '\n') {
			row++;
			col = e.abs_x;
			i++;
			continue;
		}

		// Printable character (UTF-8)
		sz clen = (b & 0x80) == 0 ? 1 : (b & 0xe0) == 0xc0 ? 2 : (b & 0xf0) == 0xe0 ? 3 : 4;

		if (row >= 0 && row < canvas_h && col >= 0 && col < canvas_w) {
			CanvasCell* cell = &grid[(sz)row * (sz)canvas_w + (sz)col];
			// Write content bytes
			sz copy_len = clen;
			if (copy_len > 8) copy_len = 8;
			for (sz k = 0; k < copy_len && i + k < content.len; k++) {
				cell.content[k] = content[i + k];
			}
			cell.content_len = (char)copy_len;
			// Snapshot current SGR accumulator (stable temp-alloc copy)
			cell.sgr = cur_sgr.copy_str(tmem);
		}

		col++;
		i += clen;
	}
}

fn String canvas_cell_str(CanvasCell* cell) @local {
	return (String)((char*)&cell.content)[:cell.content_len];
}

fn int count_lines(String s) @local {
	int count = 1;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') count++;
	}
	return count;
}