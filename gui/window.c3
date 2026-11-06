// The window hooks milktea asks a backend for (see milktea/window.c3): the
// room the window buttons take in the top row, centring them on the app's
// bar, the platform menu bar, and minimise/zoom.
module milktea_gui;

import milktea;
import std::core::string;

// Points between the window buttons and whatever the app puts after them.
const sz CHROME_GAP @private = 8;

fn void install_hooks() @private {
	milktea::install_window_hooks({
		.chrome = &chrome,
		.set_chrome_height = &chrome_height,
		.set_native_menus = &native_menus,
		.minimize = &minimize_window,
		.zoom = &toggle_zoom,
	});
	// Every app gets the platform's application and Window menus, and with
	// them Quit on ⌘Q, before it adds menus of its own.
	native_menus({});
}

fn milktea::WindowChrome chrome() @private {
	if (g.headless || g.opts.chrome_rows <= 0) return {};
	$if env::DARWIN:
		// The native buttons sit at the left, AppKit's way.
		if (g.opts.hide_window_buttons || g.buttons_right <= 0) return {};
		return { .left = (sz)g.buttons_right + CHROME_GAP };
	$else
		// No native buttons in the app's row: it draws its own.
		return { .drawn = true };
	$endif
}

fn void chrome_height(sz height) @private {
	set_chrome_height((int)height);
}

fn void native_menus(milktea::NativeMenu[] menus) @private {
	if (g.headless) return;
	mt_menu_begin(g.opts.title.zstr_tcopy(), &menu_picked);
	foreach (m : menus) {
		mt_menu_add(m.title.trim().zstr_tcopy());
		foreach (it : m.items) {
			if (it.separator) {
				mt_menu_add_separator();
			} else {
				mt_menu_add_item(it.label.zstr_tcopy(), it.key, (CInt)it.id);
			}
		}
	}
	mt_menu_end();
}

// menu_picked runs from AppKit's event handling, outside any frame, so it
// goes through the send queue like any message from outside the loop.
fn void menu_picked(CInt id) @private {
	if (id == -1) {
		milktea::request_quit();
		return;
	}
	milktea::g_program.send({ .kind = milktea::MsgKind.MENU, .tag = (int)id });
}
