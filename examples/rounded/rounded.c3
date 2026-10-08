module rounded;

// Rounded boxes with kitty-graphics corners. Three styles, one per box:
//   1. a plain background region (corners are the rounded cut),
//   2. a single-line ─ │ border whose corner arcs join the strokes,
//   3. a div-style 1px outline drawn entirely with glyphs, background fully
//      contained inside the outline.
// Adjust the radius per box and the view just swaps which frame the corner
// placeholder references — no re-transmission, the switch is instant.

import milktea;
import glaze;
import tgp;
import std::core::dstring;
import std::core::string;
import std::core::mem;

const sz BOX_COUNT = 3;
const sz CORNER_COUNT = 4;
const sz EDGE_COUNT = 4;
const sz INNER_W = 30;

const String[CORNER_COUNT] CORNER_CHARS = { "╭", "╮", "╰", "╯" };
const String[EDGE_COUNT] EDGE_CHARS = { "─", "│", "─", "│" };

struct BoxDef {
	String name;
	String bg;
	String line;
	String fg;
	String sample;
}

const BoxDef[BOX_COUNT] BOX_DEFS = {
	{ .name = "Indigo", .bg = "#312e81", .line = "#a5b4fc", .fg = "#e0e7ff", .sample = "plain background box" },
	{ .name = "Ember",  .bg = "#7c2d12", .line = "#fdba74", .fg = "#ffedd5", .sample = "single-line border, rounded corners" },
	{ .name = "Moss",   .bg = "#14532d", .line = "#86efac", .fg = "#dcfce7", .sample = "div-style 1px outline" },
};

const int MSG_GFX = 1;

struct Model {
	tgp::Session gfx;
	tgp::Glyph[CORNER_COUNT * BOX_COUNT] corners;
	tgp::Glyph[EDGE_COUNT] edges;
	sz[BOX_COUNT] radius;
	sz selected;
	bool tgp_ok;
}

fn sz hexval(char c) {
	if (c >= '0' && c <= '9') return (sz)(c - '0');
	if (c >= 'a' && c <= 'f') return (sz)(c - 'a' + 10);
	if (c >= 'A' && c <= 'F') return (sz)(c - 'A' + 10);
	return 0;
}

fn uint parse_rgb(String hex) {
	uint v = 0;
	sz i = hex.len > 0 && hex[0] == '#' ? 1 : 0;
	for (; i < hex.len && i < 7; i++) v = v * 16 + (uint)hexval(hex[i]);
	return v;
}

fn String repeat_str(String s, sz n) {
	DString d = dstring::temp();
	for (sz i = 0; i < n; i++) d.append_string(s);
	return d.str_view();
}

fn String center(String s, sz w) {
	DString d = dstring::temp();
	sz left = (w - (sz)s.len) / 2;
	sz right = w - (sz)s.len - left;
	if (left < 0) left = 0;
	if (right < 0) right = 0;
	for (sz i = 0; i < left; i++) d.append_char(' ');
	d.append_string(s);
	for (sz i = 0; i < right; i++) d.append_char(' ');
	return d.str_view();
}

fn String pad_right(String s, sz w) {
	DString d = dstring::temp();
	d.append_string(s);
	for (sz i = (sz)s.len; i < w; i++) d.append_char(' ');
	return d.str_view();
}

// Fallback characters: the plain box falls back to a solid background cell,
// the bordered and div boxes fall back to the box-drawing corner.
fn String corner_fallback(sz b, sz c) {
	return b == 0 ? " " : CORNER_CHARS[c];
}

fn String edge_fallback(sz e) => EDGE_CHARS[e];

fn milktea::Cmd Model.init(Model* self) @dynamic {
	self.tgp_ok = milktea::kitty_graphics_supported();
	// Start at the roundest corner; radii are declared 1-8 and drawn doubled.
	for (sz b = 0; b < BOX_COUNT; b++) self.radius[b] = RADII - 1;
	if (self.tgp_ok) {
		self.gfx = tgp::new_session();
		for (sz b = 0; b < BOX_COUNT; b++) {
			uint bg = parse_rgb(BOX_DEFS[b].bg);
			uint line = parse_rgb(BOX_DEFS[b].line);
			for (sz c = 0; c < CORNER_COUNT; c++) {
				char[] frames = mem::new_array(char, RADII * CORNER_BYTES);
				render_corner_set(frames, b, c, bg, line);
				self.corners[b * CORNER_COUNT + c] = self.gfx.register({
					.frames = frames,
					.count = RADII, .width = GX, .height = GY,
					.fps = 0, .fallback = corner_fallback(b, c),
				})!!;
			}
		}
		// The div box's outline edges.
		BoxDef d = BOX_DEFS[2];
		uint bg = parse_rgb(d.bg);
		uint line = parse_rgb(d.line);
		for (sz e = 0; e < EDGE_COUNT; e++) {
			char[] frames = mem::new_array(char, CORNER_BYTES);
			render_edge(frames, e, bg, line);
			self.edges[e] = self.gfx.register({
				.frames = frames,
				.count = 1, .width = GX, .height = GY,
				.fps = 0, .fallback = edge_fallback(e),
			})!!;
		}
	}
	// One-shot mounted tick: kgp transmits lazily on the first tick after the
	// alt screen is active, and render_current_view calls view() before the
	// alt-screen flag is set, so a flush() from view() alone never fires.
	// Short delay so the rounded corners pop in within a frame or two.
	return milktea::tick(16, &on_gfx);
}

fn milktea::Msg on_gfx() {
	return { .kind = milktea::MsgKind.USER, .tag = MSG_GFX };
}

fn void Model.adjust_radius(Model* self, sz delta) {
	sz r = self.radius[self.selected] + delta;
	if (r < 0) r = 0;
	if (r > RADII - 1) r = RADII - 1;
	self.radius[self.selected] = r;
}

fn milktea::Cmd Model.update(Model* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.USER && msg.tag == MSG_GFX) {
		// Idempotent: transmits pending glyphs now that the alt screen is up.
		self.gfx.tick();
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	switch (k.code) {
		case milktea::KeyCode.CTRL_C:
			return self.quit();
		case milktea::KeyCode.ESC:
			return self.quit();
		case milktea::KeyCode.RUNE:
			if (k.rune == 'q') return self.quit();
			if (k.rune == '+' || k.rune == '=') self.adjust_radius(1);
			if (k.rune == '-') self.adjust_radius(-1);
		case milktea::KeyCode.RIGHT:
			self.adjust_radius(1);
		case milktea::KeyCode.LEFT:
			self.adjust_radius(-1);
		case milktea::KeyCode.UP:
			self.selected = (self.selected + BOX_COUNT - 1) % BOX_COUNT;
		case milktea::KeyCode.DOWN:
			self.selected = (self.selected + 1) % BOX_COUNT;
		default:
	}
	return null;
}

fn milktea::Cmd Model.quit(Model* self) {
	self.gfx.destroy();
	return milktea::quit();
}

fn void Model.on_destroy(Model* self) @dynamic {
	self.gfx.destroy();
}

// corner_cell returns one corner cell: a tgp placeholder for the glyph frame
// matching this box's radius, or the box's fallback corner when graphics are
// unavailable.
fn String corner_cell(Model* m, sz b, sz c, glaze::Style fallback_st) {
	if (!m.tgp_ok) return fallback_st.render(corner_fallback(b, c));
	// Frame indices feed directly into the placeholder image id; keep an
	// out-of-range radius (e.g. a hand-edited default) from silently showing
	// the neighbor corner's frame.
	sz rad = m.radius[b];
	if (rad < 0) rad = 0;
	if (rad >= RADII) rad = RADII - 1;
	// Emit the placeholder bare: wrapping it in style SGRs breaks ghostty's
	// placeholder resolution (it must see the id-encoded fg color adjacent
	// to the U+10EEEE cell), and the corner glyph itself is opaque anyway.
	return tgp::placeholder_string(m.corners[b * CORNER_COUNT + c].base_id + (uint)rad);
}

// edge_cell returns one div-outline edge cell (0=top 1=right 2=bottom 3=left).
fn String edge_cell(Model* m, sz e, glaze::Style fallback_st) {
	if (!m.tgp_ok) return fallback_st.render(edge_fallback(e));
	return tgp::placeholder_string(m.edges[e].base_id);
}

// edge_row returns n consecutive div-outline edge cells as one placeholder
// run; the run stamps (row 0, col 0) on every cell so nothing inherits or
// increments across the repeated cells.
fn String edge_row(Model* m, sz e, sz n, glaze::Style fallback_st) {
	if (!m.tgp_ok) return fallback_st.render(repeat_str(edge_fallback(e), n));
	return tgp::placeholder_run(m.edges[e].base_id, n);
}

fn void append_marker(DString* out, Model* m, sz b) {
	if (b == m.selected) {
		out.append_string(glaze::style()
			.foreground(glaze::color_hex("#ffffff")).with_bold(true)
			.render(string::tformat("▸ %s", BOX_DEFS[b].name)));
	} else {
		out.append_string(glaze::style()
			.foreground(glaze::color_hex("#777777"))
			.render(string::tformat("  %s", BOX_DEFS[b].name)));
	}
	out.append_char('\n');
}

fn void append_box(DString* out, Model* m, sz b) {
	BoxDef d = BOX_DEFS[b];
	glaze::Color bg = glaze::color_hex(d.bg);
	glaze::Style bg_st = glaze::style().background(bg);
	glaze::Style text_st = glaze::style().foreground(glaze::color_hex(d.fg)).background(bg);
	glaze::Style title_st = glaze::style().foreground(glaze::color_hex(d.line)).background(bg).with_bold(true);
	glaze::Style line_st = glaze::style().foreground(glaze::color_hex(d.line)).background(bg);

	sz w = (sz)d.sample.len + 2;
	if (w < INNER_W) w = INNER_W;
	String fill = repeat_str(" ", w);
	String rule = repeat_str("─", w);

	String radius_txt = string::tformat("radius: %dpx", radius_px(m.radius[b]));
	if (!m.tgp_ok) radius_txt = string::tformat("%s (text fallback)", radius_txt);

	String[3] rows = {
		title_st.render(center(d.name, w)),
		text_st.render(center(radius_txt, w)),
		text_st.render(pad_right(string::tformat(" %s", d.sample), w)),
	};

	if (b == 0) {
		// Plain background box.
		out.append_string(corner_cell(m, b, 0, bg_st));
		out.append_string(bg_st.render(fill));
		out.append_string(corner_cell(m, b, 1, bg_st));
		out.append_char('\n');
		for (sz r = 0; r < 3; r++) {
			out.append_string(bg_st.render(" "));
			out.append_string(rows[r]);
			out.append_string(bg_st.render(" "));
			out.append_char('\n');
		}
		out.append_string(corner_cell(m, b, 2, bg_st));
		out.append_string(bg_st.render(fill));
		out.append_string(corner_cell(m, b, 3, bg_st));
		out.append_char('\n');
	} else if (b == 1) {
		// Single-line ─ │ border with rounded corners.
		out.append_string(corner_cell(m, b, 0, line_st));
		out.append_string(line_st.render(rule));
		out.append_string(corner_cell(m, b, 1, line_st));
		out.append_char('\n');
		for (sz r = 0; r < 3; r++) {
			out.append_string(line_st.render("│"));
			out.append_string(rows[r]);
			out.append_string(line_st.render("│"));
			out.append_char('\n');
		}
		out.append_string(corner_cell(m, b, 2, line_st));
		out.append_string(line_st.render(rule));
		out.append_string(corner_cell(m, b, 3, line_st));
		out.append_char('\n');
	} else {
		// Div-style outline: everything drawn with glyphs.
		out.append_string(corner_cell(m, b, 0, line_st));
		out.append_string(edge_row(m, 0, w, line_st));
		out.append_string(corner_cell(m, b, 1, line_st));
		out.append_char('\n');
		for (sz r = 0; r < 3; r++) {
			out.append_string(edge_cell(m, 3, line_st));
			out.append_string(rows[r]);
			out.append_string(edge_cell(m, 1, line_st));
			out.append_char('\n');
		}
		out.append_string(corner_cell(m, b, 2, line_st));
		out.append_string(edge_row(m, 2, w, line_st));
		out.append_string(corner_cell(m, b, 3, line_st));
		out.append_char('\n');
	}
}

fn milktea::Node* Model.view(Model* self) @dynamic {
	if (self.tgp_ok) self.gfx.flush();

	DString out = dstring::temp();

	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#f0f0f0")).with_bold(true)
		.render("Rounded corners"));
	out.append_char('\n');
	String sub = self.tgp_ok
		? "tgp corners: plain, bordered, div-outline — radius 2-16px"
		: "kitty graphics unavailable: text corner fallback";
	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#888888"))
		.render(sub));
	out.append_string("\n\n");

	for (sz b = 0; b < BOX_COUNT; b++) {
		append_marker(&out, self, b);
		append_box(&out, self, b);
		out.append_char('\n');
	}

	out.append_string(glaze::style()
		.foreground(glaze::color_hex("#888888"))
		.render("↑/↓ select box   ←/→ or -/+ radius   q quit"));

	return milktea::text(out.str_view());
}
