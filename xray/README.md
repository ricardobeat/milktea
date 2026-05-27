# xray Layout System

A fast, stack-based layout engine for terminal UIs with flex-like capabilities.

## Core Concepts

### Rect
The fundamental layout unit: a rectangle with position and dimensions.

```c3
struct Rect {
    int x, y, w, h;
}
```

Methods:
- `right()` — right edge x-coordinate
- `bottom()` — bottom edge y-coordinate
- `contains(px, py)` — hit testing
- `inset(left, top, right, bottom)` — shrink by padding

### Constraints
Define how elements size along a layout axis. Six kinds:

- **CLEN** — fixed size: `constraint_len(20)`
- **CMIN** — minimum size: `constraint_min(10)`
- **CMAX** — maximum size: `constraint_max(50)`
- **CPERCENT** — percentage: `constraint_percent(50)` (50% of available)
- **CFILL** — flexible fill: `constraint_fill(weight)` (splits remaining space by weight)
- **CFIT** — measure content: `constraint_fit(measure_fn, ctx)` (calls function to size)

## Simple Layout Functions

For single-axis layouts, use low-level functions:

```c3
// Horizontal layout
int layout_h(Rect area, Constraint[] cs, Rect[] out_rects);
int layout_h_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects);

// Vertical layout
int layout_v(Rect area, Constraint[] cs, Rect[] out_rects);
int layout_v_gap(Rect area, Constraint[] cs, int gap, Rect[] out_rects);
```

Returns the number of elements laid out. Rects are written to `out_rects`.

Example:
```c3
Rect area = { .x = 0, .y = 0, .w = 80, .h = 24 };
Constraint[3] cs = {
    constraint_len(10),
    constraint_fill(1),
    constraint_len(20)
};
Rect[3] out;
layout_h_gap(area, cs, 1, out);
// out[0]: 10 wide, out[1]: remaining, out[2]: 20 wide, with 1-cell gap between
```

## Flex Layout System

For complex nested layouts, use `FlexNode`. It's a tree-based system similar to flexbox.

### Create Nodes

Constructors set sensible defaults (ROW direction, FILL sizing):

```c3
FlexNode* root = flex_row();              // row container
FlexNode* col = flex_col();               // column container
FlexNode* fixed = flex_len(20);           // 20 cells fixed
FlexNode* flexible = flex_fill(1);        // fills remaining (weight=1)
FlexNode* percent = flex_percent(50);     // 50% of parent
FlexNode* sized_min = flex_min(10);       // minimum 10
FlexNode* sized_max = flex_max(80);       // maximum 80
```

Or create a generic node and configure:
```c3
FlexNode* node = flex_node()
    .with_direction(FlexDirection.COLUMN)
    .with_main_size(constraint_percent(75));
```

### Configure Nodes

Chain builder methods:

```c3
root
    .with_direction(FlexDirection.ROW)
    .with_gap(2)
    .with_padding(1, 2, 1, 2)              // top, right, bottom, left
    .with_justify(JustifyContent.JUSTIFY_CENTER)
    .with_align(AlignItems.ALIGN_CENTER);
```

- **direction**: `ROW` or `COLUMN` — main axis
- **gap**: cells between children
- **padding**: space inside container borders
- **justify**: align along main axis (start, center, end, space-between, space-around, space-evenly)
- **align**: align along cross axis (stretch, start, center, end)
- **main_size** / **cross_size**: constraints for this node itself

### Add Children

```c3
root
    .add(flex_len(20))           // 20 cells wide
    .add(flex_fill(1))           // flexible
    .add(flex_len(10));          // 10 cells wide
```

Max 32 children per node.

### Solve Layout

Once the tree is built, compute all positions:

```c3
Rect screen = { .x = 0, .y = 0, .w = 80, .h = 24 };
root.solve(screen);
```

This recursively computes `computed_rect` for every node.

### Access Results

```c3
Rect root_rect = root.rect();                    // this node's rect
Rect child0_rect = root.child_rect(0);           // first child's rect
int num_children = root.count();
```

## Example: Layout a TUI Window

```c3
// Header (fixed 3 rows), body (flexible), footer (fixed 2 rows)
FlexNode* window = flex_col()
    .with_padding(0, 0, 0, 0);

FlexNode* header = flex_len(3)
    .with_direction(FlexDirection.ROW)
    .with_gap(1);
header.add(flex_len(20)).add(flex_fill(1)).add(flex_len(15));

FlexNode* body = flex_fill(1);

FlexNode* footer = flex_len(2)
    .with_direction(FlexDirection.ROW)
    .with_gap(1);
footer.add(flex_fill(1)).add(flex_len(20));

window.add(header).add(body).add(footer);

// Solve
Rect screen = { .x = 0, .y = 0, .w = 80, .h = 24 };
window.solve(screen);

// Use computed rects to render
render_header(window.child_rect(0));
render_body(window.child_rect(1));
render_footer(window.child_rect(2));
```

## Notes

- Nodes are temp-allocated; they live as long as you keep the root reference.
- Max 64 elements per layout call (stack-based).
- FlexNode max 32 children.
- Rounding: integer division; remainder goes to the last flexible child.
