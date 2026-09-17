module xray::layout;
import xray;

// Constraint constructors — shorter names for the common cases. These are
// the same constraints the layout tree takes, so cells/fill/percent mean the
// same thing whether a rect or a Node is being sized.

fn xray::Constraint cells(int n)     => xray::cells(n);
fn xray::Constraint fill(int weight) => xray::fill(weight);
fn xray::Constraint percent(int p)   => xray::percent(p);
fn xray::Constraint min(int n)       => xray::at_least(n);
fn xray::Constraint max(int n)       => xray::at_most(n);

// screen returns a Rect covering the full terminal at (0,0).
fn xray::Rect screen(int w, int h) => xray::new_rect(0, 0, w, h);

// LayoutSlot pairs a constraint with an output rect pointer.
struct LayoutSlot {
	xray::Constraint constraint;
	xray::Rect*      out;
}

fn LayoutSlot slot(xray::Constraint c, xray::Rect* out) {
	return { .constraint = c, .out = out };
}

// LayoutOptions — ZII-safe: zero value means gap=0, no justify/align.
struct LayoutOptions {
	int gap;
}

// vstack solves constraints vertically and writes results into each slot.out.
fn void vstack(xray::Rect area, LayoutSlot[] slots, LayoutOptions opts = {}) {
	int n = (int)slots.len;
	if (n == 0) return;
	if (n > 64) n = 64;

	xray::Constraint[64] cs;
	xray::Rect[64]       rects;

	for (int i = 0; i < n; i++) cs[i] = slots[i].constraint;
	xray::layout_v_gap(area, cs[0:n], opts.gap, rects[0:n]);
	for (int i = 0; i < n; i++) {
		if (slots[i].out != null) *slots[i].out = rects[i];
	}
}

// hstack solves constraints horizontally and writes results into each slot.out.
fn void hstack(xray::Rect area, LayoutSlot[] slots, LayoutOptions opts = {}) {
	int n = (int)slots.len;
	if (n == 0) return;
	if (n > 64) n = 64;

	xray::Constraint[64] cs;
	xray::Rect[64]       rects;

	for (int i = 0; i < n; i++) cs[i] = slots[i].constraint;
	xray::layout_h_gap(area, cs[0:n], opts.gap, rects[0:n]);
	for (int i = 0; i < n; i++) {
		if (slots[i].out != null) *slots[i].out = rects[i];
	}
}
