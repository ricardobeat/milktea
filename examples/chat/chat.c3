module chat_example;

import tea;
import lipgloss;
import std::io;
import std::core::string;
import std::core::dstring;

const int MSG_TICK = 1;
const int BUF_SIZE = 512;

struct ChatModel {
    char[BUF_SIZE] input_buf;
    sz input_len;
    sz input_cursor;
    String[64] messages;
    String[64] senders;
    int msg_count;
    int scroll;
    int width;
    int height;
    int cursor_blink;
}

fn tea::Cmd ChatModel.init(ChatModel* self) @dynamic {
    // Add some initial messages
    self.messages[0] = "Welcome to the chat room!";
    self.senders[0] = "system";
    self.messages[1] = "Type a message and press Enter to send.";
    self.senders[1] = "system";
    self.msg_count = 2;
    return tea::tick(500, &on_tick);
}

fn tea::Msg on_tick() {
    return { .kind = tea::MsgKind.USER, .tag = MSG_TICK };
}

fn tea::Cmd ChatModel.update(ChatModel* self, tea::Msg msg) @dynamic {
    if (msg.kind == tea::MsgKind.WINDOW_SIZE) {
        self.width = msg.window_size.width;
        self.height = msg.window_size.height;
        return null;
    }
    if (msg.kind == tea::MsgKind.USER && msg.tag == MSG_TICK) {
        self.cursor_blink = 1 - self.cursor_blink;
        return tea::tick(500, &on_tick);
    }
    if (msg.kind != tea::MsgKind.KEY) return null;
    tea::KeyMsg k = msg.key;

    switch (k.code) {
        case tea::KeyCode.CTRL_C:
        case tea::KeyCode.ESC:
            return tea::quit();
        case tea::KeyCode.ENTER:
            if (self.input_len > 0 && self.msg_count < 64) {
                self.messages[self.msg_count] = (String)self.input_buf[:self.input_len];
                self.senders[self.msg_count] = "You";
                self.msg_count++;
                self.input_len = 0;
                self.input_cursor = 0;
            }
        case tea::KeyCode.BACKSPACE:
            if (self.input_cursor > 0) {
                for (sz i = self.input_cursor; i < self.input_len; i++) {
                    self.input_buf[i - 1] = self.input_buf[i];
                }
                self.input_len--;
                self.input_cursor--;
            }
        case tea::KeyCode.LEFT:
            if (self.input_cursor > 0) self.input_cursor--;
        case tea::KeyCode.RIGHT:
            if (self.input_cursor < self.input_len) self.input_cursor++;
        case tea::KeyCode.RUNE:
            if (k.rune == 'q' && self.input_len == 0) return tea::quit();
            if (self.input_len < BUF_SIZE - 1) {
                for (sz i = self.input_len; i > self.input_cursor; i--) {
                    self.input_buf[i] = self.input_buf[i - 1];
                }
                self.input_buf[self.input_cursor] = k.rune;
                self.input_len++;
                self.input_cursor++;
            }
        default:
    }
    return null;
}

fn tea::View ChatModel.view(ChatModel* self) @dynamic {
    lipgloss::Style you_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
    lipgloss::Style sys_style = lipgloss::new_style().foreground(lipgloss::color_hex("#888888"));
    lipgloss::Style input_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ffffff"));
    lipgloss::Style hint_style = lipgloss::new_style().foreground(lipgloss::color_hex("#444444"));
    lipgloss::Style border_style = lipgloss::new_style().set_border({ .top="-", .bottom="-", .left="|", .right="|",
                                                                       .top_left="+", .top_right="+", .bottom_left="+", .bottom_right="+" });
    lipgloss::Style title_style = lipgloss::new_style().foreground(lipgloss::color_hex("#ff00ff")).set_bold(true);

    int msg_area_h = self.height - 5;
    if (msg_area_h < 3) msg_area_h = 3;

    DString out = dstring::temp();
    out.append_string(title_style.render("💬 Chat Room"));
    out.append_char('\n');

    // Show messages (bottom-aligned)
    int start = self.msg_count - msg_area_h;
    if (start < 0) start = 0;

    for (int i = start; i < self.msg_count; i++) {
        String sender = self.senders[i];
        String msg = self.messages[i];
        lipgloss::Style s = (sender == "You") ? you_style : sys_style;
        out.append_string(s.render(string::tformat("%s: %s", sender, msg)));
        out.append_char('\n');
    }

    // Fill remaining lines
    int shown = self.msg_count - start;
    for (int i = shown; i < msg_area_h; i++) {
        out.append_char('\n');
    }

    // Input area
    String input_text = (String)self.input_buf[:self.input_len];
    DString input_line = dstring::temp();
    input_line.append_string("┃ ");
    input_line.append_string(input_text);
    if (self.cursor_blink != 0) {
        input_line.append_string("▎");
    }
    out.append_string(border_style.render(input_line.str_view()));
    out.append_char('\n');
    out.append_string(hint_style.render("ENTER send | ESC quit"));
    return tea::new_alt_screen_view(out.str_view());
}

fn int main() {
    ChatModel m = {};
    if (catch err = tea::run((tea::Model)&m)) {
        io::printfn("Error: %s", err);
        return 1;
    }

    io::printn("Bye!");
    return 0;
}