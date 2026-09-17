// macos_window.c
//
// Window chrome for milktea's GUI builds on macOS.
//
// Plain C rather than Objective-C: the AppKit behaviour needed here is all
// reachable through the Objective-C runtime, which keeps an Objective-C
// compile step out of the build.
//
// The style this implements: a window with no title bar, but with the real
// window buttons. NSWindowStyleMaskFullSizeContentView lets the content view
// cover the whole frame, the title text is hidden, and the three standard
// buttons are moved out of the title bar and into the content view. Moving
// them matters: a title bar left in place sits above the content and takes
// every mouse event in its strip, so an app drawing its own top row there
// could never be clicked.
#ifdef __APPLE__

typedef void *Id;

typedef struct {
	double x, y, width, height;
} Rect4;

typedef struct {
	double x, y;
} Point2;

extern Id sel_registerName(const char *name);
extern Id objc_getClass(const char *name);

// The Objective-C runtime has one message-send entry point, and the caller
// decides the argument types, so each signature gets its own declaration of
// the same symbol.
//
// The struct-returning form is arm64-only: four doubles come back in
// registers there, while x86_64 returns a struct that size through a hidden
// pointer and would need objc_msgSend_stret instead. milktea's GUI builds
// target Apple Silicon.
extern Id objc_msg_send_id(Id, Id) __asm__("_objc_msgSend");
extern Id objc_msg_send_id_long(Id, Id, long) __asm__("_objc_msgSend");
extern long objc_msg_send_long(Id, Id) __asm__("_objc_msgSend");
extern void objc_msg_send_void(Id, Id) __asm__("_objc_msgSend");
extern void objc_msg_send_void_bool(Id, Id, signed char) __asm__("_objc_msgSend");
extern void objc_msg_send_void_long(Id, Id, long) __asm__("_objc_msgSend");
extern void objc_msg_send_void_id(Id, Id, Id) __asm__("_objc_msgSend");
extern void objc_msg_send_void_rect(Id, Id, Rect4) __asm__("_objc_msgSend");
extern Rect4 objc_msg_send_rect(Id, Id) __asm__("_objc_msgSend");
extern Point2 objc_msg_send_point(Id, Id) __asm__("_objc_msgSend");

static Id sel(const char *name) {
	return sel_registerName(name);
}

static Id send_id(Id target, const char *name) {
	return objc_msg_send_id(target, sel(name));
}

// The application's window. milktea runs one window per process, and taking
// it from NSApplication avoids reaching into GLFW for the Cocoa handle.
static Id main_window(void) {
	Id app = objc_getClass("NSApplication");
	if (app == 0) return 0;
	app = send_id(app, "sharedApplication");
	if (app == 0) return 0;
	Id win = send_id(app, "keyWindow");
	if (win != 0) return win;
	win = send_id(app, "mainWindow");
	if (win != 0) return win;
	Id windows = send_id(app, "windows");
	if (windows == 0) return 0;
	if (objc_msg_send_long(windows, sel("count")) < 1) return 0;
	return objc_msg_send_id_long(windows, sel("objectAtIndex:"), 0);
}

static Rect4 send_rect(Id target, const char *name) {
	return objc_msg_send_rect(target, sel(name));
}

// NSWindowStyleMaskFullSizeContentView, spelled out because the framework
// headers are not available to a plain C translation unit.
#define FULL_SIZE_CONTENT_VIEW 0x8000L

// NSWindowButton: close, miniaturise, zoom.
#define BUTTON_CLOSE 0
#define BUTTON_MINIATURIZE 1
#define BUTTON_ZOOM 2

// NSWindowTitleHidden.
#define TITLE_HIDDEN 1

// AppKit lays the buttons out 12pt in from the edge on a 20pt pitch. Those
// numbers are reused here; only the vertical placement differs, because the
// buttons are centred on one of the app's rows rather than on a title bar.
#define BUTTON_FIRST_X 12.0
#define BUTTON_PITCH 20.0
#define BUTTON_FALLBACK_SIZE 14.0

// These three add up to how far the buttons reach from the window's left
// edge. The caller needs that number before the window exists, to know how
// much of its first row to keep clear, so milktea_gui.c3 carries the same sum
// as CHROME_BUTTONS_RIGHT and replaces it with this function's return value
// once the real frames are known.

// milktea_macos_inline_titlebar drops the window's title bar while keeping
// its buttons, and centres the buttons on a row of the caller's grid.
// row_height is that row's height in points, so the buttons line up with
// whatever the app draws in its first row.
//
// Returns the width the buttons occupy from the window's left edge, in
// points, or 0 when the window could not be converted.
int milktea_macos_inline_titlebar(int row_height) {
	Id window = main_window();
	if (window == 0) return 0;

	Id content = send_id(window, "contentView");
	if (content == 0) return 0;
	Rect4 bounds = send_rect(content, "bounds");

	long mask = objc_msg_send_long(window, sel("styleMask"));
	objc_msg_send_void_long(window, sel("setStyleMask:"), mask | FULL_SIZE_CONTENT_VIEW);
	objc_msg_send_void_bool(window, sel("setTitlebarAppearsTransparent:"), 1);
	objc_msg_send_void_long(window, sel("setTitleVisibility:"), TITLE_HIDDEN);

	Id close = objc_msg_send_id_long(window, sel("standardWindowButton:"), BUTTON_CLOSE);
	Id mini = objc_msg_send_id_long(window, sel("standardWindowButton:"), BUTTON_MINIATURIZE);
	Id zoom = objc_msg_send_id_long(window, sel("standardWindowButton:"), BUTTON_ZOOM);
	if (close == 0 || mini == 0 || zoom == 0) return 0;

	Id titlebar = send_id(close, "superview");
	double row = row_height > 0 ? (double)row_height : BUTTON_FALLBACK_SIZE;
	// AppKit measures from the window's bottom edge, so a row at the top of
	// the grid is at bounds.height - row.
	double centre_y = bounds.height - row / 2.0;

	Id buttons[3] = { close, mini, zoom };
	double right_edge = 0;
	for (int i = 0; i < 3; i++) {
		Rect4 f = send_rect(buttons[i], "frame");
		double w = f.width > 0 ? f.width : BUTTON_FALLBACK_SIZE;
		double h = f.height > 0 ? f.height : BUTTON_FALLBACK_SIZE;
		Rect4 target = { BUTTON_FIRST_X + (double)i * BUTTON_PITCH, centre_y - h / 2.0, w, h };
		if (send_id(buttons[i], "superview") != content) {
			objc_msg_send_void(buttons[i], sel("removeFromSuperview"));
			objc_msg_send_void_id(content, sel("addSubview:"), buttons[i]);
		}
		objc_msg_send_void_rect(buttons[i], sel("setFrame:"), target);
		double edge = target.x + w;
		if (edge > right_edge) right_edge = edge;
	}

	// With the buttons gone the title bar has nothing left in it, and leaving
	// it in place would be a strip that eats mouse events.
	if (titlebar != 0) objc_msg_send_void(titlebar, sel("removeFromSuperview"));

	return (int)(right_edge + 0.5);
}

// milktea_macos_cursor_screen reports the pointer's position in screen
// coordinates, which is what a window drag needs: a pointer position measured
// against the window is worthless once the window starts following it, since
// moving the window changes that reading as much as moving the pointer does.
//
// NSEvent's mouseLocation is not tied to the event queue, so it answers with
// wherever the pointer is right now. Its origin is the bottom left of the
// primary screen and y grows upward, the opposite of a window's y, so the
// value is only meaningful as a delta against another reading -- which is all
// the drag uses it for.
//
// Returns 1 on success, 0 if the runtime did not answer.
int milktea_macos_cursor_screen(double *out_x, double *out_y) {
	Id cls = objc_getClass("NSEvent");
	if (cls == 0) return 0;
	Point2 p = objc_msg_send_point(cls, sel("mouseLocation"));
	*out_x = p.x;
	*out_y = p.y;
	return 1;
}

#endif
