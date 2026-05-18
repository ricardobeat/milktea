// inputbox — minimal xray layout input box test.
//
// Keys: any printable char → append, backspace → delete, q alone → quit, enter → submit
module inputbox;

import tea;
import lipgloss;
import xray;
import std::io;
import std::core::dstring;

struct Model {
    DString input;
    DString output;
    int width;
    int height;
}

fn tea::Cmd Model.init(&self) @dynamic {
    self.input.tinit();
    self.output.tinit();
    self.output.append_string("Type something below.\n");
    self.output.append_string("Enter to submit, q (alone) to quit.");
    return null;
}

fn tea::Cmd Model.update(&self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width  = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind != tea::MsgKind.KEY) return null;

    tea::KeyMsg k = msg.key;
    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.ENTER:
            if (self.input.len() > 0) {
                self.output.append_char('\n');
                self.output.append_string(">> ");
                self.output.append_string(self.input.str_view());
                self.input.clear();
            }
        case tea::KeyCode.BACKSPACE:
            sz l = self.input.len();
            if (l > 0) self.input.chop(l - 1);
        case tea::KeyCode.RUNE:
            if (k.rune == 'q' && self.input.len() == 0) return tea::quit();
            self.input.append_char(k.rune);
        default:
    }
    return null;
}

fn tea::View Model.view(&self) @dynamic {
    int w = self.width  > 0 ? self.width  : 80;
    int h = self.height > 0 ? self.height : 24;

    xray::ScreenBuffer* screen = xray::new_screen_buffer((sz)w, (sz)h);
    xray::Rect full = xray::new_rect(0, 0, w, h);

    // Three rows: header(1) | output(fill) | input(3) | help(1)
    xray::Constraint[4] cs = {
        xray::constraint_len(1),
        xray::constraint_fill(1),
        xray::constraint_len(3),
        xray::constraint_len(1),
    };
    xray::Rect[4] rects;
    xray::layout_v_gap(full, cs[..], 0, rects[..]);

    // Header
    lipgloss::Style hdr = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00ffcc"))
        .set_bold(true)
        .set_width(w);
    String hdr_str = hdr.render("  INPUTBOX TEST");
    screen.render_ansi_string((sz)rects[0].x, (sz)rects[0].y, hdr_str, xray::default_style());

    // Output area
    lipgloss::Style out_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#aaaaaa"))
        .set_width(rects[1].w)
        .set_height(rects[1].h);
    String out_str = out_style.render(self.output.str_view());
    screen.render_ansi_string((sz)rects[1].x, (sz)rects[1].y, out_str, xray::default_style());

    // Input box: bordered, pad_x=1
    lipgloss::Style inp_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ffff00"))
        .set_border(lipgloss::rounded_border())
        .padding(0, 1, 0, 1)
        .set_width(rects[2].w - 2)   // subtract border (1 each side)
        .set_height(rects[2].h - 2); // subtract border (1 each side)
    String inp_content = string::tformat("> %s█", self.input.str_view());
    String inp_str = inp_style.render(inp_content);
    screen.render_ansi_string((sz)rects[2].x, (sz)rects[2].y, inp_str, xray::default_style(), (sz)(rects[2].y + rects[2].h));

    // Help line
    lipgloss::Style help_style = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#555555"))
        .set_width(w);
    String help_len_str = string::tformat("  input len: %d chars", (int)self.input.len());
    String help_str = help_style.render(help_len_str);
    screen.render_ansi_string((sz)rects[3].x, (sz)rects[3].y, help_str, xray::default_style());

    tea::View view = tea::new_alt_cell_view(screen.cells[0:(sz)w * (sz)h], (sz)w, (sz)h);
    screen.destroy();
    mem::free(screen);
    return view;
}

fn void Model.on_destroy(&self) @dynamic {
    self.input.free();
    self.output.free();
}

fn int main() {
    Model m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }
    return 0;
}
