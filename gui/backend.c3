// Bindings for gui/backend.m (sokol, drawing) and gui/platform_macos.m
// (fonts, window, clipboard). The structs mirror the C ones field for field.
module milktea_gui @link(env::DARWIN, "Metal.framework", "QuartzCore.framework", "Cocoa.framework",
	"CoreText.framework", "CoreGraphics.framework", "CoreFoundation.framework", "ImageIO.framework");

struct MtVertex {
	float x;
	float y;
	float u;
	float v;
	uint color; // RGBA8 in memory order, straight alpha
}

const int CMD_QUADS = 0;
const int CMD_DECOR = 1;
const int CMD_CLIP = 2;

struct MtCmd {
	int kind;
	int first_quad;
	int quad_count;
	int decor;
	int[4] clip; // CMD_CLIP: device pixels; w <= 0 is the whole target
}

struct MtDecor {
	float[4] rect;
	float[4] misc;
	float[4] c1;
	float[4] c2;
	float[4] bc;
	float[4] grad;
	float[4] grad2;
	float[4] sh;
	float[4] shc;
	float[4] inner;
	float[4] inc;
}

enum MtEventType : int {
	NONE,
	KEY_DOWN,
	KEY_UP,
	CHAR,
	MOUSE_DOWN,
	MOUSE_UP,
	MOUSE_MOVE,
	MOUSE_LEAVE,
	SCROLL,
	RESIZED,
	QUIT_REQUESTED,
	FOCUSED,
	UNFOCUSED,
}

struct MtEvent {
	MtEventType type;
	int key;
	uint ch;
	int repeat;
	uint mods;
	int button;
	float x;
	float y;
	float scroll_y;
	float scroll_x;
	CInt precise;
	CInt phase;
}

const uint MOD_SHIFT = 0x1;
const uint MOD_CTRL = 0x2;
const uint MOD_ALT = 0x4;
const uint MOD_SUPER = 0x8;

struct MtGlyphInfo {
	int w;
	int h;
	int off_x;
	int off_y;
	int advance;
}

alias MtVoidFn = fn void();
alias MtEventFn = fn void(MtEvent* e);

extern fn void mt_atlas_upload(char* pixels, int w, int h);
extern fn void mt_render(MtVertex* verts, int nquads, MtCmd* cmds, int ncmds, MtDecor* decors,
	int fb_w, int fb_h, float* clear);
extern fn void mt_present(float radius);
extern fn void mt_commit();
extern fn int mt_write_png(ZString path);
extern fn int mt_headless_begin();
extern fn void mt_headless_end();
extern fn void mt_run(ZString title, int width, int height, MtVoidFn init, MtVoidFn frame,
	MtEventFn event, MtVoidFn cleanup);
extern fn void mt_quit();
extern fn void mt_cancel_quit();
extern fn float mt_dpi_scale();
extern fn int mt_fb_width();
extern fn int mt_fb_height();

extern fn void* mt_font_open(ZString spec, float pixel_height, int smooth);
extern fn void mt_font_close(void* font);
extern fn int mt_font_ascent(void* font);
extern fn int mt_font_glyph(void* font, uint cp, MtGlyphInfo* info, char* buf, int cap);
extern fn float mt_screen_scale();
extern fn void mt_window_setup(int borderless, int transparent, int min_w, int min_h);
extern fn int mt_window_inline_titlebar(int row_height, int hide_buttons);
extern fn void mt_window_drag();
extern fn void mt_window_minimize();
extern fn void mt_window_zoom();
extern fn int mt_window_is_zoomed();
alias MtMenuPickFn = fn void(CInt id);
extern fn void mt_menu_begin(ZString app_name, MtMenuPickFn pick);
extern fn void mt_menu_add(ZString title);
extern fn void mt_menu_add_item(ZString label, uint key, CInt id);
extern fn void mt_menu_add_separator();
extern fn void mt_menu_end();
extern fn void mt_clipboard_write(char* text, usz len);
extern fn char* mt_clipboard_read();
extern fn void mt_free(void* p);
