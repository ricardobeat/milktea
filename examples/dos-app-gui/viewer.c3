module dos_app;

import milktea;
import glaze;
import xray;
import boba;

// OpenFile is a text file open in the main area, in place of the welcome
// tabs, in a boba::Viewport: a trackpad scrolls it by the pixel with
// momentum and springs back at the ends; a wheel and ↑↓ PgUp/PgDn Home/End
// scroll by rows. Esc closes it.
//
// There are no real files: Open... offers BANNER.TXT, whose lines are below.

struct OpenFile {
	bool open;
	String name;
	boba::Viewport vp;
}

fn void OpenFile.show(&self, String name, String[] lines) {
	if (self.vp.lines.is_initialized()) self.vp.free();
	self.vp = boba::new_viewport(60, 10);
	self.vp.set_lines(lines);
	self.vp.set_content(lines.len);
	self.name = name;
	self.open = true;
}

fn void OpenFile.close(&self) {
	self.open = false;
}

// handle_key scrolls the file; Esc closes it. Reports whether it took the key.
fn bool OpenFile.handle_key(&self, milktea::KeyMsg k) {
	if (k.code == milktea::KeyCode.ESC) {
		self.close();
		return true;
	}
	return self.vp.handle_key(k);
}

// node is the file's text, filling the area it is given; its colours are the
// panel's, so the text sits on the panel's background.
fn xray::Node* OpenFile.node(&self, Theme* th) {
	self.vp.content_style = { .fg = th.text };
	return self.vp.node().fill(1);
}

const String[*] BANNER_TXT = {
	"",
	"  ███╗   ███╗██╗██╗     ██╗  ██╗████████╗███████╗ █████╗",
	"  ████╗ ████║██║██║     ██║ ██╔╝╚══██╔══╝██╔════╝██╔══██╗",
	"  ██╔████╔██║██║██║     █████╔╝    ██║   █████╗  ███████║",
	"  ██║╚██╔╝██║██║██║     ██╔═██╗    ██║   ██╔══╝  ██╔══██║",
	"  ██║ ╚═╝ ██║██║███████╗██║  ██╗   ██║   ███████╗██║  ██║",
	"  ╚═╝     ╚═╝╚═╝╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝",
	"",
	"            a TUI framework for the C3 language",
	"",
	"                        (  )   (   )  )",
	"                         ) (   )  (  (",
	"                         ( )  (    ) )",
	"                    _____________________",
	"                   <_____________________> ___",
	"                   |                     |/ _ \\",
	"                   |      m i l k        | | | |",
	"                   |        t e a        | |_| |",
	"                ___|                     |\\___/",
	"               /    \\___________________/    \\",
	"               \\_____________________________/",
	"",
	"  ─────────────────────────────────────────────────────",
	"",
	"   THE RECIPE",
	"",
	"     1.  Brew one strong black tea, about five minutes.",
	"     2.  Cook the tapioca pearls until they float.",
	"     3.  Rinse the pearls and drop them in brown sugar.",
	"     4.  Pour the tea over ice in a tall glass.",
	"     5.  Add the milk, slowly, and watch it swirl.",
	"     6.  Spoon in the pearls. Find a wide straw.",
	"",
	"  ─────────────────────────────────────────────────────",
	"",
	"   THE ARCHITECTURE",
	"",
	"        ┌─────────┐     ┌──────────┐     ┌──────────┐",
	"        │  Model  │ ──▶ │   view   │ ──▶ │   tree   │",
	"        └─────────┘     └──────────┘     └──────────┘",
	"             ▲                                 │",
	"             │                                 ▼",
	"        ┌─────────┐                      ┌──────────┐",
	"        │ update  │ ◀──────  Msg  ────── │ terminal │",
	"        └─────────┘                      │ or window│",
	"                                         └──────────┘",
	"",
	"  ─────────────────────────────────────────────────────",
	"",
	"   A FEW STARS",
	"",
	"        .        *          .         .     *",
	"     *        .        .        *        .",
	"          .        ★        .        .        *",
	"     .         .        .         *      .",
	"        *   .        .       .         .        .",
	"            .     *       .       ★       .",
	"     .         .      .        .      *      .",
	"",
	"  ─────────────────────────────────────────────────────",
	"",
	"   You reached the end of BANNER.TXT.",
	"   Pull past it on a trackpad: it gives, and springs back.",
	"",
};
