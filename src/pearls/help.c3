module pearls;

import lipgloss;
import std::core::dstring;

// HelpEntry is a single key-action pair for display.
struct HelpEntry {
	String key;
	String description;
}

// Help is a help text rendering component.
struct Help {
	HelpEntry[16] entries;
	int count;
	lipgloss::Style key_style;
	lipgloss::Style desc_style;
	lipgloss::Style separator_style;
	String separator;
}

// new_help creates an empty help component.
fn Help new_help() {
	Help h = { };
	h.key_style = lipgloss::new_style().foreground(lipgloss::color_hex("#00d7ff")).set_bold(true);
	h.desc_style = lipgloss::new_style().foreground(lipgloss::color_hex("#666666"));
	h.separator_style = lipgloss::new_style().foreground(lipgloss::color_hex("#444444"));
	h.separator = " | ";
	return h;
}

// with_styles returns a copy with custom styles.
fn Help Help.with_styles(self, lipgloss::Style key_s, lipgloss::Style desc_s) {
	Help h = self;
	h.key_style = key_s;
	h.desc_style = desc_s;
	return h;
}

// with_separator returns a copy with a custom separator string.
fn Help Help.with_separator(self, String sep) {
	Help h = self;
	h.separator = sep;
	return h;
}

// add_entry adds a key-description pair.
fn void Help.add_entry(&self, String key, String desc) {
	if (self.count >= 16) return;
	self.entries[self.count] = { .key = key, .description = desc };
	self.count++;
}

// clear removes all entries.
fn void Help.clear(&self) {
	self.count = 0;
}

// view returns the rendered help string with all entries joined by the separator.
fn String Help.view(&self) {
	DString out = dstring::temp();
	for (int i = 0; i < self.count; i++) {
		if (i > 0) {
			out.append_string(self.separator_style.render(self.separator));
		}
		out.append_string(self.key_style.render(self.entries[i].key));
		out.append_char(' ');
		out.append_string(self.desc_style.render(self.entries[i].description));
	}
	return out.str_view();
}

// view_vertical returns entries rendered one per line.
fn String Help.view_vertical(&self) {
	DString out = dstring::temp();
	for (int i = 0; i < self.count; i++) {
		out.append_string(self.key_style.render(self.entries[i].key));
		out.append_char(' ');
		out.append_string(self.desc_style.render(self.entries[i].description));
		if (i < self.count - 1) out.append_char('\n');
	}
	return out.str_view();
}

// default_help returns a common help bar.
fn Help default_help() {
	Help h = new_help();
	h.add_entry("q", "quit");
	h.add_entry("esc", "quit");
	h.add_entry("↑/↓", "navigate");
	h.add_entry("enter", "select");
	return h;
}