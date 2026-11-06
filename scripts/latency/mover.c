// mover <pid> <seconds> <hz>: sweeps the cursor along the top row of pid's
// window, posting real mouse-moved events through the HID event tap.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
	int pid = atoi(argv[1]);
	double secs = atof(argv[2]);
	double hz = atof(argv[3]);
	CGRect r = CGRectZero;
	for (int tries = 0; tries < 50 && CGRectIsEmpty(r); tries++) {
		CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
		for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
			CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
			int wpid = 0;
			CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &wpid);
			if (wpid != pid) continue;
			CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r);
		}
		CFRelease(list);
		if (CGRectIsEmpty(r)) usleep(100000);
	}
	if (CGRectIsEmpty(r)) { fprintf(stderr, "window not found\n"); return 1; }
	fprintf(stderr, "window %.0f,%.0f %.0fx%.0f\n", r.origin.x, r.origin.y, r.size.width, r.size.height);
	CGPoint saved = CGEventGetLocation(CGEventCreate(NULL));
	// Click once in the content to bring the window forward, away from the bar.
	CGPoint mid = { r.origin.x + r.size.width / 2, r.origin.y + r.size.height * 0.8 };
	CGEventPost(kCGHIDEventTap, CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, mid, kCGMouseButtonLeft));
	CGEventPost(kCGHIDEventTap, CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, mid, kCGMouseButtonLeft));
	usleep(300000);
	int steps = (int)(secs * hz);
	double y = r.origin.y + 8; // the menu bar row, where titles hover
	for (int i = 0; i < steps; i++) {
		double t = (double)(i % 200) / 200.0;
		double x = r.origin.x + 5 + (t < 0.5 ? t * 2 : (1 - t) * 2) * 230;
		CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(x, y), kCGMouseButtonLeft);
		CGEventPost(kCGHIDEventTap, e);
		CFRelease(e);
		usleep((useconds_t)(1e6 / hz));
	}
	CGWarpMouseCursorPosition(saved);
	return 0;
}
