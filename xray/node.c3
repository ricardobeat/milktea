module xray;

import std::core::mem;

// Content is anything that can fill a solved rect with text.
//
// render is called after layout, so the rect it receives is the size the
// solver chose. Implementations return a string sized to that rect; it may
// carry ANSI escapes, which paint decodes with render_ansi_string. xray does
// not know how those escapes are produced — milktea builds them with glaze.
//
// measure reports how tall the content wants to be at a given width, and
// measure_width how wide it wants to be at a given height. Both are consulted
// only when nothing else fixes that axis — CFIT sizing, which is what place()
// and center() produce, and draw_inline. Content that is happy to fill can
// leave either unimplemented; an unimplemented axis measures 0, which for a
// leaf under center() means it collapses on that axis, so implement the ones
// that matter.
//
// cursor reports where the terminal cursor belongs, in screen coordinates,
// given the node's solved rect. Content that does not own a cursor leaves it
// unimplemented. Content that owns one only when focused should return
// has_cursor = false when it is not, rather than relying on paint order.
interface Content {
	fn String render(Rect r);
	fn int measure(int width) @optional;
	fn int measure_width(int height) @optional;
	fn ContentCursor cursor(Rect r) @optional;
}

// DrawCursorFn paints the cursor itself instead of leaving it to the
// terminal. It is called after everything else is on screen, so `under` is
// the character already at that cell — a crosshair or a matrix rain effect
// can show it through rather than hiding it. Returning an empty string
// leaves the cell as it was.
//
// blink alternates on the interval the cursor asked for; a callback that
// animates on its own clock can ignore it.
alias DrawCursorFn = fn String(int x, int y, bool blink, String under);

// place_cursor puts a caret at a column and row inside a content area, which
// is a node's rect less whatever frame its content draws around itself.
//
// col and row are relative to the text, so content passes its own caret
// position and the layout supplies the origin. A caret scrolled out of view
// reports no cursor rather than one clamped to the edge, which would sit on a
// line it is not on.
fn ContentCursor place_cursor(Rect text, int col, int row, CursorStyle cs = {}) {
	if (col < 0 || row < 0 || row >= text.h || col >= text.w) return {};
	return {
		.x = text.x + col,
		.y = text.y + row,
		.has_cursor = true,
		.draw = cs.draw,
		.blink_ms = cs.blink_ms,
		.shape = cs.shape,
		.blink = cs.blink,
		.color = cs.color,
	};
}

// CursorStyle is how a caret looks. Leaving draw null gives the terminal's own
// cursor with the given shape, blink and color; setting it paints the cursor
// into the grid instead, and the terminal cursor stays hidden.
//
// shape is an index into whatever shapes the host defines
// (milktea::CursorShape); xray does not name them.
struct CursorStyle {
	int shape;
	bool blink;
	String color;
	DrawCursorFn draw;
	int blink_ms;
}

// ContentCursor is what Content.cursor returns. x and y are absolute screen
// coordinates. has_cursor = false means "not mine this frame".
//
// Leaving draw null gives the real terminal cursor at that position, with
// the given shape and blink. Setting it paints the cursor into the grid
// instead, and the terminal cursor stays hidden.
struct ContentCursor {
	int x;
	int y;
	bool has_cursor;
	DrawCursorFn draw;
	// Milliseconds per blink phase for a drawn cursor. 0 uses the default.
	int blink_ms;
	// Terminal cursor appearance, used only when draw is null. shape is an
	// index into whatever shapes the host defines (milktea::CursorShape);
	// color is a hex string such as "#ff6600", empty for the default.
	int shape;
	bool blink;
	String color;
}

// JustifyContent positions children along a container's main axis;
// AlignItems sizes and positions them across it.
enum JustifyContent : char {
	JUSTIFY_START,
	JUSTIFY_CENTER,
	JUSTIFY_END,
	JUSTIFY_SPACE_BETWEEN,
	JUSTIFY_SPACE_AROUND,
	JUSTIFY_SPACE_EVENLY
}

enum AlignItems : char {
	ALIGN_STRETCH,
	ALIGN_START,
	ALIGN_CENTER,
	ALIGN_END
}

// Direction of a container's main axis. STACK has no main axis: every child
// is solved against the parent's whole rect, and later children paint over
// earlier ones.
enum NodeDirection : char {
	ROW,
	COLUMN,
	STACK,
}

const int MAX_NODE_CHILDREN = 32;

// Node is one box in a layout tree. It is either a container (children, a
// direction) or a leaf (content), never usefully both — a node with content
// and children paints its content first and its children on top.
//
// Nodes are temp-allocated: a tree lives for one frame and is rebuilt by the
// next view() call. Do not store a Node* across frames.
struct Node {
	// Sizing is stored per real axis, not per main/cross axis, because a node
	// is built before it is added to anything: .width(6) cannot know whether
	// it will end up in a row or a column. The parent picks which of the two
	// is its main axis at solve time.
	Constraint size_w;
	Constraint size_h;

	Node*[MAX_NODE_CHILDREN] children;
	int child_count;

	NodeDirection direction;
	JustifyContent justify;
	AlignItems align;
	int gap;

	int pad_top, pad_right, pad_bottom, pad_left;

	Content content;

	// Effects applied when this node paints. shadow lands under the content,
	// inner_shadow over it, and alpha blends the content's colors into
	// whatever is already on screen.
	LayerStyle layer_style;
	char alpha_value;

	// Fixed offset inside the parent, used only when pinned (see at()).
	int offset_x, offset_y;
	bool pinned;

	// Milliseconds until this node wants to be painted again, or 0 for
	// "never on my account". paint collects the smallest non-zero value in
	// the tree so the runtime can schedule one repaint for all of them.
	int repaint_ms;

	Rect computed_rect;
}

fn Node* new_node(NodeDirection dir) @local {
	Node* n = mem::tnew(Node);
	n.size_w = fill(1);
	n.size_h = fill(1);
	n.direction = dir;
	n.justify = JustifyContent.JUSTIFY_START;
	n.align = AlignItems.ALIGN_STRETCH;
	return n;
}

// vstack stacks its children top to bottom.
fn Node* vstack() => new_node(NodeDirection.COLUMN);

// hstack places its children left to right.
fn Node* hstack() => new_node(NodeDirection.ROW);

// zstack gives every child the parent's whole rect. Later children paint over
// earlier ones.
fn Node* zstack() => new_node(NodeDirection.STACK);

// root is the mandatory outermost node: a zstack covering the screen. Having
// it always present means draw sees one shape, and a child added to it — a
// modal, a toast — has a defined place to land without the base layout
// knowing about it.
fn Node* root() => new_node(NodeDirection.STACK);

// node wraps content as a leaf. Callers normally reach this through a
// higher-level constructor such as milktea::text.
fn Node* content_node(Content c) {
	Node* n = new_node(NodeDirection.COLUMN);
	n.content = c;
	return n;
}

// add appends a child and returns this node, so the chained and statement
// forms are the same call.
//
// A null child is ignored, which lets content that is sometimes hidden return
// null from its node() and be added unconditionally.
fn Node* Node.add(&self, Node* child) {
	if (child != null && self.child_count < MAX_NODE_CHILDREN) {
		self.children[self.child_count++] = child;
	}
	return self;
}

// add_content is add() for anything implementing Content, so a component can
// go straight into a tree: parent.add_content(&self.list).
fn Node* Node.add_content(&self, Content c) {
	return self.add(content_node(c));
}

// Sizing. width and height both set a real axis rather than a main/cross one,
// so a caller does not have to remember which is which for the container it
// is in. In a column, height is the main axis and width the cross axis; in a
// row it is the other way around.
fn Node* Node.width(&self, Constraint c) {
	self.size_w = c;
	return self;
}

fn Node* Node.height(&self, Constraint c) {
	self.size_h = c;
	return self;
}

// fill gives this node a share of whatever space is left over on its parent's
// main axis, weighted against its siblings. Which axis that is depends on the
// parent, so it sets both and the parent uses the one it lays out along.
fn Node* Node.fill(&self, int weight) {
	self.size_w = fill(weight);
	self.size_h = fill(weight);
	return self;
}

fn Node* Node.with_justify(&self, JustifyContent j) {
	self.justify = j;
	return self;
}

fn Node* Node.with_align(&self, AlignItems a) {
	self.align = a;
	return self;
}

fn Node* Node.with_gap(&self, int g) {
	self.gap = g;
	return self;
}

fn Node* Node.with_padding(&self, int top, int right, int bottom, int left) {
	self.pad_top = top;
	self.pad_right = right;
	self.pad_bottom = bottom;
	self.pad_left = left;
	return self;
}

// place centres or aligns this node inside its parent's rect on both axes at
// once, and sizes it to its content. It is meant for a child of a zstack —
// a modal over the base layout — where the parent's rect is the whole screen
// and the child should occupy only as much of it as it needs.
fn Node* Node.place(&self, JustifyContent j, AlignItems a) {
	self.justify = j;
	self.align = a;
	// Fit only the axes the caller has not already sized, so .width(30) before
	// .center() survives and only the height is measured. An axis still set to
	// the default fill has nothing to preserve.
	if (self.size_w.kind == ConstraintKind.CFILL) self.size_w = fit(&node_measure_w, self);
	if (self.size_h.kind == ConstraintKind.CFILL) self.size_h = fit(&node_measure_h, self);
	return self;
}

// at pins this node to a fixed offset inside its parent, sized to its content
// unless a width or height was given. It is for content whose position is
// known rather than solved — a dropdown under the menu title that opened it,
// a tooltip beside its anchor.
//
// Only meaningful in a stack, where every child gets the parent's whole rect
// to place itself in; a row or column decides its children's offsets itself.
fn Node* Node.at(&self, int x, int y) {
	self.offset_x = x;
	self.offset_y = y;
	self.pinned = true;
	if (self.size_w.kind == ConstraintKind.CFILL) self.size_w = fit(&node_measure_w, self);
	if (self.size_h.kind == ConstraintKind.CFILL) self.size_h = fit(&node_measure_h, self);
	return self;
}

// center places this node in the middle of its parent, sized to its content.
fn Node* Node.center(&self) {
	return self.place(JustifyContent.JUSTIFY_CENTER, AlignItems.ALIGN_CENTER);
}

fn Node* Node.shadow(&self, Shadow s) {
	self.layer_style.shadow = s;
	self.layer_style.shadow.enabled = true;
	return self;
}

fn Node* Node.with_inner_shadow(&self, InnerShadow s) {
	self.layer_style.inner_shadow = s;
	self.layer_style.inner_shadow.enabled = true;
	return self;
}

// alpha blends this node's colors over what is already painted beneath it.
// 0 is opaque; 1-254 blend; the underlying characters always show through
// where this node paints a blank.
fn Node* Node.alpha(&self, char a) {
	self.alpha_value = a;
	return self;
}

// repaint_after asks the runtime to paint this tree again in ms milliseconds.
// Content that animates on its own — a border cycling colors — calls this so
// the app does not have to run a timer for it.
fn Node* Node.repaint_after(&self, int ms) {
	self.repaint_ms = ms;
	return self;
}

fn Rect Node.rect(&self) => self.computed_rect;

fn Rect Node.child_rect(&self, int idx) {
	if (idx < 0 || idx >= self.child_count) return {};
	return self.children[idx].computed_rect;
}

fn int Node.count(&self) => self.child_count;
