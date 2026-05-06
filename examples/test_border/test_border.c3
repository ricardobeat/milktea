module test_border;

import lipgloss;
import std::io;
import std::core::dstring;
import std::core::string;

fn int main() {
    lipgloss::Style active = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#ff00ff"))
        .set_bold(true);

    lipgloss::Style label = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#888888"));

    lipgloss::Style title = lipgloss::new_style()
        .foreground(lipgloss::color_hex("#00d7ff"))
        .set_bold(true)
        .padding(1, 0, 1, 0);

    lipgloss::Style box_style = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(1, 2, 1, 2);

    io::printfn("width('∙') = %d (terminal: 1)", lipgloss::string_width("∙"));
    io::printfn("width('←') = %d (terminal: 1)", lipgloss::string_width("←"));
    io::printfn("width('●') = %d (terminal: 1)", lipgloss::string_width("●"));

    // Build content like spinners.c3 does
    DString content = dstring::temp();
    content.append_string(title.render("Spinner Gallery"));
    content.append_char('\n');

    // Simulate 6 spinners on one line
    content.append_string(active.render("  ⠋"));
    content.append_string(label.render("  Dots"));
    content.append_string("   ");
    content.append_string(active.render("  -"));
    content.append_string(label.render("  Lines"));
    content.append_string("   ");
    content.append_string(active.render("  ←"));
    content.append_string(label.render("  Arrow"));
    content.append_string("   ");
    content.append_string(active.render("  ▏"));
    content.append_string(label.render("  Blocks"));
    content.append_string("   ");
    content.append_string(active.render("  🌑"));
    content.append_string(label.render("  Moon"));
    content.append_string("   ");
    content.append_string(active.render("  ∙●∙"));
    content.append_string(label.render("  Pulse"));
    content.append_string("   ");

    content.append_char('\n');
    content.append_string(label.render("Press q or ESC to quit"));

    String raw_content = content.str_view();

    io::printfn("\n=== Raw content lines ===");
    usz ls = 0;
    int ln = 0;
    for (usz i = 0; i <= raw_content.len; i++) {
        if (i == raw_content.len || raw_content[i] == '\n') {
            String line = raw_content[ls:i - ls];
            io::printfn("raw[%d] visual_width=%d byte_len=%d", ln, lipgloss::string_width(line), (int)line.len);
            ls = i + 1;
            ln++;
            if (i == raw_content.len) break;
        }
    }

    String result = box_style.render(raw_content);

    io::printfn("\n=== Boxed output ===");
    io::printfn("%s", result);

    io::printfn("\n=== Boxed line widths ===");
    ls = 0;
    ln = 0;
    for (usz i = 0; i <= result.len; i++) {
        if (i == result.len || result[i] == '\n') {
            String line = result[ls:i - ls];
            io::printfn("line[%d] visual_width=%d byte_len=%d", ln, lipgloss::string_width(line), (int)line.len);
            ls = i + 1;
            ln++;
            if (i == result.len) break;
        }
    }

    // Now test: does the box_style.pad_right get doubled?
    io::printfn("\n=== Checking pad_right doubling ===");
    lipgloss::Style simple = lipgloss::new_style()
        .set_border(lipgloss::rounded_border())
        .padding(0, 2, 0, 2);
    String r2 = simple.render("Hi\nThere");
    io::printfn("Simple box (pad 0,2,0,2):\n%s", r2);

    // Check widths
    ls = 0;
    ln = 0;
    for (usz i = 0; i <= r2.len; i++) {
        if (i == r2.len || r2[i] == '\n') {
            String line = r2[ls:i - ls];
            io::printfn("line[%d] visual_width=%d byte_len=%d", ln, lipgloss::string_width(line), (int)line.len);
            ls = i + 1;
            ln++;
            if (i == r2.len) break;
        }
    }

    return 0;
}
