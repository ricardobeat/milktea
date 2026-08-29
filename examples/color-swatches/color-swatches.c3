// color-swatches — visual showcase of glaze colour functions.
// Compares color_hex, blend_luv, hsl, blend_hsl, hcl, blend_hcl.
// Move the mouse to drop coloured glitter. Press q to quit.
module color_swatches;

import milktea;
import glaze;
import xray;
import xray::layout;
import std::core::dstring;
import std::io;

const int MAX_GLITTER = 256;
const String[6] SPARKLES = { "✦", "✧", "·", "˖", "°", "•" };

struct Particle {
	int col;
	int row;
	glaze::Color color;
	int life; // frames remaining
	bool active;
}

struct Model {
	Particle[MAX_GLITTER] glitter;
	int glitter_count;
	int spawn_idx; // round-robin index
	int color_phase;
	// Reused cell buffer, owned by the model. The View borrows its cell array
	// until the framework has copied it into the renderer, so the buffer must
	// outlive view() — building a fresh screen per frame and freeing it here
	// left every View referencing freed memory (use-after-free).
	xray::ScreenBuffer* screen;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	return milktea::tick(33);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK) {
		for (int i = 0; i < MAX_GLITTER; i++) {
			if (self.glitter[i].active) {
				self.glitter[i].life--;
				if (self.glitter[i].life <= 0) self.glitter[i].active = false;
			}
		}
		return milktea::tick(33);
	}
	if (msg.kind == milktea::MsgKind.KEY) {
		if (msg.key.code == milktea::KeyCode.CTRL_C) return milktea::quit();
		if (msg.key.code == milktea::KeyCode.ESC) return milktea::quit();
		if (msg.key.code == milktea::KeyCode.RUNE && msg.key.rune == 'q') return milktea::quit();
		return null;
	}
	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (msg.mouse.action == milktea::MouseAction.MOUSE_MOTION) {
			for (int j = 0; j < 3; j++) {
				int idx = self.spawn_idx % MAX_GLITTER;
				self.glitter[idx].col = msg.mouse.col + (j - 1);
				self.glitter[idx].row = msg.mouse.row;
				self.glitter[idx].color = glaze::hcl((double)(self.color_phase % 360), 100.0, 65.0);
				self.glitter[idx].life = 15 + j * 5;
				self.glitter[idx].active = true;
				self.spawn_idx++;
				self.color_phase += 47;
			}
		}
		return null;
	}
	return null;
}

fn milktea::View Model.view(&self) @dynamic {
	int w = milktea::screen_width();
	int h = milktea::screen_height();

	glaze::Style title_s = glaze::style().foreground(glaze::color_hex("#ffffff")).bold(true);
	glaze::Style label_s = glaze::style().foreground(glaze::color_hex("#888888"));
	glaze::Style label_hi = glaze::style().foreground(glaze::color_hex("#cccccc")).bold(true);

	glaze::Color red  = glaze::color_hex("#ff0000");
	glaze::Color blue = glaze::color_hex("#0000ff");
	glaze::Color grn  = glaze::color_hex("#00ff00");

	int cols = w - 4;
	if (cols < 10) cols = 10;

	// ── build gradient rows ──────────────────────────────────────────────

	DString row1 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row1.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row1.append_string(glaze::style().foreground(glaze::blend_luv(red, blue, (double)i / (double)(cols - 1))).render("█"));
		}
	}

	DString row2 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row2.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row2.append_string(glaze::style().foreground(glaze::blend_hsl(red, blue, (double)i / (double)(cols - 1))).render("█"));
		}
	}

	DString row3 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row3.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row3.append_string(glaze::style().foreground(glaze::blend_hcl(red, blue, (double)i / (double)(cols - 1))).render("█"));
		}
	}

	DString row4 = dstring::temp();
	int third = cols / 3;
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row4.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			glaze::Color c;
			if (i < third) {
				c = glaze::blend_luv(red, grn, (double)i / (double)third);
			} else if (i < third * 2) {
				c = glaze::blend_luv(grn, blue, (double)(i - third) / (double)third);
			} else {
				c = glaze::blend_luv(blue, red, (double)(i - third * 2) / (double)(cols - third * 2));
			}
			row4.append_string(glaze::style().foreground(c).render("█"));
		}
	}

	DString row5 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row5.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row5.append_string(glaze::style().foreground(glaze::hsl((double)i / (double)cols, 1.0, 0.5)).render("█"));
		}
	}

	DString row6 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row6.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row6.append_string(glaze::style().foreground(glaze::hcl((double)i / (double)cols * 360.0, 100.0, 60.0)).render("█"));
		}
	}

	DString row7 = dstring::temp();
	String[8] hex_colors = { "#ff0000", "#ff8800", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#8800ff", "#ff00ff" };
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row7.append_string("\n  ");
		for (int i = 0; i < 8; i++) {
			row7.append_string(glaze::style().foreground(glaze::color_hex(hex_colors[i])).render("████"));
		}
	}

	// ── build labels ─────────────────────────────────────────────────────

	DString lbl1 = dstring::temp(); lbl1.append_string("  blend_luv"); lbl1.append_string(label_s.render("   red → blue (perceptual)"));
	DString lbl2 = dstring::temp(); lbl2.append_string("  blend_hsl"); lbl2.append_string(label_s.render("   red → blue (hue-aware shortest path)"));
	DString lbl3 = dstring::temp(); lbl3.append_string("  blend_hcl"); lbl3.append_string(label_s.render("   red → blue (perceptual + hue-aware)"));
	DString lbl4 = dstring::temp(); lbl4.append_string("  blend_luv"); lbl4.append_string(label_s.render("   red → green → blue (3-stop)"));
	DString lbl5 = dstring::temp(); lbl5.append_string("  hsl"); lbl5.append_string(label_s.render("          full hue sweep (s=1, l=0.5)"));
	DString lbl6 = dstring::temp(); lbl6.append_string("  hcl"); lbl6.append_string(label_s.render("          full hue sweep (c=100, l=60)"));
	DString lbl7 = dstring::temp(); lbl7.append_string("  color_hex"); lbl7.append_string(label_s.render("  basic palette"));

	DString grad1 = dstring::temp(); grad1.append_string("  "); grad1.append_string(row1.str_view());
	DString grad2 = dstring::temp(); grad2.append_string("  "); grad2.append_string(row2.str_view());
	DString grad3 = dstring::temp(); grad3.append_string("  "); grad3.append_string(row3.str_view());
	DString grad4 = dstring::temp(); grad4.append_string("  "); grad4.append_string(row4.str_view());
	DString grad5 = dstring::temp(); grad5.append_string("  "); grad5.append_string(row5.str_view());
	DString grad6 = dstring::temp(); grad6.append_string("  "); grad6.append_string(row6.str_view());
	DString grad7 = dstring::temp(); grad7.append_string("  "); grad7.append_string(row7.str_view());

	// ── vstack layout ────────────────────────────────────────────────────

	xray::Rect area = xray::new_rect(0, 0, w, h);

	xray::Rect r00, r01, r02, r03, r04, r05, r06, r07, r08, r09, r10, r11;
	xray::Rect r12, r13, r14, r15, r16, r17, r18, r19, r20, r21, r22;
	layout::vstack(area, {
		layout::slot(layout::cells(1), &r00),
		layout::slot(layout::cells(1), &r01),
		layout::slot(layout::cells(1), &r02),
		layout::slot(layout::cells(2), &r03),
		layout::slot(layout::cells(1), &r04),
		layout::slot(layout::cells(1), &r05),
		layout::slot(layout::cells(2), &r06),
		layout::slot(layout::cells(1), &r07),
		layout::slot(layout::cells(1), &r08),
		layout::slot(layout::cells(2), &r09),
		layout::slot(layout::cells(1), &r10),
		layout::slot(layout::cells(1), &r11),
		layout::slot(layout::cells(2), &r12),
		layout::slot(layout::cells(1), &r13),
		layout::slot(layout::cells(1), &r14),
		layout::slot(layout::cells(2), &r15),
		layout::slot(layout::cells(1), &r16),
		layout::slot(layout::cells(1), &r17),
		layout::slot(layout::cells(2), &r18),
		layout::slot(layout::cells(1), &r19),
		layout::slot(layout::cells(1), &r20),
		layout::slot(layout::cells(2), &r21),
		layout::slot(layout::cells(1), &r22),
	});

	String v00 = r00.render(title_s,       "  COLOUR SPACE COMPARISON");
	String v01 = glaze::style().render_in(r01, "");
	String v02 = r02.render(label_hi,     lbl1.str_view());
	String v03 = glaze::style().render_in(r03, grad1.str_view());
	String v04 = glaze::style().render_in(r04, "");
	String v05 = r05.render(label_hi,     lbl2.str_view());
	String v06 = glaze::style().render_in(r06, grad2.str_view());
	String v07 = glaze::style().render_in(r07, "");
	String v08 = r08.render(label_hi,     lbl3.str_view());
	String v09 = glaze::style().render_in(r09, grad3.str_view());
	String v10 = glaze::style().render_in(r10, "");
	String v11 = r11.render(label_hi,     lbl4.str_view());
	String v12 = glaze::style().render_in(r12, grad4.str_view());
	String v13 = glaze::style().render_in(r13, "");
	String v14 = r14.render(label_hi,     lbl5.str_view());
	String v15 = glaze::style().render_in(r15, grad5.str_view());
	String v16 = glaze::style().render_in(r16, "");
	String v17 = r17.render(label_hi,     lbl6.str_view());
	String v18 = glaze::style().render_in(r18, grad6.str_view());
	String v19 = glaze::style().render_in(r19, "");
	String v20 = r20.render(label_hi,     lbl7.str_view());
	String v21 = glaze::style().render_in(r21, grad7.str_view());
	String v22 = glaze::style().render_in(r22, "");

	String content = v00;
	content = glaze::join_vertical(glaze::Position.LEFT, content, v01);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v02);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v03);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v04);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v05);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v06);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v07);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v08);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v09);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v10);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v11);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v12);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v13);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v14);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v15);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v16);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v17);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v18);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v19);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v20);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v21);
	content = glaze::join_vertical(glaze::Position.LEFT, content, v22);

	// ── render to screen buffer + glitter overlay ────────────────────────

	xray::ScreenBuffer* screen = self.screen;
	if (screen == null) {
		screen = xray::new_screen_buffer((sz)w, (sz)h);
		self.screen = screen;
	} else if (screen.width != (sz)w || screen.height != (sz)h) {
		screen.resize((sz)w, (sz)h);
	}
	screen.clear();
	screen.render_ansi_string(0, 0, content, xray::default_style());

	// Overlay glitter particles — fg blends additively, bg inherited from content
	for (int i = 0; i < MAX_GLITTER; i++) {
		Particle* p = &self.glitter[i];
		if (!p.active) continue;
		if (p.col < 0 || p.col >= w || p.row < 0 || p.row >= h) continue;

		sz idx = (sz)p.row * (sz)w + (sz)p.col;

		// Fade based on remaining life
		double fade = (double)p.life / 20.0;
		if (fade > 1.0) fade = 1.0;

		char pr = (char)(int)((double)p.color.r * fade);
		char pg = (char)(int)((double)p.color.g * fade);
		char pb = (char)(int)((double)p.color.b * fade);

		String ch = SPARKLES[i % 6];
		xray::Style s = xray::default_style()
			.set_fg(xray::color_rgb(pr, pg, pb))
			.set_bg(xray::color_transparent());
		screen.set_cell((sz)p.col, (sz)p.row, xray::new_cell(ch, 1, s));
	}

	milktea::View view = milktea::new_alt_cell_view(screen.cells[0:(sz)w * (sz)h], (sz)w, (sz)h)
		.set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);
	// screen is owned by the model (self.screen); freed in on_destroy.

	return view;
}

fn void Model.on_destroy(&self) @dynamic {
	if (self.screen != null) {
		self.screen.destroy();
		mem::free(self.screen);
		self.screen = null;
	}
}

fn int main() {
	Model m;
	return milktea::@run(&m);
}
