module lipgloss;

import std::core::dstring;

// Join two strings horizontally, line by line.
// The shorter string is padded with spaces on the right.
fn String join_horizontal(String left, String right, int gap) {
    String[128] left_lines;
    String[128] right_lines;
    sz left_count = 0;
    sz right_count = 0;

    sz start = 0;
    for (sz i = 0; i <= left.len; i++) {
        if (i == left.len || left[i] == '\n') {
            if (left_count < left_lines.len) {
                left_lines[left_count] = left[start:i - start];
                left_count++;
            }
            start = i + 1;
            if (i == left.len) break;
        }
    }
    start = 0;
    for (sz i = 0; i <= right.len; i++) {
        if (i == right.len || right[i] == '\n') {
            if (right_count < right_lines.len) {
                right_lines[right_count] = right[start:i - start];
                right_count++;
            }
            start = i + 1;
            if (i == right.len) break;
        }
    }

    // Find max width of left lines
    int max_left_w = 0;
    for (sz i = 0; i < left_count; i++) {
        int w = string_width(left_lines[i]);
        if (w > max_left_w) max_left_w = w;
    }

    int total = (int)left_count;
    if ((int)right_count > total) total = (int)right_count;

    DString out = dstring::temp();
    for (int i = 0; i < total; i++) {
        String l = (i < (int)left_count) ? left_lines[i] : "";
        String r = (i < (int)right_count) ? right_lines[i] : "";

        int l_w = string_width(l);
        out.append_string(l);
        for (int p = l_w; p < max_left_w + gap; p++) out.append_char(' ');
        out.append_string(r);
        if (i < total - 1) out.append_char('\n');
    }
    return out.str_view();
}

// Place content centered in the given width and height.
fn String place(int width, int height, String content) {
    // Split content into lines
    String[256] lines;
    sz line_count = 0;
    sz start = 0;
    for (sz i = 0; i <= content.len; i++) {
        if (i == content.len || content[i] == '\n') {
            lines[line_count] = content[start:i - start];
            line_count++;
            start = i + 1;
            if (i == content.len) break;
        }
    }

    // Find max content width
    int content_w = 0;
    for (sz i = 0; i < line_count; i++) {
        int w = string_width(lines[i]);
        if (w > content_w) content_w = w;
    }

    int content_h = (int)line_count;
    int pad_top = (height - content_h) / 2;
    if (pad_top < 0) pad_top = 0;
    int pad_left = (width - content_w) / 2;
    if (pad_left < 0) pad_left = 0;

    DString out = dstring::temp();

    // Top padding
    for (int i = 0; i < pad_top; i++) {
        for (int j = 0; j < width; j++) out.append_char(' ');
        out.append_char('\n');
    }

    // Content lines
    for (sz i = 0; i < line_count; i++) {
        for (int j = 0; j < pad_left; j++) out.append_char(' ');
        out.append_string(lines[i]);
        int w = string_width(lines[i]);
        for (int j = w + pad_left; j < width; j++) out.append_char(' ');
        if (i < line_count - 1) out.append_char('\n');
    }

    // Bottom padding
    for (int i = pad_top + content_h; i < height; i++) {
        out.append_char('\n');
        for (int j = 0; j < width; j++) out.append_char(' ');
    }

    return out.str_view();
}