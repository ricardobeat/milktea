module bounce;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;

struct BounceModel {
    int ball_x;
    int ball_y;
    int dx;
    int dy;
    int width;
    int height;
    int ticks;
}

fn tea::Cmd BounceModel.init(BounceModel* self) @dynamic {
    self.ball_x = 5;
    self.ball_y = 3;
    self.dx = 1;
    self.dy = 1;
    return tea::tick(60, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd BounceModel.update(BounceModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }

    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.ticks++;

        // Bounce area is smaller than the terminal
        int arena_w = self.width - 4;
        int arena_h = self.height - 6;
        if (arena_w < 5) arena_w = 5;
        if (arena_h < 3) arena_h = 3;

        self.ball_x += self.dx;
        self.ball_y += self.dy;

        if (self.ball_x <= 0 || self.ball_x >= arena_w) {
            self.dx = -self.dx;
            if (self.ball_x < 0) self.ball_x = 0;
            if (self.ball_x > arena_w) self.ball_x = arena_w;
        }
        if (self.ball_y <= 0 || self.ball_y >= arena_h) {
            self.dy = -self.dy;
            if (self.ball_y < 0) self.ball_y = 0;
            if (self.ball_y > arena_h) self.ball_y = arena_h;
        }

        return tea::tick(60, &on_tick);
    }

    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
            return tea::quit();
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.RUNE:
            if (k.rune == 'q') return tea::quit();
        default:
    }
    return null;
}

fn tea::View BounceModel.view(BounceModel* self) @dynamic {
    int arena_w = self.width - 4;
    int arena_h = self.height - 6;
    if (arena_w < 5) arena_w = 5;
    if (arena_h < 3) arena_h = 3;

    String[4] ball_frames = { "🔴", "🟠", "🟡", "🟢" };
    String ball = ball_frames[self.ticks % 4];

    DString out = dstring::temp();

    // Top border
    out.append_string("╔");
    for (int x = 0; x < arena_w; x++) out.append_string("═");
    out.append_string("╗\n");

    for (int y = 0; y < arena_h; y++) {
        out.append_string("║");
        if (y == self.ball_y) {
            for (int x = 0; x < arena_w; x++) {
                if (x == self.ball_x) {
                    out.append_string(ball);
                } else {
                    out.append_char(' ');
                }
            }
        } else {
            for (int x = 0; x < arena_w; x++) {
                out.append_char(' ');
            }
        }
        out.append_string("║\n");
    }

    // Bottom border
    out.append_string("╚");
    for (int x = 0; x < arena_w; x++) out.append_string("═");
    out.append_string("╝\n");

    lipgloss::Style hint = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
    out.append_string(hint.render("Bouncing ball  |  q/ESC quit"));

    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    BounceModel m = {};
    if (catch err = tea::@run_program(&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}