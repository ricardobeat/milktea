// color-swatches — visual showcase of glaze colour functions.
// Compares color_hex, blend_luv, hsl, blend_hsl, hcl, blend_hcl.
// Move the mouse to drop coloured glitter. Press q to quit.
module color_swatches;

import milktea;
import glaze;
import xray;
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
	int width;
	int height;
	Particle[MAX_GLITTER] glitter;
	int glitter_count;
	int spawn_idx; // round-robin index
	int color_phase;
}

fn milktea::Cmd Model.init(&self) @dynamic {
	return milktea::tick(33);
}

fn milktea::Cmd Model.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
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
	int w = self.width > 0 ? self.width : 80;
	int h = self.height > 0 ? self.height : 24;

	glaze::Style title_s = glaze::new_style().foreground(glaze::color_hex("#ffffff")).set_bold(true);
	glaze::Style label_s = glaze::new_style().foreground(glaze::color_hex("#888888"));
	glaze::Style label_hi = glaze::new_style().foreground(glaze::color_hex("#cccccc")).set_bold(true);

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
			row1.append_string(glaze::new_style().foreground(glaze::blend_luv(red, blue, (double)i / (double)(cols - 1))).render("█"));
		}
	}

	DString row2 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row2.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row2.append_string(glaze::new_style().foreground(glaze::blend_hsl(red, blue, (double)i / (double)(cols - 1))).render("█"));
		}
	}

	DString row3 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row3.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row3.append_string(glaze::new_style().foreground(glaze::blend_hcl(red, blue, (double)i / (double)(cols - 1))).render("█"));
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
			row4.append_string(glaze::new_style().foreground(c).render("█"));
		}
	}

	DString row5 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row5.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row5.append_string(glaze::new_style().foreground(glaze::hsl((double)i / (double)cols, 1.0, 0.5)).render("█"));
		}
	}

	DString row6 = dstring::temp();
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row6.append_string("\n  ");
		for (int i = 0; i < cols; i++) {
			row6.append_string(glaze::new_style().foreground(glaze::hcl((double)i / (double)cols * 360.0, 100.0, 60.0)).render("█"));
		}
	}

	DString row7 = dstring::temp();
	String[8] hex_colors = { "#ff0000", "#ff8800", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#8800ff", "#ff00ff" };
	for (int pass = 0; pass < 2; pass++) {
		if (pass == 1) row7.append_string("\n  ");
		for (int i = 0; i < 8; i++) {
			row7.append_string(glaze::new_style().foreground(glaze::color_hex(hex_colors[i])).render("████"));
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

	milktea::LayoutNode[23] nodes = {
		{ xray::constraint_len(1), title_s, "  COLOUR SPACE COMPARISON" },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl1.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad1.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl2.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad2.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl3.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad3.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl4.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad4.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl5.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad5.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl6.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad6.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
		{ xray::constraint_len(1), label_hi, lbl7.str_view() },
		{ xray::constraint_len(2), glaze::new_style(), grad7.str_view() },
		{ xray::constraint_len(1), glaze::new_style(), "" },
	};

	String content = milktea::vstack(area, nodes[..]);

	// ── render to screen buffer + glitter overlay ────────────────────────

	xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);
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
	screen.destroy();
	mem::free(screen);

	return view;
}

fn int main() {
	Model m;
	if (catch err = milktea::@run_program(&m)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	return 0;
}
