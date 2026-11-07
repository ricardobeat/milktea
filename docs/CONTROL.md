# Driving a program from outside

A milktea program can be driven by another process: a test, a script, a
second copy of the app. Start it with `MILKTEA_CONTROL` set to a socket path:

```sh
MILKTEA_CONTROL=/tmp/app.sock ./app
```

It then listens on that Unix socket, which only your user can open. Without
the variable nothing is opened. It works the same in a terminal and in a
window.

Through the socket you can read the tree the program last drew, send it
clicks, keys and scrolls, wait for it to settle, and follow the input it
gets.

## From the shell

A program can hand `ctl` arguments to `milktea::control_client`, so the app
is its own client. ted does:

```c3
if (args.len > 1 && args[1] == "ctl") return milktea::control_client(args[2..]);
```

Then:

```sh
ted ctl /tmp/app.sock find 'file[key="src/"]'
ted ctl /tmp/app.sock click 'file[key="src/"]' wait idle find statusbar
ted ctl /tmp/app.sock key ctrl+b type 'hello' key enter
ted ctl /tmp/app.sock subscribe
```

Each request is either a command followed by its argument, or a JSON
object. They run in order, and each reply is printed on its own line. The
exit status is 1 if any request failed. `subscribe` keeps printing events
until the program exits.

With only the socket path given, `ctl` reads requests from stdin, one per
line, and prints the replies and events, which is handy for piping.

## The protocol

Each request is one line of JSON, and each reply is one line back. A
request's `"id"` comes back in its reply:

```
→ {"id":1,"cmd":"click","select":"menu[key=\"File\"]"}
← {"id":1,"ok":true}
→ {"id":2,"cmd":"find","select":"nope"}
← {"id":2,"ok":true,"nodes":[]}
→ {"id":3,"cmd":"click","select":"nope"}
← {"id":3,"ok":false,"error":"nothing matches nope"}
```

Requests are handled between frames, on the program's own thread. Input goes
through the same path real input takes, so hover, focus and clicks behave
the same as with a real mouse or keyboard.

| cmd | fields | does |
|---|---|---|
| `ping` | | answers |
| `tree` | `select`, `depth` | the tree from the root, or from each match |
| `find` | `select` | the matching nodes, as a flat list |
| `click` | `select` or `at`, `cell` | moves there, presses and releases |
| `move`, `press`, `release` | `select` or `at`, `cell` | one of those |
| `drag` | `from`, `to` | each is `{select or at, cell}` |
| `scroll` | `select` or `at`, `dy`, `dx` | in rows; positive scrolls towards the end |
| `key` | `key` | `"ctrl+b"`, `"enter"`, `"shift+tab"`, `"a"` |
| `type` | `text` | one key per character |
| `wait` | `frames`, `select` or nothing, `timeout_ms` | see below |
| `subscribe` | `events` | `["input"]` (the default), `["frame"]` |
| `unsubscribe` | `events` | |

`at` is `[col, row]` on the screen, in cells. `select` picks the first match
and points at its middle, or at `cell`, a `[col, row]` within its content.
When a request has both and the selector matches nothing, `at` is used.

`wait` answers once:

- with `frames: n`, n more frames have been drawn;
- with `select`, something matches it;
- with neither, the program is idle: nothing is queued, nothing is
  animating, and the input sent before has been drawn.

It gives up after `timeout_ms`, which defaults to 5000.

## Nodes

A node in a reply looks like this:

```json
{"id":"file","key":"src/","role":"list-item","type":"StyledText",
 "rect":[1,11,23,1],"clickable":true,"text":" src/"}
```

The fields are:

- `id`, `key` and `role` are what the program set with `.id()`, `.key()`
  and `.role()`.
- `type` is the content's type, for nodes made with `content_node`.
- `rect` is `[col, row, width, height]` in cells.
- `text` is what the node shows on screen. `tree` gives it only for leaves,
  and `find` gives it for every match.

Fields that are empty are left out.

Name the things a script will look for:

```c3
row.id("file").key(name).role(LIST_ITEM)
```

`id` says what kind of thing a node is, so many nodes can share one. `key`
tells them apart by something a person would recognise, such as a name or
a label. `role` comes from a fixed list close to the one accessibility uses.
`ref()` is separate: it is the private pointer your callbacks get back.

## Selectors

| selector | matches |
|---|---|
| `file` | a node whose id, role or type is `file` |
| `*` | any node |
| `[key="src/"]` | key equal to `src/`; `id`, `role`, `type` and `text` work too |
| `[text*="Save"]` | text containing `Save`; `^=` is starts with |
| `:focused`, `:clickable` | a node in that state |
| `:nth(2)` | the third match of the whole selector |
| `sidebar file` | a `file` inside `sidebar` |

These can be combined: `sidebar list-item[text^="src"]:nth(0)`. Text is matched with its spaces trimmed off both ends.

## Events

After `subscribe`, input arrives as lines of its own:

```json
{"event":"press","select":"sidebar file[key=\"src/\"]","cell":[11,0],"at":[13,12]}
{"event":"key","key":"ctrl+b"}
{"event":"scroll","dy":3.00,"select":"editor","cell":[26,10],"at":[53,12]}
```

The events are `move`, `press`, `release`, `key` and `scroll`. `select` is a
selector that finds the node under the pointer again, and `cell` is the
place within it. `at` is the place on screen, and is `[-1,-1]` when the
pointer has left the program.

Each event is also the request that repeats it: the socket takes `"event"`
where it would take `"cmd"`, and passes over lines that are replies. So
piping one program's events into another's socket makes the second do what
the first does:

```sh
ted ctl $A subscribe | ted ctl $B > /dev/null
```

The selector finds the same node in B however differently B is laid out, a
window next to a terminal, say. When nothing in B matches it, B uses `at`.

`["frame"]` sends `{"event":"frame","n":42}` after each frame is drawn.

## Not yet

- The model's own state cannot be read; only what is on screen.
- Keys can be sent but not released, and the mouse has only the left
  button.
- A screenshot over the socket.
