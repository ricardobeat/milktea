module xray;

// ClickTarget is one node's mouse hooks plus its solved rect, extracted from
// a tree after solve() so the hooks can be fired against a later mouse event
// without keeping the tree itself alive — see collect_click_targets.
struct ClickTarget {
	Rect rect;
	ClickFn on_click;
	void* on_click_ctx;
	ClickFn on_click_outside;
	void* on_click_outside_ctx;
}

// collect_click_targets walks a solved tree and appends one ClickTarget per
// node that set on_click or on_click_outside, in paint order (parent before
// children, earlier siblings before later ones) — the same order paint()
// uses, so the last entry for any overlapping rect is the topmost one.
//
// out is a caller-owned fixed buffer (Program keeps one across frames);
// *count is both the starting offset and, on return, the new total. Targets
// beyond `out.len` are silently dropped, matching the fixed-buffer-drops
// convention used elsewhere (timers, send queue, input ring).
fn void collect_click_targets(Node* n, ClickTarget[] out, int* count) {
	if (n == null || *count >= (int)out.len) return;
	if (n.on_click_fn != null || n.on_click_outside_fn != null) {
		out[*count] = {
			.rect = n.computed_rect,
			.on_click = n.on_click_fn,
			.on_click_ctx = n.on_click_ctx,
			.on_click_outside = n.on_click_outside_fn,
			.on_click_outside_ctx = n.on_click_outside_ctx,
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
fn void dispatch_click(ClickTarget[] targets, int col, int row) {
	for (int i = (int)targets.len - 1; i >= 0; i--) {
		if (targets[i].on_click != null && targets[i].rect.contains(col, row)) {
			targets[i].on_click(targets[i].on_click_ctx, col, row);
			break;
		}
	}
	foreach (t : targets) {
		if (t.on_click_outside != null && !t.rect.contains(col, row)) {
			t.on_click_outside(t.on_click_outside_ctx, col, row);
		}
	}
}
