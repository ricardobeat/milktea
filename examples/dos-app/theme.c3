module dos_app;

import glaze;
import std::collections::object;
import std::encoding::json;
import std::io;
import std::io::file;

// Themes are loaded from themes.json next to this source, so a color scheme
// can be changed or added without touching the program.
//
// Every color the app draws with comes from the active theme. A screen that
// reads a color directly would not follow a theme change, so nothing does.
const String THEMES_PATH = "examples/dos-app/themes.json";

const int MAX_THEMES = 8;

struct Theme {
	String name;
	glaze::Color desktop; // behind everything
	// Optional second color. When set, the content panel's background is a
	// vertical gradient from desktop to this; unset leaves it flat.
	glaze::Color desktop_to;
	glaze::Color bar;     // menu bar and status bar
	glaze::Color bar_text; // text on the bar — ink is too dark on a dark bar
	glaze::Color panel;   // dialog and content panel background
	glaze::Color text;    // body text
	glaze::Color dim;     // secondary text
	glaze::Color accent;  // titles, highlights, focused controls
	glaze::Color ink;     // text drawn on an accent or bar background
	glaze::Color shadow;  // drop shadows
}

struct ThemeSet {
	Theme[MAX_THEMES] themes;
	int count;
	int active;
}

fn Theme* ThemeSet.current(&self) => &self.themes[self.active];

// load reads themes.json. A theme set that fails to load falls back to one
// built-in scheme rather than leaving the app with no colors at all — the
// file is data, and a missing or malformed one should not stop the demo.
fn ThemeSet load_themes() {
	ThemeSet set;

	char[]? data = file::load(mem, THEMES_PATH);
	if (catch data) return default_themes();
	defer mem::free(((char[])data).ptr);

	Object*? root = json::tparse((String)data);
	if (catch root) return default_themes();

	Object*? list = root.get("themes");
	if (catch list) return default_themes();

	for (sz i = 0; i < list.get_len() && set.count < MAX_THEMES; i++) {
		Object* t = list.get_at(i);
		set.themes[set.count] = {
			.name    = theme_string(t, "name", "Untitled"),
			.desktop = theme_color(t, "desktop", "#0000aa"),
			.desktop_to = theme_color(t, "desktop_to", ""),
			.bar      = theme_color(t, "bar",      "#00aaaa"),
			.bar_text = theme_color(t, "bar_text", "#000000"),
			.panel   = theme_color(t, "panel",   "#000055"),
			.text    = theme_color(t, "text",    "#ffffff"),
			.dim     = theme_color(t, "dim",     "#aaaaaa"),
			.accent  = theme_color(t, "accent",  "#ffff55"),
			.ink     = theme_color(t, "ink",     "#000000"),
			.shadow  = theme_color(t, "shadow",  "#111111"),
		};
		set.count++;
	}

	if (set.count == 0) return default_themes();
	return set;
}

// The parsed Object is temp-allocated and its strings go with it, so each name
// is copied onto the heap to outlive the parse.
fn String theme_string(Object* t, String key, String fallback) @local {
	String? v = t.get_string(key);
	if (catch v) return fallback;
	return v.copy(mem);
}

// An empty fallback means the key is optional: absent leaves the color unset,
// which is how a theme says it has no gradient.
fn glaze::Color theme_color(Object* t, String key, String fallback) @local {
	String? v = t.get_string(key);
	if (catch v) return fallback.len > 0 ? glaze::color_hex(fallback) : glaze::color_none();
	return glaze::color_hex(v);
}

// default_themes is the fallback when themes.json cannot be read: the classic
// scheme, so the app still runs from a directory where the file is not found.
fn ThemeSet default_themes() @local {
	ThemeSet set;
	set.themes[0] = {
		.name    = "DOS Classic",
		.desktop = glaze::color_hex("#0000aa"),
		.bar      = glaze::color_hex("#00aaaa"),
		.bar_text = glaze::color_hex("#000000"),
		.panel   = glaze::color_hex("#000055"),
		.text    = glaze::color_hex("#ffffff"),
		.dim     = glaze::color_hex("#aaaaaa"),
		.accent  = glaze::color_hex("#ffff55"),
		.ink     = glaze::color_hex("#000000"),
		.shadow  = glaze::color_hex("#111111"),
	};
	set.count = 1;
	return set;
}
