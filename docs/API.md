# taro API Reference

The taro runtime embeds a QuickJS-based JavaScript engine inside a milktea C3 application. Scripts have access to built-in modules and globals for file I/O, networking, timers, console output, and TUI component bridges.

All APIs are synchronous unless noted otherwise.

---

## ES Modules

Importable with `import { ... } from "module"`.

### `"fs"` — File I/O

Bun-compatible file system API.

```js
import { file, write, exists, mkdir, readdir, unlink, stat } from "fs";
```

#### `file(path) → FileHandle`

Returns a lazy file handle. No I/O happens until a method is called.

```js
const f = file("data/config.json");
```

#### FileHandle properties

| Property | Type | Description |
|----------|------|-------------|
| `.path` | `string` | The original path |
| `.name` | `string` | Filename portion (after last `/`) |
| `.size` | `number` | File size in bytes, `-1` if not found |
| `.type` | `string` | MIME type guessed from extension |

Supported MIME types: `.txt`, `.json`, `.js`, `.ts`, `.html`, `.css`, `.xml`, `.csv`, `.md`, `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.svg`, `.pdf`, `.zip`, `.gz`, `.wasm`, `.bin`. Unknown extensions return `"application/octet-stream"`.

#### FileHandle methods

| Method | Returns | Description |
|--------|---------|-------------|
| `.exists()` | `boolean` | Whether the path exists |
| `.isFile()` | `boolean` | Whether the path is a regular file |
| `.isDir()` | `boolean` | Whether the path is a directory |
| `.text()` | `string \| null` | Read entire file as UTF-8 text |
| `.json()` | `object \| null` | Read and parse as JSON |
| `.bytes()` | `ArrayBuffer \| null` | Read entire file as bytes |

```js
const f = file("README.md");
if (f.exists()) {
  console.log(f.name, f.size, "bytes");
  const content = f.text();
}

const config = file("config.json").json();
const data = file("image.png").bytes();
```

#### `write(dest, data) → boolean`

Writes data to a file. Creates the file if it does not exist, overwrites if it does.

- If `data` is a `string` — writes UTF-8 text
- If `data` is a `Uint8Array` or `ArrayBuffer` — writes raw bytes
- If `data` is a `FileHandle` (has `.path`) — copies the source file

```js
write("out.txt", "Hello, world!");
write("out.bin", new Uint8Array([0x48, 0x69]));
write("copy.txt", file("original.txt"));  // copy
```

#### `exists(path) → boolean`

```js
if (exists("config.json")) { /* ... */ }
```

#### `mkdir(path, opts?) → boolean`

Creates a directory. Pass `{ recursive: true }` to create parent directories.

```js
mkdir("output");
mkdir("a/b/c", { recursive: true });
```

#### `readdir(path) → string[] | null`

Lists directory entries, excluding `.` and `..`. Returns `null` if the path is not a directory.

```js
const entries = readdir("src");
// ["main.js", "utils.js", "lib"]
```

#### `unlink(path) → boolean`

Deletes a file.

```js
unlink("temp.txt");
```

#### `stat(path) → object | null`

Returns file metadata or `null` if not found.

```js
const info = stat("data.bin");
// { size: 1024, isFile: true, isDir: false, mtimeMs: 1700000000000 }
```

| Field | Type | Description |
|-------|------|-------------|
| `size` | `number` | File size in bytes |
| `isFile` | `boolean` | Regular file |
| `isDir` | `boolean` | Directory |
| `mtimeMs` | `number` | Last modification time (ms since epoch) |

---

### `"os"` — Operating System

```js
import { getenv } from "os";
```

| Export | Signature | Description |
|--------|-----------|-------------|
| `getenv` | `getenv(name) → string \| null` | Read an environment variable |

```js
const home = getenv("HOME");
const path = getenv("PATH");
```

---

### `"milktea"` — milktea Framework

Re-exports the `tea` global and `h` helper for use in ES modules.

```js
import { milktea, h } from "milktea";
```

See [Global Objects](#global-objects) below for the full `tea` and `h` API.

---

## Global Objects

Available in all scripts without imports.

### `console`

| Method | Description |
|--------|-------------|
| `console.log(...args)` | Print to stderr (objects are JSON-stringified) |
| `console.error(...args)` | Alias for `log` |
| `console.warn(...args)` | Alias for `log` |
| `console.info(...args)` | Alias for `log` |

### `h(type, props, ...children) → vnode`

Creates a virtual DOM node for use with `milktea.run()`.

```js
const btn = h("button", { onclick: () => milktea.quit() }, "Exit");
```

Returns `{ type, props: {...}, children: [...] }`.

### `milktea` — milktea API

#### App lifecycle

| Method | Signature | Description |
|--------|-----------|-------------|
| `milktea.run(model)` | `model → void` | Register the application model. Required — scripts that do not call this will fail. |
| `milktea.quit()` | `→ "quit"` | Request application exit |

The `model` object must implement:
- `init()` — called once at startup, return `null` or a command
- `update(msg)` — called on each event, return updated model or `[model, cmd]`
- `view()` — return a string or vnode tree to render

```js
milktea.run({
  count: 0,
  init() { return null; },
  update(msg) {
    if (milktea.isKey(msg, "q") || milktea.isKey(msg, "ctrl+c")) return milktea.quit();
    if (milktea.isKey(msg, "space")) this.count++;
    return this;
  },
  view() { return `Count: ${this.count}\nPress space, q to quit`; },
});
```

#### Commands

| Method | Signature | Description |
|--------|-----------|-------------|
| `milktea.tick(tag)` | `tag → cmd` | Schedule a tick event (used with `milktea.batch`) |
| `milktea.batch(...cmds)` | `...cmds → cmd` | Run multiple commands concurrently |

#### Key helpers

| Method | Signature | Description |
|--------|-----------|-------------|
| `milktea.keyName(msg)` | `msg → string` | Extract the key code from a key message |
| `milktea.isKey(msg, code)` | `(msg, code) → boolean` | Check if a message matches a key code |

Common key codes: `"q"`, `"space"`, `"enter"`, `"esc"`, `"tab"`, `"backspace"`, `"delete"`, `"up"`, `"down"`, `"left"`, `"right"`, `"ctrl+c"`, `"ctrl+z"`, `"ctrl+l"`.

#### Textarea component

| Method | Signature | Description |
|--------|-----------|-------------|
| `milktea.textareaUpdate(id, msg)` | Forward a key event to the textarea |
| `milktea.textareaGetText(id)` | `→ string` | Get current text content |
| `milktea.textareaClear(id)` | Clear the textarea |
| `milktea.textareaGetCursor(id)` | `→ { row, col }` | Get cursor position |

#### Viewport component

| Method | Signature | Description |
|--------|-----------|-------------|
| `milktea.viewportUpdate(id, msg)` | Forward a key event to the viewport |
| `milktea.viewportScrollToBottom(id)` | Scroll to the bottom |
| `milktea.viewportScrollUp(id)` | Scroll up one line |
| `milktea.viewportScrollDown(id)` | Scroll down one line |
| `milktea.viewportPageUp(id)` | Page up |
| `milktea.viewportPageDown(id)` | Page down |

---

## Global Functions

### Timers

| Function | Signature | Description |
|----------|-----------|-------------|
| `setTimeout` | `setTimeout(fn, delay_ms) → id` | One-shot timer |
| `clearTimeout` | `clearTimeout(id)` | Cancel a timeout |
| `setInterval` | `setInterval(fn, delay_ms) → id` | Repeating timer |
| `clearInterval` | `clearInterval(id)` | Cancel an interval |

### `fetch(url, opts?) → Promise<Response>`

HTTP client backed by libcurl, running on a background thread.

**Options:**

| Field | Type | Description |
|-------|------|-------------|
| `method` | `string` | HTTP method (default `"GET"`) |
| `body` | `string` | Request body |
| `headers` | `object` | Request headers |
| `stream` | `boolean` | Enable streaming response body |

**Response object:**

| Field/Method | Type | Description |
|--------------|------|-------------|
| `.ok` | `boolean` | Status 200-299 |
| `.status` | `number` | HTTP status code |
| `.text()` | `Promise<string>` | Response body as text |
| `.json()` | `Promise<object>` | Parse response body as JSON |
| `.body` | `async iterable` | Streaming body (only with `stream: true`) |

```js
// Simple fetch
const res = await fetch("https://api.example.com/data");
const data = await res.json();

// POST with body
await fetch("https://api.example.com/submit", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ key: "value" }),
});

// Streaming (SSE)
const stream = await fetch("https://api.example.com/events", { stream: true });
for await (const chunk of stream.body) {
  console.log(chunk);
}
```

### `blendLuv(from, to, t) → string`

Interpolate between two hex colors in CIELUV color space.

```js
const mid = blendLuv("#ff0000", "#0000ff", 0.5);
// → interpolated hex color string
```

---

## Example: Full App

```js
import { file, write } from "fs";
import { getenv } from "os";

// Read config from home directory
const home = getenv("HOME");
const configPath = home + "/.myapp/config.json";
const config = file(configPath).json() || { count: 0 };

milktea.run({
  count: config.count,
  init() { return null; },
  update(msg) {
    if (milktea.isKey(msg, "q") || milktea.isKey(msg, "ctrl+c")) {
      // Save state before quitting
      write(configPath, JSON.stringify({ count: this.count }));
      return milktea.quit();
    }
    if (milktea.isKey(msg, "space")) this.count++;
    return this;
  },
  view() {
    return `Counter: ${this.count}\n` +
           `Config: ${configPath}\n\n` +
           `space = increment, q = quit`;
  },
});
```
