// platform_macos.m
//
// The macOS pieces of milktea's GUI that are not drawing: glyphs from
// CoreText, the window's chrome and dragging, minimise and zoom, the
// clipboard. Bound from gui/platform.c3.
#ifdef __APPLE__

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

extern const void *mt_window(void);

static NSWindow *window(void) { return (__bridge NSWindow *)mt_window(); }

// ---- fonts ------------------------------------------------------------------

typedef struct {
	CTFontRef font;
	int ascent; // device pixels, truncated as raylib's loader did
	int smooth;
} MtFont;

typedef struct {
	int w, h;     // bitmap size; 0 for a glyph with nothing to draw
	int off_x;    // bitmap left, from the pen position
	int off_y;    // bitmap top, from the top of the line
	int advance;
} MtGlyphInfo;

static CTFontRef font_from(const char *spec, CGFloat size) {
	CTFontRef font = NULL;
	if (spec && spec[0]) {
		CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)spec, (CFIndex)strlen(spec), false);
		if (url) {
			CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(url);
			CFRelease(url);
			if (descs) {
				if (CFArrayGetCount(descs) > 0) {
					font = CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, 0), size, NULL);
				}
				CFRelease(descs);
			}
		}
		// Not a file: a font name ("Menlo", "SF Mono").
		if (!font && !strchr(spec, '/')) {
			CFStringRef name = CFStringCreateWithCString(NULL, spec, kCFStringEncodingUTF8);
			if (name) {
				font = CTFontCreateWithName(name, size, NULL);
				CFRelease(name);
			}
		}
	}
	return font;
}

// mt_font_open loads a font from a file path, or by name, sized the way
// raylib's loader sized one: its ascent-to-descent span is pixel_height
// pixels. With no usable spec it falls back to the system's monospace font.
void *mt_font_open(const char *spec, float pixel_height, int smooth) {
	if (pixel_height <= 0) return NULL;
	CTFontRef probe = font_from(spec, 1000.0);
	if (!probe) probe = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 1000.0, NULL);
	if (!probe) return NULL;
	CGFloat span = CTFontGetAscent(probe) + CTFontGetDescent(probe);
	CTFontDescriptorRef desc = CTFontCopyFontDescriptor(probe);
	CFRelease(probe);
	if (span <= 0 || !desc) {
		if (desc) CFRelease(desc);
		return NULL;
	}
	CTFontRef font = CTFontCreateWithFontDescriptor(desc, (CGFloat)pixel_height * 1000.0 / span, NULL);
	CFRelease(desc);
	if (!font) return NULL;
	MtFont *f = calloc(1, sizeof(MtFont));
	f->font = font;
	f->ascent = (int)CTFontGetAscent(font);
	f->smooth = smooth;
	return f;
}

void mt_font_close(void *handle) {
	MtFont *f = handle;
	if (!f) return;
	CFRelease(f->font);
	free(f);
}

int mt_font_ascent(void *handle) { return handle ? ((MtFont *)handle)->ascent : 0; }

// glyph_for finds cp in font, or in the font CoreText falls back to for it.
// The font comes back retained; null when nothing installed has the
// codepoint (Last Resort's placeholder boxes are not drawn).
static CTFontRef glyph_for(CTFontRef font, uint32_t cp, CGGlyph *out) {
	UniChar chars[2];
	CFIndex n = 1;
	if (cp > 0xFFFF) {
		uint32_t v = cp - 0x10000;
		chars[0] = (UniChar)(0xD800 + (v >> 10));
		chars[1] = (UniChar)(0xDC00 + (v & 0x3FF));
		n = 2;
	} else {
		chars[0] = (UniChar)cp;
	}
	CGGlyph gl[2] = {0, 0};
	if (CTFontGetGlyphsForCharacters(font, chars, gl, n) && gl[0] != 0) {
		*out = gl[0];
		CFRetain(font);
		return font;
	}
	CFStringRef s = CFStringCreateWithCharacters(NULL, chars, n);
	if (!s) return NULL;
	CTFontRef fb = CTFontCreateForString(font, s, CFRangeMake(0, n));
	CFRelease(s);
	if (!fb) return NULL;
	CFStringRef name = CTFontCopyPostScriptName(fb);
	bool last_resort = name && CFStringCompare(name, CFSTR("LastResort"), 0) == kCFCompareEqualTo;
	if (name) CFRelease(name);
	if (last_resort || !CTFontGetGlyphsForCharacters(fb, chars, gl, n) || gl[0] == 0) {
		CFRelease(fb);
		return NULL;
	}
	*out = gl[0];
	return fb;
}

// mt_font_glyph rasterises cp into buf as one byte of coverage per pixel,
// w x h, and describes where it goes. Returns 1 when info is filled in (a
// space has w == 0 and only an advance), 0 when no font has the codepoint,
// and -n when buf is smaller than the n bytes the glyph needs.
int mt_font_glyph(void *handle, uint32_t cp, MtGlyphInfo *info, uint8_t *buf, int cap) {
	MtFont *f = handle;
	if (!f) return 0;
	memset(info, 0, sizeof(*info));
	CGGlyph g;
	CTFontRef font = glyph_for(f->font, cp, &g);
	if (!font) return 0;
	CGSize adv;
	CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &g, &adv, 1);
	info->advance = (int)lround(adv.width);
	CGRect bb;
	CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &g, &bb, 1);
	if (bb.size.width <= 0 || bb.size.height <= 0) {
		CFRelease(font);
		return 1;
	}
	// One pixel of margin round the ink, so neighbours in the atlas never meet.
	int x0 = (int)floor(bb.origin.x) - 1;
	int y0 = (int)floor(bb.origin.y) - 1;
	int w = (int)ceil(bb.origin.x + bb.size.width) + 1 - x0;
	int h = (int)ceil(bb.origin.y + bb.size.height) + 1 - y0;
	if (w * h > cap) {
		CFRelease(font);
		return -(w * h);
	}
	memset(buf, 0, (size_t)(w * h));
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
	CGContextRef ctx = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8, (size_t)w, cs, (CGBitmapInfo)kCGImageAlphaNone);
	CGColorSpaceRelease(cs);
	if (!ctx) {
		CFRelease(font);
		return 0;
	}
	CGContextSetGrayFillColor(ctx, 1.0, 1.0);
	CGContextSetShouldAntialias(ctx, true);
	CGContextSetAllowsFontSmoothing(ctx, f->smooth != 0);
	CGContextSetShouldSmoothFonts(ctx, f->smooth != 0);
	CGContextSetAllowsFontSubpixelPositioning(ctx, false);
	CGContextSetShouldSubpixelPositionFonts(ctx, false);
	CGContextSetAllowsFontSubpixelQuantization(ctx, false);
	CGPoint pos = CGPointMake((CGFloat)-x0, (CGFloat)-y0);
	CTFontDrawGlyphs(font, &g, &pos, 1, ctx);
	CGContextRelease(ctx);
	CFRelease(font);
	info->w = w;
	info->h = h;
	info->off_x = x0;
	info->off_y = f->ascent - (y0 + h);
	return 1;
}

// mt_screen_scale is the main screen's backing scale, for a screenshot run
// that has no window to ask.
float mt_screen_scale(void) {
	NSScreen *s = [NSScreen mainScreen];
	return s ? (float)s.backingScaleFactor : 2.0f;
}

// ---- window -----------------------------------------------------------------

// mt_window_setup applies the style a GUI run asked for, once the window
// exists. borderless hides the title bar and its buttons while keeping a
// titled window, so it still takes key focus, resizes and keeps the system's
// rounded corners and shadow. transparent lets the corners the frame cuts
// show the desktop through them.
void mt_window_setup(int borderless, int transparent, int min_w, int min_h) {
	NSWindow *w = window();
	if (!w) return;
	if (borderless) {
		// Not titled at all: macOS rounds and clips every titled window, title
		// bar hidden or not, so only a borderless one has the corners the
		// frame draws. It still resizes from its edges, minimises and casts a
		// shadow; backend.m lets it become the key window.
		w.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
			| NSWindowStyleMaskMiniaturizable;
		w.hasShadow = YES;
	}
	if (transparent) {
		w.opaque = NO;
		w.backgroundColor = [NSColor clearColor];
		w.contentView.wantsLayer = YES;
		w.contentView.layer.opaque = NO;
	}
	if (min_w > 0 && min_h > 0) w.contentMinSize = NSMakeSize(min_w, min_h);
}

// mt_window_inline_titlebar takes the title bar away but keeps the window
// buttons, moved into the content view and centred on a row_height strip at
// the top. Returns how far the buttons reach from the window's left edge in
// points (0 when they are hidden), or -1 with no window.
int mt_window_inline_titlebar(int row_height, int hide_buttons) {
	NSWindow *w = window();
	if (!w) return -1;
	w.styleMask |= NSWindowStyleMaskFullSizeContentView;
	w.titlebarAppearsTransparent = YES;
	w.titleVisibility = NSWindowTitleHidden;
	// sokol's view hosts its Metal layer itself, and AppKit does not lay out
	// subviews inside a layer-hosting view properly: they draw flipped and
	// away from where they take clicks. So the buttons go in a plain
	// container that holds the sokol view and sits above it.
	NSView *content = w.contentView;
	if (content.layer != nil && !content.isFlipped && content.subviews.count == 0
			&& ![content.identifier isEqualToString:@"milktea.chrome"]) {
		NSView *box = [[NSView alloc] initWithFrame:content.frame];
		box.identifier = @"milktea.chrome";
		box.autoresizesSubviews = YES;
		box.wantsLayer = YES;
		[content retain];
		w.contentView = box;
		content.frame = box.bounds;
		content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[box addSubview:content];
		[content release];
		[box release];
		[w makeFirstResponder:content];
		content = box;
	}
	// The window's own buttons stay where AppKit keeps them, hidden: AppKit
	// lays them out again with its title bar's geometry whenever it likes,
	// over anything done to them here. Standalone copies of the same native
	// buttons, which act on whatever window they are in, take their place.
	static NSButton *own[3];
	CGFloat x = 12, right = 0;
	for (NSWindowButton b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) {
		NSButton *std = [w standardWindowButton:b];
		if (std) [std setHidden:YES];
		if (hide_buttons) {
			if (own[b]) [own[b] setHidden:YES];
			continue;
		}
		if (own[b] == nil) {
			own[b] = [[NSWindow standardWindowButton:b forStyleMask:w.styleMask] retain];
			if (own[b] == nil) continue;
			[content addSubview:own[b]];
		} else if (own[b].superview != content) {
			[own[b] removeFromSuperview];
			[content addSubview:own[b]];
		}
		[own[b] setHidden:NO];
		NSRect f = own[b].frame;
		// Centred on the top strip, held there as the window resizes.
		CGFloat inset = (row_height - f.size.height) / 2.0;
		own[b].frame = NSMakeRect(x, content.bounds.size.height - inset - f.size.height, f.size.width, f.size.height);
		own[b].autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
		x += f.size.width + 6;
		right = x - 6;
	}
	return (int)ceil(right);
}

// mt_window_drag hands the press now being handled to AppKit to move the
// window by. It returns once the button is up; a press that does not move
// leaves the window where it was.
void mt_window_drag(void) {
	NSWindow *w = window();
	NSEvent *e = [NSApp currentEvent];
	if (w && e && e.type == NSEventTypeLeftMouseDown) [w performWindowDragWithEvent:e];
}

void mt_window_minimize(void) { [window() miniaturize:nil]; }
void mt_window_zoom(void) { [window() zoom:nil]; }
int mt_window_is_zoomed(void) { return window().isZoomed ? 1 : 0; }

void mt_window_set_title(const char *title) {
	NSWindow *w = window();
	if (w && title) w.title = [NSString stringWithUTF8String:title];
}

// ---- clipboard --------------------------------------------------------------

void mt_clipboard_write(const char *text, size_t len) {
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	NSString *s = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
	if (!s) return;
	[pb clearContents];
	[pb setString:s forType:NSPasteboardTypeString];
	[s release];
}

// mt_clipboard_read returns the clipboard's text as malloc'd UTF-8 (the
// caller frees it with mt_free), or null when it holds none.
char *mt_clipboard_read(void) {
	NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
	if (!s) return NULL;
	const char *u = s.UTF8String;
	return u ? strdup(u) : NULL;
}

void mt_free(void *p) { free(p); }

#endif
