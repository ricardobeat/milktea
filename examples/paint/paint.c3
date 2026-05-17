module paint;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;
import std::core::mem;

// ── Paint tool ────────────────────────────────────────────────────────────────

enum PaintTool : char {
    PAINT,
    ERASER,
}

// Palette: 8 colors as hex strings (indices 0-7).
const String[8] PALETTE_HEX = {
    "#505050", // 0: medium gray (eraser / background)
    "#ff5555", // 1: red
    "#55ff55", // 2: green
    "#ffff55", // 3: yellow
    "#5555ff", // 4: blue
    "#ff55ff", // 5: magenta
    "#55ffff", // 6: cyan
    "#ffffff", // 7: white
};

struct Model {
    int term_width;
    int term_height;

    int[] canvas;
    int canvas_width;
    int canvas_height;
    int canvas_x;  // left offset of canvas within terminal
    int canvas_y;  // top offset of canvas within terminal

    char selected_color; // 0-7
    PaintTool tool;
    int stroke_width;    // 1-3
    int eraser_width;    // 1-3

    bool was_pressing;
    int last_draw_row;
    int last_draw_col;

    int hover_row;
    int hover_col;
}

// ── Canvas helpers ────────────────────────────────────────────────────────────

fn void resize_canvas(Model* m, int width, int height) {
    m.term_width = width;
    m.term_height = height;

    // Col 0 = palette (1 cell wide), Row 0 = toolbar
    m.canvas_x = 1;
    m.canvas_y = 1;
    m.canvas_width  = width  - m.canvas_x;
    m.canvas_height = height - m.canvas_y;

    if (m.canvas_width  < 1) m.canvas_width  = 1;
    if (m.canvas_height < 1) m.canvas_height = 1;

    sz total = (sz)m.canvas_width * (sz)m.canvas_height;
    if (m.canvas.ptr != null) mem::free(m.canvas.ptr);
    m.canvas = mem::new_array(int, total);
    for (sz i = 0; i < total; i++) m.canvas[i] = -1;
}

fn void clear_canvas(Model* m) {
    for (sz i = 0; i < m.canvas.len; i++) m.canvas[i] = -1;
}

// draw_circle fills a circle centered at (cx, cy) with the given color index.
fn void draw_circle(Model* m, int cx, int cy, int radius, int color) {
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            if (dx*dx + dy*dy <= radius*radius) {
                int col = cx + dx;
                int row = cy + dy;
                if (col >= 0 && col < m.canvas_width && row >= 0 && row < m.canvas_height) {
                    sz idx = (sz)row * (sz)m.canvas_width + (sz)col;
                    m.canvas[idx] = color;
                }
            }
        }
    }
}

// draw_line bridges two points by sampling N steps between them.
fn void draw_line(Model* m, int x0, int y0, int x1, int y1, int radius, int color) {
    int dx = x1 - x0;
    int dy = y1 - y0;
    int steps = dx < 0 ? -dx : dx;
    int dy_abs = dy < 0 ? -dy : dy;
    if (steps < dy_abs) steps = dy_abs;
    if (steps < 1) steps = 1;

    for (int i = 0; i <= steps; i++) {
        int x = x0 + (dx * i) / steps;
        int y = y0 + (dy * i) / steps;
        draw_circle(m, x, y, radius, color);
    }
}

// ── Tea Model ───────────────────────────────────────────────────────────────

fn tea::Cmd Model.init(Model* self) @dynamic {
    self.selected_color = 1; // red
    self.tool = PaintTool.PAINT;
    self.stroke_width = 1;
    self.eraser_width = 3;
    self.was_pressing = false;
    self.last_draw_row = -1;
    self.last_draw_col = -1;
    self.hover_row = -1;
    self.hover_col = -1;
    return null;
}

fn tea::Cmd Model.update(Model* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        resize_canvas(self, msg.window_size.width, msg.window_size.height);
        return null;
    }

    if (msg.kind == tea::MsgKind.MOUSE) {
        int col = msg.mouse.col;
        int row = msg.mouse.row;

        self.hover_col = col;
        self.hover_row = row;

        // ── Click on color palette (row 0, col 0) ───────────────────────
        if (col == 0 && row >= 1 && row <= 8) {
            self.selected_color = (char)(row - 1);
            return null;
        }

        // ── Toolbar clicks (row 0, cols >= 1) ───────────────────────────
        if (row == 0) {
            // Paint button: cols 0-8
            if (col >= 0 && col <= 8) {
                self.tool = PaintTool.PAINT;
                return null;
            }
            // Stroke width buttons (cols 9, 10, 11)
            if (col == 10) { self.stroke_width = 1; return null; }
            if (col == 11) { self.stroke_width = 2; return null; }
            if (col == 12) { self.stroke_width = 3; return null; }
            // Eraser button (cols 13-19)
            if (col == 14) { self.tool = PaintTool.ERASER; return null; }
            // Clear button (cols 20-23)
            if (col == 21) { clear_canvas(self); return null; }
            // Color selector: click cols 25-32 maps to colors 0-7
            if (col >= 25 && col <= 32) {
                self.selected_color = (char)(col - 25);
                return null;
            }
            return null;
        }

        // ── Canvas click ───────────────────────────────────────────────
        int ccol = col - self.canvas_x;
        int crow = row - self.canvas_y;
        bool in_canvas = ccol >= 0 && ccol < self.canvas_width
                      && crow >= 0 && crow < self.canvas_height;

        if (msg.mouse.action == tea::MouseAction.MOUSE_PRESS && in_canvas) {
            self.was_pressing = true;
            int radius = (self.tool == PaintTool.PAINT) ? self.stroke_width : self.eraser_width;
            int color  = (self.tool == PaintTool.PAINT) ? self.selected_color : -1;
            draw_circle(self, ccol, crow, radius, color);
            self.last_draw_col = ccol;
            self.last_draw_row = crow;
            return null;
        }

        if (msg.mouse.action == tea::MouseAction.MOUSE_MOTION && self.was_pressing && in_canvas) {
            int radius = (self.tool == PaintTool.PAINT) ? self.stroke_width : self.eraser_width;
            int color  = (self.tool == PaintTool.PAINT) ? self.selected_color : -1;
            if (self.last_draw_col >= 0 && self.last_draw_row >= 0) {
                draw_line(self, self.last_draw_col, self.last_draw_row, ccol, crow, radius, color);
            } else {
                draw_circle(self, ccol, crow, radius, color);
            }
            self.last_draw_col = ccol;
            self.last_draw_row = crow;
            return null;
        }

        if (msg.mouse.action == tea::MouseAction.MOUSE_RELEASE) {
            self.was_pressing = false;
            self.last_draw_col = -1;
            self.last_draw_row = -1;
        }

        return null;
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q' || k.rune == 'Q') return tea::quit();
            if (k.rune == 'p' || k.rune == 'P') {
                self.tool = PaintTool.PAINT;
            } else if (k.rune == 'e' || k.rune == 'E') {
                self.tool = PaintTool.ERASER;
            } else if (k.rune == 'c' || k.rune == 'C') {
                clear_canvas(self);
            } else if (k.rune >= '1' && k.rune <= '8') {
                self.selected_color = (char)(k.rune - '1');
            } else if (k.rune >= 'a' && k.rune <= 'c') {
                self.stroke_width = (int)(k.rune - 'a') + 1;
            }
        default:
    }
    return null;
}

// ── View ────────────────────────────────────────────────────────────────────

fn tea::View Model.view(Model* self) @dynamic {
    DString out = dstring::temp();

    int tw = self.term_width;
    int th = self.term_height;

    if (tw == 0 || th == 0) {
        return tea::new_alt_screen_view("");
    }

    String bg_empty = PALETTE_HEX[0];

    for (int row = 0; row < th; row++) {

        // ── Palette column (col 0) ────────────────────────────────────────
        {
            String cell_bg  = bg_empty;
            char   cell_ch = ' ';
            String fg       = "#333333";

            if (row >= 1 && row <= 8) {
                char swatch = (char)(row - 1);
                cell_bg = PALETTE_HEX[swatch];
                if (swatch == self.selected_color) {
                    cell_ch = '>';
                    fg = "#ffffff";
                }
            } else if (row == 9) {
                cell_bg = bg_empty;
                cell_ch = (char)('0' + self.stroke_width);
                fg = "#888888";
            } else if (row == 0) {
                cell_ch = '|';
                fg = "#444444";
            }

            lipgloss::Style s = lipgloss::new_style()
                .foreground(lipgloss::color_hex(fg))
                .background(lipgloss::color_hex(cell_bg));
            out.append_string(s.render(string::tformat("%c", cell_ch)));
        }

        // ── Toolbar row (row 0, cols 1+) ────────────────────────────────
        if (row == 0) {
            // Paint button
            {
                String lbl = self.tool == PaintTool.PAINT ? "[*Paint*]" : "[ Paint ]";
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex(self.tool == PaintTool.PAINT ? "#000000" : "#aaaaaa"))
                    .background(lipgloss::color_hex(self.tool == PaintTool.PAINT ? "#55ff55" : "#333333"));
                out.append_string(s.render(lbl));
            }
            // Separator
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#555555"))
                    .background(lipgloss::color_hex("#222222"));
                out.append_string(s.render("|"));
            }
            // Stroke width 1-3
            for (int w = 1; w <= 3; w++) {
                bool active = (self.tool == PaintTool.PAINT && w == self.stroke_width);
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex(active ? "#000000" : "#888888"))
                    .background(lipgloss::color_hex(active ? "#55ffff" : "#222222"));
                out.append_string(s.render(string::tformat("%d", w)));
            }
            // Separator
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#555555"))
                    .background(lipgloss::color_hex("#222222"));
                out.append_string(s.render("|"));
            }
            // Eraser button
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex(self.tool == PaintTool.ERASER ? "#000000" : "#aaaaaa"))
                    .background(lipgloss::color_hex(self.tool == PaintTool.ERASER ? "#ff55ff" : "#333333"));
                out.append_string(s.render("[Eraser]"));
            }
            // Separator
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#555555"))
                    .background(lipgloss::color_hex("#222222"));
                out.append_string(s.render("|"));
            }
            // Clear All
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#ff5555"))
                    .background(lipgloss::color_hex("#222222"));
                out.append_string(s.render("[Clr]"));
            }
            // Separator
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#555555"))
                    .background(lipgloss::color_hex("#222222"));
                out.append_string(s.render("|"));
            }
            // Color palette row: clickable colors 0-7
            for (int c = 0; c < 8; c++) {
                bool selected = (c == self.selected_color);
                String cell_bg = PALETTE_HEX[c];
                String fg = (c == 7) ? "#000000" : "#ffffff"; // white for dark, black for white
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex(fg))
                    .background(lipgloss::color_hex(cell_bg))
                    .set_bold(selected);
                char label = (char)(c + '1');
                out.append_string(s.render(string::tformat("%c", label)));
            }
            // Fill rest of toolbar row
            {
                int written = 11 + 1 + 3 + 1 + 8 + 1 + 5 + 1 + 8;
                int remaining = tw - written;
                if (remaining > 0) {
                    lipgloss::Style s = lipgloss::new_style()
                        .foreground(lipgloss::color_hex("#333333"))
                        .background(lipgloss::color_hex("#222222"));
                    for (int i = 0; i < remaining; i++) {
                        out.append_char(' ');
                    }
                }
            }
            out.append_char('\n');
            continue;
        }

        // ── Canvas rows ─────────────────────────────────────────────────
        {
            int canvas_row = row - self.canvas_y;

            if (canvas_row < 0 || canvas_row >= self.canvas_height) {
                // Fill gap rows with dark background
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#222222"))
                    .background(lipgloss::color_hex("#111111"));
                for (int i = 1; i < tw; i++) {
                    out.append_string(s.render(" "));
                }
                out.append_char('\n');
                continue;
            }

            // Vertical separator after palette column.
            {
                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex("#444444"))
                    .background(lipgloss::color_hex(bg_empty));
                out.append_string(s.render("|"));
            }

            // Canvas cells.
            for (int canvas_col = 0; canvas_col < self.canvas_width; canvas_col++) {
                sz idx = (sz)canvas_row * (sz)self.canvas_width + (sz)canvas_col;
                int color_idx = self.canvas[idx];
                String cell_bg = bg_empty;
                char   cell_ch = ' ';
                String cell_fg = "#222222";

                if (color_idx >= 0) {
                    cell_bg = PALETTE_HEX[color_idx];
                    cell_ch = '#';
                    cell_fg = PALETTE_HEX[color_idx];
                }

                lipgloss::Style s = lipgloss::new_style()
                    .foreground(lipgloss::color_hex(cell_fg))
                    .background(lipgloss::color_hex(cell_bg));
                out.append_string(s.render(string::tformat("%c", cell_ch)));
            }

            out.append_char('\n');
        }
    }

    return tea::new_alt_screen_view(out.str_view());
}

// ── Entry point ────────────────────────────────────────────────────────────

fn int main() {
    Model m = {};
    tea::enter_alt_screen();
    tea::enable_mouse();
    defer { tea::disable_mouse(); }

    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}