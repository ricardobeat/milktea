module xray;

import std::io;

// ClickTarget is one node's mouse hooks plus its solved rect, extracted from
// a tree after solve() so the hooks can be fired against a later mouse event
// without keeping the tree itself alive — see collect_click_targets.
//
// id_str and id_ptr are what the node was tagged with via .id(...); one of
// them is meaningful per the way the node was built, and the framework
// forwards both to the callback.
struct ClickTarget {
	Rect rect;
	String id_str;
	void* id_ptr;
	ClickFn on_click;
	ClickFn on_click_outside;
	ClickFn on_hover_in;
	ClickFn on_hover_out;
}

// collect_click_targets walks a solved tree and appends one ClickTarget per
// node that set any mouse hook, in paint order (parent before children,
// earlier siblings before later ones) — the same order paint() uses, so the
// last entry for any overlapping rect is the topmost one.
//
// out is a caller-owned fixed buffer (Program keeps one across frames);
// *count is both the starting offset and, on return, the new total. Targets
// beyond `out.len` are silently dropped, matching the fixed-buffer-drops
// convention used elsewhere (timers, send queue, input ring).
fn void collect_click_targets(Node* n, ClickTarget[] out, int* count) {
	if (n == null || *count >= (int)out.len) return;
	if (n.on_click_fn != null || n.on_click_outside_fn != null
		|| n.on_hover_in_fn != null || n.on_hover_out_fn != null) {
		out[*count] = {
			.rect = n.computed_rect,
			.id_str = n.id_str,
			.id_ptr = n.id_ptr,
			.on_click = n.on_click_fn,
			.on_click_outside = n.on_click_outside_fn,
			.on_hover_in = n.on_hover_in_fn,
			.on_hover_out = n.on_hover_out_fn,
		};
		(*count)++;
	}
	for (int i = 0; i < n.child_count; i++) {
		collect_click_targets(n.children[i], out, count);
	}
}

// dispatch_click fires the hooks in `targets` for a press at (col, row):
// on_click for the topmost (last-collected) target whose rect contains the
// point, and on_click_outside for every target whose rect does not — run in
// that order so a click that both hits one target and falls outside others
// (the common case: click a button, dismiss everything behind it) reaches
// the click handler first.
//
// col and row passed to the callbacks are local to the hit target's rect
// (i.e. already offset by rect.x / rect.y) so a widget that cares where the
// press landed inside it can read the position as a 0-based cell within its
// own content area rather than subtracting its own origin by hand.
fn void dispatch_click(ClickTarget[] targets, int col, int row, bool dbg) {
	if (dbg) io::eprintfn("[dispatch] (%d,%d) against %d targets", col, row, targets.len);
	for (int i = (int)targets.len - 1; i >= 0; i--) {
		if (dbg) {
			Rect r = targets[i].rect;
			io::eprintfn("  [%d] rect x=%d y=%d w=%d h=%d hit=%s click=%s id=%s",
				i, r.x, r.y, r.w, r.h, r.contains(col, row), targets[i].on_click != null,
				targets[i].id_str.len > 0 ? targets[i].id_str : "(ptr)");
		}
		if (targets[i].on_click != null && targets[i].rect.contains(col, row)) {
			if (dbg) io::eprintfn("  -> firing on_click of [%d]", i);
			Rect r = targets[i].rect;
			targets[i].on_click(targets[i].id_ptr, targets[i].id_str, col - r.x, row - r.y);
			break;
		}
	}
	foreach (i, t : targets) {
		if (t.on_click_outside != null && !t.rect.contains(col, row)) {
			if (dbg) io::eprintfn("  -> firing on_click_OUTSIDE of [%d]", i);
			t.on_click_outside(t.id_ptr, t.id_str, col, row);
		}
	}
}

// dispatch_hover walks `targets` and fires on_hover_in for any target whose
// rect contains (col, row) but did NOT contain the previous pointer position,
// and on_hover_out for any whose rect did contain it but no longer does.
// Targets that contained the pointer on both frames, or neither, are left
// alone — hover is an edge event, not a per-frame broadcast.
//
// targets is the click-target list as of the most recent draw. last_targets
// and last_count are what was hovered on the previous pointer event (same
// list, but filtered to hover-out-able targets). prev_col, prev_row are the
// previous pointer position; first call should pass (-1, -1) so everything
// that contains the new position fires on_hover_in.
//
// col and row passed to the callbacks are local to the hit target's rect,
// matching dispatch_click.
fn void dispatch_hover(ClickTarget[] targets, int col, int row,
		ClickTarget[] prev, int prev_count, int prev_col, int prev_row, bool dbg) {
	if (col == prev_col && row == prev_row) return;
	foreach (i, t : targets) {
		if (t.on_hover_in == null && t.on_hover_out == null) continue;
		bool inside_now = t.rect.contains(col, row);
		bool inside_prev = t.rect.contains(prev_col, prev_row);
		if (inside_now && !inside_prev && t.on_hover_in != null) {
			if (dbg) io::eprintfn("  -> firing on_hover_in of [%d]", i);
			t.on_hover_in(t.id_ptr, t.id_str, col - t.rect.x, row - t.rect.y);
		} else if (!inside_now && inside_prev && t.on_hover_out != null) {
			if (dbg) io::eprintfn("  -> firing on_hover_out of [%d]", i);
			t.on_hover_out(t.id_ptr, t.id_str, col - t.rect.x, row - t.rect.y);
		}
	}
	(void)prev; (void)prev_count;
}

// collect_drag_regions walks a solved tree and appends the rect of every node
// that set window_drag, in the same paint order as collect_click_targets.
// Order does not matter here the way it does for clicks — a point either
// falls in some drag region or it does not — but keeping the two walks alike
// keeps them easy to read together.
//
// out is a caller-owned fixed buffer; *count is both the starting offset and,
// on return, the new total. Regions beyond out.len are dropped silently, same
// as click targets.
fn void collect_drag_regions(Node* n, Rect[] out, int* count) {
	if (n == null || *count >= (int)out.len) return;
	if (n.window_drag_area) {
		out[*count] = n.computed_rect;
		(*count)++;
	}
	for (int i = 0; i < n.child_count; i++) {
		collect_drag_regions(n.children[i], out, count);
	}
}
