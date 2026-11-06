module milktea;

// Window integration a GUI backend provides and a terminal does not: room
// for the platform's window controls in an app's own top bar, and the
// platform's own menu bar. A backend installs WindowHooks when it starts;
// with none installed (a terminal) every call here does nothing and reports
// nothing, so components such as boba::MenuBar can use them unconditionally.

// WindowChrome is the room the platform's window controls take in the top
// row of a window that has no title bar of its own, in layout units (pixels
// in a GUI). left is reserved at the start of the row (macOS), right at the
// end; both 0 when the window keeps its own title bar or there is no window.
// drawn is true when the platform draws no controls of its own there, and
// the app is expected to draw minimise/maximise/close itself.
struct WindowChrome {
	sz left;
	sz right;
	bool drawn;
}

// NativeMenuItem is one entry of a menu in the platform's menu bar. key is
// the shortcut's character (0 for none), which the platform shows with its
// own modifier (⌘ on macOS). A separator has no label.
struct NativeMenuItem {
	String label;
	uint key;
	int id;
	bool separator;
}

struct NativeMenu {
	String title;
	NativeMenuItem[] items;
}

alias WindowChromeFn = fn WindowChrome();
alias ChromeHeightFn = fn void(sz height);
alias NativeMenusFn = fn void(NativeMenu[] menus);
alias WindowActionFn = fn void();

struct WindowHooks {
	WindowChromeFn chrome;
	ChromeHeightFn set_chrome_height;
	NativeMenusFn set_native_menus;
	WindowActionFn minimize;
	WindowActionFn zoom;
}

WindowHooks g_window_hooks @private;

// install_window_hooks is for backends: the GUI calls it when it starts and
// again with {} when it stops.
fn void install_window_hooks(WindowHooks hooks) {
	g_window_hooks = hooks;
}

// window_chrome reports the room the window controls take in the top row.
fn WindowChrome window_chrome() {
	if (g_window_hooks.chrome == null) return {};
	return g_window_hooks.chrome();
}

// set_window_chrome_height tells the backend how tall the app's top bar is,
// so the platform's controls are centred on it.
fn void set_window_chrome_height(sz height) {
	if (g_window_hooks.set_chrome_height != null) g_window_hooks.set_chrome_height(height);
}

// has_native_menus reports whether set_native_menus puts menus in a
// platform menu bar, so an app can leave them out of its own view.
fn bool has_native_menus() => g_window_hooks.set_native_menus != null;

// set_native_menus puts these menus in the platform's menu bar, after the
// application menu the platform adds itself. Choosing an item sends a
// MsgKind.MENU message whose tag is the item's id. The menus are copied, so
// the arrays need not outlive the call.
fn void set_native_menus(NativeMenu[] menus) {
	if (g_window_hooks.set_native_menus != null) g_window_hooks.set_native_menus(menus);
}

fn void minimize_window() {
	if (g_window_hooks.minimize != null) g_window_hooks.minimize();
}

fn void zoom_window() {
	if (g_window_hooks.zoom != null) g_window_hooks.zoom();
}
