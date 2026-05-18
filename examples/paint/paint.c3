module paint;

import tea;
import lipgloss;
import xray;
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

// ── Canvas ────────────────────────────────────────────────────────────────────

// Pixel bitmap. width × height pixels, each cell is a color index (0-7) or -1 for empty.
struct Canvas {
    int[] pixels;
    int width;
    int height;
}

fn void Canvas.resize(Canvas* self, int width, int height) {
    self.width  = width  < 1 ? 1 : width;
    self.height = height < 1 ? 1 : height;
    sz total = (sz)self.width * (sz)self.height;
    if (self.pixels.ptr != null) mem::free(self.pixels.ptr);
    self.pixels = mem::new_array(int, total);
    for (sz i = 0; i < total; i++) self.pixels[i] = -1;
}

fn void Canvas.clear(Canvas* self) {
    for (sz i = 0; i < self.pixels.len; i++) self.pixels[i] = -1;
}

fn void Canvas.set_pixel(Canvas* self, int x, int y, int color) {
    if (x < 0 || x >= self.width || y < 0 || y >= self.height) return;
    self.pixels[(sz)y * (sz)self.width + (sz)x] = color;
}

fn int Canvas.get_pixel(Canvas* self, int x, int y) {
    if (x < 0 || x >= self.width || y < 0 || y >= self.height) return -1;
    return self.pixels[(sz)y * (sz)self.width + (sz)x];
}

fn void Canvas.draw_circle(Canvas* self, int cx, int cy, int radius, int color) {
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int dist_sq  = dx*dx + dy*dy;
            int radius_sq = radius*radius;
            if (dist_sq < radius_sq || (dist_sq <= radius_sq + 2*radius && dist_sq <= radius_sq + radius)) {
                self.set_pixel(cx + dx, cy + dy, color);
            }
        }
    }
}

fn void Canvas.draw_line(Canvas* self, int x0, int y0, int x1, int y1, int radius, int color) {
    int dx = x1 - x0;
    int dy = y1 - y0;
    int steps = dx < 0 ? -dx : dx;
    int dy_abs = dy < 0 ? -dy : dy;
    if (steps < dy_abs) steps = dy_abs;
    if (steps < 1) steps = 1;
    for (int i = 0; i <= steps; i++) {
        self.draw_circle(x0 + (dx * i) / steps, y0 + (dy * i) / steps, radius, color);
    }
}

// ── Model ─────────────────────────────────────────────────────────────────────

struct Model {
    int term_width;
    int term_height;

    Canvas canvas;
    xray::Rect palette_rect;  // left sidebar
    xray::Rect canvas_rect;   // canvas area (in terminal cells; each row = 2 pixel rows)

    char selected_color; // 0-7
    PaintTool tool;
    int stroke_width;    // 1-3
    int eraser_width;    // 1-3

    bool was_pressing;
    int last_draw_row;   // in canvas pixel coords
    int last_draw_col;

    int hover_row;
    int hover_col;
}

// ── Tea Model ─────────────────────────────────────────────────────────────────

fn tea::Cmd Model.init(Model* self) @dynamic {
    self.selected_color = 1;
    self.tool = PaintTool.PAINT;
    self.stroke_width = 1;
    self.eraser_width = 2;
    self.was_pressing = false;
    self.last_draw_row = -1;
    self.last_draw_col = -1;
    self.hover_row = -1;
    self.hover_col = -1;
    return null;
}

fn tea::Cmd Model.update(Model* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.term_width  = msg.window_size.width;
        self.term_height = msg.window_size.height;
        // Row 0 = toolbar; remaining rows split into palette (5 wide) + canvas
        xray::Rect body = xray::new_rect(0, 1, self.term_width, self.term_height - 1);
        xray::Rect[2] cols;
        xray::layout_h(body, { xray::constraint_len(5), xray::constraint_fill(1) }, cols[..]);
        self.palette_rect = cols[0];
        self.canvas_rect  = cols[1];
        self.canvas.resize(self.canvas_rect.w, self.canvas_rect.h * 2);
        return null;
    }

    if (msg.kind == tea::MsgKind.MOUSE) {
        int col = msg.mouse.col;
        int row = msg.mouse.row;

        self.hover_col = col;
        self.hover_row = row;

        // ── Color palette ────────────────────────────────────────────────────
        if (self.palette_rect.contains(col, row)) {
            int color_idx = (row - self.palette_rect.y) / 3;
            if (color_idx < 8) {
                self.selected_color = (char)color_idx;
                return null;
            }
        }

        // ── Toolbar (row 0) ──────────────────────────────────────────────────
        if (row == 0) {
            if (col >= 5 && col <= 13)  { self.tool = PaintTool.PAINT;  return null; }
            if (col == 15)              { self.stroke_width = 1;         return null; }
            if (col == 16)              { self.stroke_width = 2;         return null; }
            if (col == 17)              { self.stroke_width = 3;         return null; }
            if (col >= 19 && col <= 28) { self.tool = PaintTool.ERASER; return null; }
            if (col >= 30 && col <= 34) { self.canvas.clear();          return null; }
            return null;
        }

        // ── Canvas ───────────────────────────────────────────────────────────
        int ccol = col - self.canvas_rect.x;
        // Each terminal row = 2 canvas pixel rows; map here, once.
        int crow = (row - self.canvas_rect.y) * 2;
        bool in_canvas = ccol >= 0 && ccol < self.canvas.width
                      && crow >= 0 && crow < self.canvas.height;

        if (msg.mouse.action == tea::MouseAction.MOUSE_PRESS && in_canvas) {
            self.was_pressing = true;
            int radius = (self.tool == PaintTool.PAINT) ? self.stroke_width : self.eraser_width;
            int color  = (self.tool == PaintTool.PAINT) ? (int)self.selected_color : -1;
            self.canvas.draw_circle(ccol, crow, radius, color);
            self.last_draw_col = ccol;
            self.last_draw_row = crow;
            return null;
        }

        if (msg.mouse.action == tea::MouseAction.MOUSE_MOTION && self.was_pressing && in_canvas) {
            int radius = (self.tool == PaintTool.PAINT) ? self.stroke_width : self.eraser_width;
            int color  = (self.tool == PaintTool.PAINT) ? (int)self.selected_color : -1;
            if (self.last_draw_col >= 0 && self.last_draw_row >= 0) {
                self.canvas.draw_line(self.last_draw_col, self.last_draw_row, ccol, crow, radius, color);
            } else {
                self.canvas.draw_circle(ccol, crow, radius, color);
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
                self.canvas.clear();
            } else if (k.rune >= '1' && k.rune <= '8') {
                self.selected_color = (char)(k.rune - '1');
            } else if (k.rune == '+' || k.rune == '=') {
                if (self.stroke_width < 3) self.stroke_width++;
                if (self.eraser_width < 3) self.eraser_width++;
            } else if (k.rune == '-' || k.rune == '_') {
                if (self.stroke_width > 1) self.stroke_width--;
                if (self.eraser_width > 1) self.eraser_width--;
            } else if (k.rune >= 'a' && k.rune <= 'c') {
                self.stroke_width = (int)(k.rune - 'a') + 1;
            }
        default:
    }
    return null;
}

// ── View helpers ──────────────────────────────────────────────────────────────

fn String build_palette_column(Model* self) {
    DString out = dstring::temp();
    String bg_empty = PALETTE_HEX[0];

    for (int color_idx = 0; color_idx < 8; color_idx++) {
        bool selected = (color_idx == self.selected_color);
        String cell_bg = PALETTE_HEX[color_idx];
        String fg = (color_idx == 7) ? "#000000" : "#ffffff";

        lipgloss::Style s = lipgloss::new_style()
            .foreground(lipgloss::color_hex(fg))
            .background(lipgloss::color_hex(cell_bg));

        for (int row = 0; row < 3; row++) {
            String content = (selected && row == 1) ? "  ✓  " : "     ";
            out.append_string(s.render(content));
            out.append_char('\n');
        }
    }

    lipgloss::Style s = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"))
        .background(lipgloss::color_hex(bg_empty));
    out.append_string(s.render(string::tformat("W:%d", self.stroke_width)));

    return out.str_view();
}

fn String build_tools_toolbar(Model* self) {
    DString out = dstring::temp();

    out.append_string(self.tool == PaintTool.PAINT ? "[*Paint*]" : "[ Paint ]");
    out.append_string(" | ");
    for (int w = 1; w <= 3; w++) {
        bool active = (self.tool == PaintTool.PAINT && w == self.stroke_width);
        lipgloss::Style s = lipgloss::new_style()
            .foreground(lipgloss::color_hex(active ? "#000000" : "#888888"))
            .background(lipgloss::color_hex(active ? "#55ffff" : "#222222"));
        out.append_string(s.render(string::tformat("%d", w)));
    }
    out.append_string(" | ");
    out.append_string(self.tool == PaintTool.ERASER ? "[*Eraser*]" : "[ Eraser ]");
    out.append_string(" | ");
    out.append_string("[Clr]");

    return out.str_view();
}

fn String build_top_bar(Model* self, int width) {
    String tools = build_tools_toolbar(self);
    int remaining = width - 1 - lipgloss::string_width(tools);
    if (remaining > 0) {
        DString pad = dstring::temp();
        for (int i = 0; i < remaining; i++) pad.append_char(' ');
        return lipgloss::join_horizontal(tools, pad.str_view(), 0);
    }
    return tools;
}

fn String build_canvas_view(Canvas* c) {
    DString out = dstring::temp();
    String bg_empty = PALETTE_HEX[0];

    // Two canvas pixel rows per terminal row via half-block characters.
    for (int py = 0; py < c.height; py += 2) {
        lipgloss::Style sep = lipgloss::new_style()
            .foreground(lipgloss::color_hex("#444444"))
            .background(lipgloss::color_hex(bg_empty));
        out.append_string(sep.render("|"));

        for (int px = 0; px < c.width; px++) {
            int top    = c.get_pixel(px, py);
            int bottom = c.get_pixel(px, py + 1);

            String top_hex    = (top    >= 0) ? PALETTE_HEX[top]    : bg_empty;
            String bottom_hex = (bottom >= 0) ? PALETTE_HEX[bottom] : bg_empty;

            String glyph, fg, bg;
            if (top >= 0 && bottom >= 0 && top == bottom) {
                glyph = "█"; fg = top_hex;    bg = top_hex;
            } else if (top >= 0 && bottom >= 0) {
                glyph = "▀"; fg = top_hex;    bg = bottom_hex;
            } else if (top >= 0) {
                glyph = "▀"; fg = top_hex;    bg = bg_empty;
            } else if (bottom >= 0) {
                glyph = "▄"; fg = bottom_hex; bg = bg_empty;
            } else {
                glyph = " "; fg = "#222222";  bg = bg_empty;
            }

            lipgloss::Style s = lipgloss::new_style()
                .foreground(lipgloss::color_hex(fg))
                .background(lipgloss::color_hex(bg));
            out.append_string(s.render(glyph));
        }
        out.append_char('\n');
    }
    return out.str_view();
}

// ── View ──────────────────────────────────────────────────────────────────────

fn tea::View Model.view(Model* self) @dynamic {
    if (self.term_width == 0 || self.term_height == 0) {
        return tea::new_alt_screen_view("");
    }

    String top_bar      = build_top_bar(self, self.term_width);
    String palette      = build_palette_column(self);
    String canvas_view  = build_canvas_view(&self.canvas);
    String content_area = lipgloss::join_horizontal(palette, canvas_view, 0);
    String content      = lipgloss::join_vertical(lipgloss::Position.LEFT, top_bar, content_area);

    return tea::new_alt_screen_view(content).set_mouse_cursor("crosshair");
}

// ── Entry point ───────────────────────────────────────────────────────────────

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
