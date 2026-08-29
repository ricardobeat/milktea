# Tree layout

Design notes for the tree layout API, written before it was built. It is built
now; where the two differ, the code is right. The differences worth knowing:

- `Content` gained `measure_width` alongside `measure`, because a leaf needs a
  natural size on both axes for `center()` to fit it.
- Sizing is stored per real axis (`size_w`, `size_h`), not per main/cross axis.
  A node is built before it is added to anything, so `.width(6)` cannot know
  whether it will land in a row or a column; the parent picks at solve time.
- A struct must name the interface it implements — `struct Foo (xray::Content)`
  — and c3c 0.8.3 does not accept an alias there, so the xray name is required
  even though milktea re-exports the type.
- `paint` takes a scratch buffer from its caller rather than owning one, and
  takes the current time, since xray has no clock.
- A drawn cursor (`DrawCursorFn`) moved into the library from the cursors
  example, and `ContentCursor` carries either that or a terminal cursor.
- `layout::vstack`/`hstack` were kept, not replaced. They are the sizing half
  of the string API, which is still supported.
- `Padding` was not added: the pad fields are already settable in a literal, so
  a wrapper struct would have added a name and no capability. `pad`, `pad_x`
  and `pad_y` cover the shorthand.

## What was wrong

Views are built by solving a layout into rects, rendering a string per rect,
then gluing the strings together:

```c3
xray::Rect title_r, body_r, status_r;
layout::vstack(layout::screen(w, h), {
	layout::slot(layout::len(1),  &title_r),
	layout::slot(layout::fill(1), &body_r),
	layout::slot(layout::len(1),  &status_r),
});

String doc = glaze::join_vertical(glaze::Position.LEFT,
	title_r.render(title_s, "Title"),
	body_r.render(body_s, content));
doc = glaze::join_vertical(glaze::Position.LEFT, doc, status_r.render(status_s, "Status"));
```

The solver computes coordinates and then `join_vertical` throws them away.
Pieces land in argument order, which is correct only because each string was
padded to exactly its rect's size. A gap between rects, a wrong join order, or
two rects overlapping all produce silently wrong output.

Consequences:

- Overlapping content is impossible, so a modal means bypassing layout
  entirely. `examples/wolf3d-server/wolf3d-server.c3:786` solves a rect with
  `FlexNode` and then copies cells by hand.
- `gap` has to become padding inside a box, since a gap between joined strings
  has nowhere to live.
- Nesting means a named rect variable per level.
  `examples/cursors/cursors.c3` has twelve `vstack`/`hstack` calls and two
  five-element rect arrays that exist only because `slot()` needs somewhere to
  write.

Meanwhile the pieces to fix it already exist. `examples/cursors/cursors.c3`
skips joining entirely: it keeps an `xray::ScreenBuffer` on the model and calls
`render_ansi_string(x, y, ...)` at solved coordinates. That is the target
model, written out longhand in one example.

## Duplication to resolve

The same idea is spelled several ways depending on which entry point you use.

Sizing a region: `Constraint` + `LayoutSlot` (flat, `gap` only) or `Constraint`
on `FlexNode.main_size`/`cross_size` (tree, plus justify/align/padding). Both
reach the same solver, `layout_axis_cross` in `xray/layout.c3:75`.

Positioning: `Rect` (solved) or `Layer.x/y/z` (set by hand).

Attaching content: `Rect.render(style, content)`, `Layer.content`, or
`milktea::Layout.write_line`.

Producing a frame: `glaze::join_vertical`, `Compositor.render` (cells,
z-ordered), or `ScreenBuffer.render_ansi_string` (cells, no z).

Two trees, each with half of what's needed: `FlexNode` computes positions but
holds no content; `Layer` holds content but computes no positions.

`milktea::Layout` (`milktea/layout.c3`) has zero callers. It is the only thing
that tracks cursor position while building a view, which is the one idea worth
keeping. Delete it as part of this work.

## Target API

An app imports `milktea` and `glaze`. Nothing else.

```c3
fn milktea::View Model.view(&self) @dynamic {
	milktea::Node* root = milktea::root()
		.add(milktea::vstack()
			.add(milktea::text(title_s,  "Title").height(1))
			.add(milktea::text(body_s,   content).fill(1))
			.add(milktea::text(status_s, "Status").height(1)));

	if (self.confirming_quit) {
		root.add(milktea::text(modal_s, "Really quit? (y/n)")
			.center()
			.shadow(milktea::shadow(1, 1, 128, 0)));
	}

	return milktea::draw(root);
}
```

`add` mutates and returns the same node, so the chained and statement forms are
the same call. Conditional content is a plain `if` that adds to a node — no
`when`, `toggle`, or `overlay_if` wrapper, and no reassigning the root.

`root()` is mandatory and is a zstack: a base layer with things optionally on
top. Making it always present means `draw` sees one shape and overlay
placement has a defined meaning.

### Containers

- `root()` — zstack, mandatory outermost node
- `vstack()` — children stacked vertically
- `hstack()` — children side by side
- `zstack()` — children share the parent's rect, later ones paint on top

### Sizing

`width()` and `height()` are both optional on every container. One sets the
main axis, the other the cross axis, depending on the container. A node with
neither fills.

In a `vstack`, `height()` divides among siblings and `width()` stops the node
stretching to full width, so `align` decides where it sits:

```c3
milktea::vstack()
	.align(milktea::CENTER)
	.add(milktea::text(box_s, "centered").width(30).height(5))
```

Both accept cells or a percentage, dispatched by a macro on the argument type:

```c3
.width(30)
.width(milktea::pct(50))
```

```c3
struct Pct { int v; }
fn Pct pct(int v) => { .v = v };
```

`fill(n)` stays a separate method, main-axis only. Open: whether `fill` should
also go through `width`/`height` as `.height(fill(1))`, dropping `.fill()`.
Also open: whether `percent` survives as its own constraint or `pct` replaces
it.

`center()` means fit to content and sit in the middle of the rect. Alias for
`place(milktea::CENTER)`.

### Content

`Content` is an interface in xray. One required method:

```c3
interface Content {
	fn String render(Rect r);
	fn Cursor cursor(Rect r) @optional;
}
```

Given a solved rect, return a string sized to it. xray never learns about
glaze — it consumes a string that already carries ANSI escapes and decodes them
with `render_ansi_string`, which uses `xray::Style`.

milktea implements it over glaze:

```c3
struct StyledText {
	glaze::Style style;
	String       text;
}

fn String StyledText.render(StyledText* self, xray::Rect r) @dynamic {
	return self.style.width(r.w).height(r.h).render(self.text);
}

fn xray::Node* text(glaze::Style st, String s);
```

That render call is what `xray::Rect.render` already does in
`milktea/render_bridge.c3:9`. It runs after solve, so a border is drawn at the
size the layout chose rather than the size of the text — which is what makes
`fill(1)` meaningful on a bordered box.

Named `text()`, not `content()`: `Content` is the interface and `Node.content`
is the field, so a third meaning would be confusing.

### Components

Every boba component already has `fn String X.view(&self)` and carries
`width`/`height` fields the app sets before calling. Implementing `Content` is
three lines:

```c3
fn String List.render(&self, xray::Rect r) @dynamic {
	self.width  = r.w;
	self.height = r.h;
	return self.view();
}
```

Then a component drops into a tree directly, and the app stops poking sizes in:

```c3
.add(&self.lst)
```

This removes lines like `self.lst.height = sidebar_r.h - 4` from
`examples/component-viewer/component-viewer.c3`.

### Cursor

Text input currently counts rows by hand.
`examples/textinputs/textinputs.c3:88` has `base_row = 3` and
`label_cols = { 10, 7, 10 }`; change the title's padding and the cursor moves to
the wrong place with nothing to catch it. `examples/inputbox/inputbox.c3`
sidesteps it by drawing a `█` into the string.

With the optional `cursor` method the layout supplies the position:

```c3
fn Cursor TextInput.cursor(&self, xray::Rect r) @dynamic {
	return { .x = r.x + self.cursor_col(), .y = r.y };
}
```

`draw` checks for the method the way `Program` checks `on_destroy`
(`milktea/milktea.c3:940`), and sets it on the `View`.

Only one node can own the terminal cursor. Components know whether they are
focused, so an unfocused one should report "not me" rather than relying on
last-one-wins.

taro already does this, using a global instead of an interface method.
`FocusedCursor` in `taro/js_view.c3:20` holds x, y, a color, and a
`suppress_native` flag. `reset_focused_cursor()` clears it before the walk
(`taro/js_model.c3:434`); the textarea renderer checks `ta.focused`
(`taro/js_view.c3:931`) and, if so, converts its component-local cursor into
screen space as `inner.x + prompt_w + ta.cursor_col`; after the walk
`taro/js_model.c3:482` reads it back and calls `set_cursor_shape`.

Same arithmetic — node rect plus component-local offset, resolved at paint
time. The global works because one program runs at a time, the same assumption
`g_program` makes. An interface method keeps the data flow visible instead,
which is why this doc specifies one.

### Modals and overlays

A modal is a child of `root()` with `center()`. Alpha and shadows work in the
tree — `render_shadow` and `render_inner_shadow` are `ScreenBuffer` methods
(`xray/layer.c3:76`), and the alpha blend in `milktea/milktea.c3:1600` needs no
`View` or `Overlay`. Those are just its current callers.

```c3
fn Node* Node.shadow(&self, xray::Shadow s);
fn Node* Node.alpha(&self, char a);
```

`paint` draws the shadow before the content so it lands underneath, matching
`milktea/milktea.c3:1595`.

`View.add_overlay` stays. It is the better fit for placement at exact
coordinates — the component-viewer toasts compute
`hard_x = center_x - hard_w - 2` and bob with a triangle wave
(`examples/component-viewer/component-viewer.c3:559`). A solver has nothing to
offer there. Overlays are for "exactly here"; the tree is for "wherever the
layout decides".

## Styles

Field names become the API so compound literals are usable:

```c3
milktea::text({ .fg = accent, .bold = true }, "Title").height(1)
```

Renames: `is_bold` to `bold`, `is_italic` to `italic`, `is_underline` to
`underline`, `border_style` to `border`, `target_w` to `width`, `target_h` to
`height`, `h_align` to `align_h`, `v_align` to `align_v`. `fg`, `bg`, and
`border_color` keep their names.

A field and a method cannot share a name, so builders become `with_bold()`,
`with_width()`, `with_border()`. Both forms then work and mean the same thing.

Add a `Padding` struct and a `padding()` that applies to all sides.

Borders keep the eight-string `Border` struct for custom shapes and gain a
`kind` field so presets can be named:

```c3
milktea::text({ .fg = accent, .border = glaze::ROUNDED }, "hi")
```

Presets are constants carrying only a kind, resolved to characters at render
time; a custom border fills in the strings.

## Re-exports

milktea aliases the xray types, constructors, and constants so apps need no
`import xray`:

```c3
alias Node   = xray::Node;
alias Rect   = xray::Rect;
alias Shadow = xray::Shadow;
```

Plus `root`, `vstack`, `hstack`, `zstack`, and the position and alignment
constants. Today `examples/pomodoro` and `examples/inputbox` import xray only
for `xray::layout` and `xray::Rect`, so this covers essentially every app.

## Renames in xray

`FlexNode` becomes `Node`. `Content` and a `content` field are added, along
with `paint` and a zstack direction.

## What draw does

1. Solve the tree against the screen rect.
2. Walk it, rendering each node's content into its rect and painting at its
   coordinates. Shadows before content. Later siblings over earlier ones.
3. Apply draw-cursor callbacks as a final pass.
4. Return a cell view.

Step 3 comes last because those callbacks take `under` — the character already
at that position — so `cursor_crosshair` and `cursor_matrix` can show it through
(`examples/cursors/cursors.c3:26`). That needs the finished grid, which is also
why `draw` returns a cell view rather than painting straight to the renderer.

taro runs its equivalent during the walk (`taro/js_view.c3:943`), which it can
because its `drawCursor` prop receives only x, y, and blink. A callback that
reads what is beneath it cannot work that way. Running the pass last handles
both kinds, so do that regardless of what a given callback needs.

## Inline mode

`draw()` solves against the full terminal and returns an alt-screen view.
`draw_inline()` sizes to content instead, for apps that share the screen with
the user's scrollback.

```c3
fn View draw(Node* root);          // full screen, alt_screen = true
fn View draw_inline(Node* root);   // sized to content, alt_screen = false
```

The difference is the rect the tree is solved against. Alt-screen uses
`screen_width() x screen_height()`. Inline uses the full width but measures the
height from the tree, so the solve needs a measuring pass first:

1. Measure the tree's natural height — each node's content height, plus gaps
   and padding, with `fill` nodes contributing their minimum rather than
   expanding.
2. Solve against `screen_width() x measured_height`.
3. Paint as usual, and return the view with `alt_screen = false`.

The runtime handles the rest. `milktea/milktea.c3:1511` picks RELATIVE for a
non-alt-screen view, and `milktea.c3:1518` sizes the inline block from
`view_content_rows`/`view_content_cols`, calling `resize_inline` when it
changes. The cell path at `milktea.c3:1535` already works for both modes, so a
cell view needs nothing new — only the correct `alt_screen` flag and
dimensions.

Two constraints inline mode imposes:

- The block is capped at the terminal height (`milktea.c3:1523`). A tree taller
  than the screen cannot be addressed relatively without scrolling, so it gets
  clipped.
- Rows below the block belong to the user. Nothing may paint outside the
  measured height, which means the "children do not clip to their parent" rule
  stops at the block's bottom edge — a shadow on the last row has nowhere to
  go.

`fill(n)` divides leftover space, and inline that rule is unchanged wherever
there is leftover space to divide. Only a container with no fixed size has
none: its height comes from its children, so a `fill` child takes the height
its content needs and the weight is ignored.

Give that container a `height()` and `fill` behaves exactly as it does
alt-screen, dividing the difference between the fixed height and what the other
children need:

```c3
milktea::vstack().height(10)
    .add(milktea::text(head_s, "Title").height(1))
    .add(milktea::text(body_s, content).fill(1))   // gets 9 rows
```

The same applies on the cross axis, which is always fixed inline because the
width is: `fill` stretches horizontally in a `vstack` as usual.

The buffer must be reused across frames, not allocated per frame.
`examples/cursors/cursors.c3` keeps one on the model and resizes it; `draw`
should hang one off the program, like `Renderer.overlay_scratch`
(`milktea/milktea.c3:1607`).

## Decided

`layout::vstack`/`hstack` become the tree API. `milktea::vstack`/`hstack` are
aliases. The rect-filling form is replaced, not kept alongside, so there is one
`vstack` and it builds nodes.

`layout::len` is renamed for consistency with `.width()`/`.height()`. 53 call
sites.

Children do not clip to their parent's rect. Shadows are the reason —
`render_shadow` writes at an offset, so a shadow on a container's right edge
falls outside it and must still paint.

Animated content reads the clock internally rather than taking a timestamp
parameter. `Content.render` keeps its `(Rect)` signature, and a style with
`border_animation` set calls `milktea::time_ms()` when it renders. Most
components ignore time, so putting it in every signature costs more than it
gives.

The renderer schedules its own repaint, copying taro: `taro/js_view.c3:943`
computes an interval and calls `request_render_tick(interval_ms)`. A node whose
content animates registers the interval it wants during paint, and `draw`
returns the smallest one so the program can re-tick. Apps do not tick manually
for self-animating content.

`fill(n)` stays its own method, main-axis only. `width()` and `height()` accept
cells or `pct(n)`; they do not accept `fill`. Three spellings for three
different ideas — a fixed size, a share of the parent, and a share of what is
left — is clearer than folding two of them into one call. `percent` as a
`Constraint` kind stays for the solver's internal use; `pct(n)` is the spelling
apps see.

`Content.render` stores the rect's width and height on `self` before calling
`view()`. It is impure, but it matches what components already do, and some
need their size outside of rendering — `Viewport` reads `self.height` in
`handle_key` to scroll by a page, before any render happens. Passing the size
to `view()` alone would not cover that.

## Not doing

Lambdas. C3 has them, but they do not capture, so anything needing state is
back to a function pointer plus a context pointer. `Content` on a struct is
cleaner and type-safe.
