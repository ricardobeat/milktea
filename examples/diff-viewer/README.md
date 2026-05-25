# Diff Viewer Example

A terminal UI for viewing unified diff format (git-style diffs) with color-coded changes, line numbers, and smooth scrolling. Inspired by the "crush" tool's diff rendering.

## Features

- **Colored output**: Green for additions, red for deletions, cyan for file/hunk headers
- **Line numbering**: Shows line numbers alongside diff lines
- **Cursor navigation**: See which line you're on with highlighting
- **Keyboard navigation**: 
  - `j`/`k` or arrow keys: move up/down line by line
  - `Page Up`/`Page Down`: jump by screen height
  - `Home`/`End`: go to start/end of diff
  - `q` or `Ctrl+C`: quit

## How It Works

### Data Structure

```c3
struct DiffLine {
    enum Kind : uint8 {
        CONTEXT,      // unchanged lines (prefix: space)
        ADDITION,     // new lines (prefix: +, green)
        DELETION,     // removed lines (prefix: -, red)
        FILE_HEADER,  // "diff --git a/... b/..." (cyan)
        HUNK_HEADER,  // "@@ -10,5 +10,6 @@" (magenta)
    }
    Kind kind;
    String content;
    int line_num;
}
```

### Parsing

`parse_sample_diff()` scans a unified diff string line-by-line and categorizes each line based on its prefix:
- Lines starting with `diff --git` → `FILE_HEADER`
- Lines starting with `@@` → `HUNK_HEADER`
- Lines starting with `+` (not `+++`) → `ADDITION`
- Lines starting with `-` (not `---`) → `DELETION`
- Everything else → `CONTEXT`

In a real app, you'd read from `git diff` output or a file.

### Rendering

`format_diff_line()` applies glaze styling:
- Foreground color based on line kind
- Background color (cursor line) + bold if the cursor is on that line
- Consistent formatting with line numbers and prefix characters

`view()` assembles the viewport:
1. Header with instructions
2. Visible portion of lines (clipped to window height)
3. Footer with current position

### Scrolling

`adjust_scroll()` keeps the cursor visible:
- If cursor moves above the visible area, scroll up
- If cursor moves below the visible area, scroll down
- Always maintains the cursor within a comfortable viewing window

## Building

```bash
cd examples/diff-viewer
c3c run
```

## Customization Ideas

- **Load from file**: Replace `parse_sample_diff()` with file I/O using `std::io::file`
- **Pipe from git**: Use `std::os::Command` to execute `git diff` and parse its output
- **Syntax highlighting**: Extend `format_diff_line()` to recognize code tokens and color them
- **Multi-file diffs**: Track file boundaries and allow jumping between files
- **Diff statistics**: Show insertion/deletion counts per file and total
- **Search**: Add `/` keybinding to search within the diff
- **Stage/unstage hunks**: Integrate with git staging (like `git add -p`)

## Key Techniques Demonstrated

- **Enum variants**: `DiffLine.Kind` with semantic categorization
- **Deferred cleanup**: `defer` statements for safe resource cleanup
- **String manipulation**: `string.split()`, `starts_with()`, `format()`
- **Viewport scrolling**: Managing scroll offset and cursor visibility
- **Lipgloss styling**: Color codes, bold, background highlighting
- **Window resizing**: Responding to `WINDOW_SIZE` messages
- **Keyboard input**: Handling `KEY` messages with vim-like bindings
