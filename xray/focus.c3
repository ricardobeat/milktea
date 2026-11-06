module xray;

import std::collections::list;
import std::core::mem;

// Keyboard focus: which focusable node (see Node.focusable) has the keyboard,
// remembered by its id, plus Tab order and focus on click.
//
// The state is here and its logic is reached only through g_focus_runtime,
// which stays null until a node is made focusable or focus is set: a program
// that never uses focus never references this code, so it is not linked in.
// milktea calls the runtime from its loop when it is installed, and offers
// is_focused/focus/blur over the state.

// FocusTarget is a focusable node as it stood in the last solved tree: its
// id, which is what focus is remembered by, and its rect, for focus on click.
// The name is copied, not referenced: targets outlive the frame whose temp
// allocator held the node's id.
struct FocusTarget {
	Rect rect;
	char[64] name;
	char name_len;
	void* id_ptr;
}

fn String FocusTarget.id_str(&self) => (String)self.name[:self.name_len];

struct FocusState @private {
	void* ptr;
	char[64] buf;
	usz len;
	List{FocusTarget} targets;
	// A node that blocks the pointer (a modal) was on screen: focus stays in it.
	bool trapped;
}

FocusState g_focus @private;

alias FocusUpdateFn = fn void(Node* root);
alias FocusStepFn = fn bool(bool back);
alias FocusClickFn = fn void(sz col, sz row);
alias FocusFreeFn = fn void();

struct FocusRuntime {
	FocusUpdateFn update; // after a tree is solved, before it paints
	FocusStepFn step;     // Tab (back: Shift-Tab); false when nothing is focusable
	FocusClickFn click;   // a press at col, row, before the click hooks run
	FocusFreeFn free;     // when a program stops: no focus, no targets
}

FocusRuntime* g_focus_runtime;

FocusRuntime focus_runtime_impl @private = { &focus_update, &focus_step, &focus_click, &focus_free };

// use_focus installs the focus runtime; Node.focusable and setting focus do.
fn void use_focus() {
	g_focus_runtime = &focus_runtime_impl;
}

// ---- state ------------------------------------------------------------------

fn void focus_set(void* id) {
	use_focus();
	g_focus.ptr = id;
	g_focus.len = 0;
}

fn void focus_set_named(String id) {
	use_focus();
	usz n = id.len < g_focus.buf.len ? id.len : g_focus.buf.len;
	g_focus.buf[:n] = id[:n];
	g_focus.len = n;
	g_focus.ptr = null;
}

fn void focus_clear() {
	g_focus.ptr = null;
	g_focus.len = 0;
}

fn bool focus_is(void* id) => id != null && g_focus.ptr == id;
fn bool focus_is_named(String id) => id.len > 0 && (String)g_focus.buf[:g_focus.len] == id;
fn bool focus_any() => g_focus.ptr != null || g_focus.len > 0;

// focus_matches reports whether n is the focused node.
fn bool Node.has_keyboard_focus(&self) {
	if (!self.can_focus) return false;
	if (self.id_str.len > 0) return focus_is_named(self.id_str);
	return focus_is(self.id_ptr);
}

// ---- runtime ------------------------------------------------------------------

fn void focus_to(FocusTarget t) @private {
	if (t.name_len > 0) {
		focus_set_named(t.id_str());
	} else {
		focus_set(t.id_ptr);
	}
}

fn sz focused_index() @private {
	foreach (i, t : g_focus.targets) {
		if (t.name_len > 0 ? focus_is_named(t.id_str()) : focus_is(t.id_ptr)) return (sz)i;
	}
	return -1;
}

// collect appends every focusable node with an id, in paint order, which is
// Tab order. A node that blocks the pointer drops everything collected
// before it, since a modal covers those, and traps focus.
fn void collect(Node* n) @private {
	if (n == null || n.alpha_value == 0) return;
	if (n.blocks_pointer) {
		g_focus.targets.clear();
		g_focus.trapped = true;
	}
	if (n.can_focus && (n.id_str.len > 0 || n.id_ptr != null)) {
		FocusTarget t = { .rect = n.computed_rect, .id_ptr = n.id_ptr };
		usz len = n.id_str.len < t.name.len ? n.id_str.len : t.name.len;
		t.name[:len] = n.id_str[:len];
		t.name_len = (char)len;
		g_focus.targets.push(t);
	}
	for (sz i = 0; i < n.child_count; i++) collect(n.children[i]);
}

// focus_update brings focus in line with a newly solved tree: inside a
// modal, focus that is not on one of its nodes moves to the first; anywhere
// else, focus on a node that is gone is dropped.
fn void focus_update(Node* root) @private {
	if (!g_focus.targets.is_initialized()) g_focus.targets.init(mem);
	g_focus.targets.clear();
	g_focus.trapped = false;
	collect(root);
	if (!focus_any() && !g_focus.trapped) return;
	if (focused_index() >= 0) return;
	if (g_focus.trapped && g_focus.targets.len() > 0) {
		focus_to(g_focus.targets[0]);
	} else {
		focus_clear();
	}
}

fn bool focus_step(bool back) @private {
	sz n = (sz)g_focus.targets.len();
	if (n == 0) return false;
	sz i = focused_index();
	if (back) {
		i = i <= 0 ? n - 1 : i - 1;
	} else {
		i = i < 0 || i >= n - 1 ? 0 : i + 1;
	}
	focus_to(g_focus.targets[i]);
	return true;
}

fn void focus_click(sz col, sz row) @private {
	FocusTarget[] ts = g_focus.targets.array_view();
	for (sz i = (sz)ts.len - 1; i >= 0; i--) {
		if (ts[i].rect.contains(col, row)) {
			focus_to(ts[i]);
			return;
		}
	}
	if (!g_focus.trapped) focus_clear();
}

fn void focus_free() @private {
	focus_clear();
	if (g_focus.targets.is_initialized()) g_focus.targets.free();
	g_focus.trapped = false;
}
