# Driving a program from the command line

A milktea program is itself its own command line: when its stdin is not a
terminal, each line of stdin is a command and each reply is a line on
stdout. No socket, no client program, no JSON.

This is automatic. A terminal program whose stdin is piped takes commands;
a window program (a `milktea_gui` app) always takes them, because its input
comes from the window, not stdin, so you can drive it from the terminal you
launched it in.

```sh
printf 'ping\nquit\n' | ted
echo 'tree' | milktea-gui
```

A command answers with its output and then `ok`, or with one line
`err ...` when it fails. So a script reads lines until it sees `ok` or
`err`.

## Commands

| command | does |
|---|---|
| `ping` | answers |
| `tree [SEL]` | the tree, from the root, or each match's subtree |
| `list SEL` | each node a selector matches, one a line |
| `match PATTERN` | nodes whose on-screen text matches the pattern |
| `click SEL` or `@c,r` | moves there, presses and releases |
| `press`, `release`, `move` | one of those |
| `drag FROM TO` | each a selector or `@c,r` |
| `scroll [WHERE] [dy=N] [dx=N]` | in rows; positive scrolls towards the end |
| `key SPEC` | `ctrl+b`, `enter`, `shift+tab`, `a` |
| `type TEXT` | the rest of the line, spaces included, one key per character |
| `select SEL TEXT` or `/PAT/ [N]` | drags across text on screen; see below |
| `screen [PATTERN]` | the text on screen, or the lines that match |
| `stream` | echo the input the program gets as commands |
| `quit` | quits the program |

`SEL` is a [selector](#selectors); the command targets the middle of the
first node it matches. `@c,r` is a cell of the screen; `@-1,-1` is outside
the program. Where a node is and what it shows are read from the last
drawn frame.

A selector holding a space travels in quotes, with single quotes around the
value inside: `list "list-item[text='a b']"`.

Commands are handled between frames, on the program's own thread, and input
goes through the same path real input takes, so hover, focus and clicks
behave the same as with a real mouse or keyboard.

A command that sends input answers `ok` once the input is sent. The commands
after it wait for the next frame, so a `screen` that follows a `click` shows
what the click did.

## A session

```sh
$ printf 'screen\nlist :clickable\nclick button[key="save"]\nscreen\nquit\n' | ted
[the lines of the screen]
button[key="save"] @12,14 12x1 :clickable
ok
[the lines of the screen, after the click]
ok
```

With a window app the replies appear in the launching terminal while the
program's window shows what is driven. On `quit` the window closes.

When the pipe runs out, a program that has nothing left to do exits on its
own, so `quit` is only needed to stop one that keeps going (a clock).

## Selecting text

`select` selects text the way a person would. It looks for the `n`th
occurrence of `TEXT`, counting from 0, or the `n`th match of the pattern
`/PAT/`, in what the target shows on screen, and drags from where it starts
to just past where it ends. Only text on screen can be found, so scroll to
it first.

```
select editor "import boba;"
select editor /fn \w+/
```

## The pattern language

The pattern matcher is deliberately tiny: literals, `.`, the escapes `\d`,
`\w` and `\s`, the quantifiers `*`, `+` and `?`, and the anchors `^` and
`$`. There are no groups, no alternation and no character classes. A pattern
matches anywhere in the text unless it starts with `^`.

## Nodes and the tree

One node on its own line:

```
file [key="src/"] @1,11 23x1 :clickable :focusable
```

The name is the node's `id`, else its `role`, else its content `type`, else
`*`. Then the node's `key`, its place on screen as `@col,row WxH`, its state
as `:clickable`, `:focusable` and `:focused`, and, for a leaf, its text
quoted. `tree` indents by depth; `list` and `match` print flat.

Name the things a script will look for:

```c3
row.id("file").key(name).role(LIST_ITEM)
```

`id` says what kind of thing a node is, so many nodes can share one. `key`
tells them apart by something a person would recognise, such as a name or a
label. `role` comes from a fixed list close to the one accessibility uses.

## Selectors

| selector | matches |
|---|---|
| `file` | a node whose id, role or type is `file` |
| `*` | any node |
| `[key="src/"]` | key equal to `src/`; `id`, `role`, `type` and `text` work too |
| `[text*="Save"]` | text containing `Save`; `^=` is starts with |
| `:focused`, `:clickable` | a node in that state |
| `:nth(2)` | the third match of the whole selector; `list` and `tree` then show only that one |
| `sidebar file` | a `file` inside `sidebar` |

These can be combined: `sidebar list-item[text^="src"]:nth(0)`. Text is
matched with its spaces trimmed off both ends.

## Streaming input

`stream` turns the input the program gets into commands, so another copy of
the program can do what it does:

```
key ctrl+b
move @5,3
press @5,3
release @5,3
scroll @5,3 dy=1.00
```

These are commands in the same language, so the output of one program's
`stream` can be piped into another's stdin. `stream` answers `stream on` or
`stream off`.

## Not yet

- The model's own state cannot be read; only what is on screen.
- Keys can be sent but not released, and the mouse has only the left
  button.
- There is no screenshot over the command line (but `MILKTEA_GUI_SHOT`
  takes one of a GUI app).
