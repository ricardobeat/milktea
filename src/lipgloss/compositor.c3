module lipgloss;

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

// Render composites all layers onto a canvas and returns the result.
fn String Compositor.render(Compositor* self) {
	if (self.entry_count == 0) return "";

	int w = self.bounds_w;
	int h = self.bounds_h;
	if (w <= 0 || h <= 0) return "";

	// Create canvas: grid of cells, each holding a string fragment
	// We use a flat DString grid — each cell is a column in a row
	DString[MAX_CANVAS_H] canvas_rows;
	bool[MAX_CANVAS_H] canvas_init;
	for (int r = 0; r < h && r < MAX_CANVAS_H; r++) {
		canvas_rows[r] = dstring::temp();
		canvas_init[r] = false;
	}

	// Draw each layer in z-order
	for (sz i = 0; i < self.entry_count; i++) {
		CompositeEntry* e = &self.entries[i];
		draw_layer(canvas_rows[..], canvas_init[..], w, h, e);
	}

	// Assemble output
	DString out = dstring::temp();
	for (int r = 0; r < h && r < MAX_CANVAS_H; r++) {
		out.append_string(canvas_rows[r].str_view());
		if (r < h - 1) out.append_char('\n');
	}
	return out.str_view();
}

const int MAX_CANVAS_H = 200;

fn void draw_layer(DString[] rows, bool[] init, int canvas_w, int canvas_h, CompositeEntry* e) {
	// Split layer content into lines
	String[MAX_LAYOUT_LINES] lines;
	sz line_count  = 0;
	sz start       = 0;
	String content = e.layer.content;
	for (sz i = 0; i <= content.len; i++) {
		if (i == content.len || content[i] == '\n') {
			if (line_count < MAX_LAYOUT_LINES) {
				lines[line_count] = content[start:i - start];
				line_count++;
			}
			start = i + 1;
			if (i == content.len) break;
		}
	}

	// Draw each line of the layer at the correct position
	for (sz li = 0; li < line_count; li++) {
		int row = e.abs_y + (int)li;
		if (row < 0 || row >= canvas_h) continue;

		String line = lines[li];
		int col     = e.abs_x;
		sz ci       = 0;

		// If this is the first layer touching this row, initialize with spaces
		if (!init[row]) {
			// Pre-fill with spaces to canvas width
			for (int p = 0; p < canvas_w; p++) rows[row].append_char(' ');
			init[row] = true;
		}

		// Write the line content into the row at the correct column offset.
		// We need to handle ANSI sequences (pass through) and regular chars
		// (overwrite at position).
		// For simplicity, we just overwrite the entire row segment.
		// A proper implementation would track cell positions through ANSI sequences.
		// For now, we rebuild the row with the new content overlaid.
		DString new_row = dstring::temp();
		String old      = rows[row].str_view();
		int old_col     = 0;
		sz oi           = 0;
		sz line_i       = 0;
		int write_col   = col;

		// Copy old content up to the layer's x position
		while (oi < old.len && old_col < write_col) {
			// Skip ANSI sequences in old content
			if (old[oi] == '\x1b' && oi + 1 < old.len && old[oi + 1] == '[') {
				new_row.append_char(old[oi]);
				oi++;
				while (oi < old.len) {
					new_row.append_char(old[oi]);
					char c = old[oi];
					oi++;
					if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) break;
				}
			} else {
				new_row.append_char(old[oi]);
				old_col++;
				oi++;
			}
		}

		// Write the new layer content
		new_row.append_string(line);

		// Count visual chars in the new line to know where to resume
		int new_chars = 0;



		{
			sz ni = 0;
			while (ni < line.len) {
				if (line[ni] == '\x1b' && ni + 1 < line.len && line[ni + 1] == '[') {
					ni += 2;
					while (ni < line.len) {
						char c = line[ni];
						ni++;
						if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) break;
					}
				} else {
					new_chars++;
					ni++;
				}
			}
		}

		// Skip old content that was overwritten
		int end_col = write_col + new_chars;
		while (oi < old.len && old_col < end_col) {
			if (old[oi] == '\x1b' && oi + 1 < old.len && old[oi + 1] == '[') {
				oi += 2;
				while (oi < old.len) {
					char c = old[oi];
					oi++;
					if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) break;
				}
			} else {
				old_col++;
				oi++;
			}
		}

		// Reset SGR before copying remaining old content
		if (oi < old.len) new_row.append_string("\x1b[0m");

		// Copy remaining old content
		while (oi < old.len) {
			new_row.append_char(old[oi]);
			oi++;
		}

		// Replace the row
		rows[row] = new_row;
	}
}

fn int count_lines(String s) @local {
	int count = 1;
	for (sz i = 0; i < s.len; i++) {
		if (s[i] == '\n') count++;
	}
	return count;
}