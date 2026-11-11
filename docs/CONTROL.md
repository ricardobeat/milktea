# Driving a program from outside

Any milktea program, terminal or window, can be driven by another program,
such as an agent: it reads what the program shows and sends it the clicks
and keys a person would. Commands are lines of text. Each is answered with
its output and then `ok`, or with one line `err ...`.

There are two ways in.

**Piped stdin.** When a program's stdin is not a terminal, each line of it is
a command, answered on stdout. A window app always takes commands on stdin,
since its input comes from the window, so it can be driven from the terminal
that launched it.

```sh
printf 'screen\nclick Save\nscreen\nquit\n' | ted
```

When stdin runs out, a program with nothing left to do exits on its own.

**`--cmd`, for a program already running.** Run the same binary again with
`--cmd` and a command, from anywhere:

```sh
ted                       # in one terminal, as usual
ted --cmd tree            # from another
ted --cmd click Save
```

`--cmd` sends the rest of its command line as one command, prints the reply,
and exits 0 on `ok`, 1 on `err`. It drives the most recently started `ted`;
`MILKTEA_PID=<pid>` picks another.

The first `--cmd` has to be allowed by whoever is at the program, which shows

```
Allow remote control?  [yes]  [no]
```

at the bottom of the screen, and `--cmd` waits up to a minute for the answer.
Left, right or tab choose, enter answers, esc says no, and so does a click.
It starts on "no" and letters answer nothing, so someone typing when it comes
up cannot say yes by accident. A refusal answers
`err remote control was refused`, and the next `--cmd` asks again. Once
allowed, a white dot on red sits in the bottom left corner.

| started with | |
|---|---|
| `MILKTEA_CONTROL=1` | takes `--cmd` at once without asking: for a program an agent starts itself |
| nothing | asks on the first `--cmd` |
| `MILKTEA_CONTROL=0` | cannot be driven with `--cmd` or asked |

## Commands

| command | does |
|---|---|
| `tree` | the nodes on screen, one a line, indented by depth |
| `screen` | the text on screen, one line a row |
| `click T` | moves to T, presses and releases |
| `move T` | moves to T, which hovers it |
| `drag T1 T2` | presses at T1, moves to T2 and releases there |
| `scroll T N` | scrolls N rows at T; positive scrolls towards the end |
| `key SPEC...` | sends keys: `ctrl+b`, `enter`, `shift+tab`, `a`, `space`, `f5` |
| `type TEXT` | sends the rest of the line, a key a character |
| `quit` | quits the program |

Commands run between frames, against the frame on screen, and input goes the
way real input does, so hover, focus and clicks behave as they do for a
person. A command that sends input answers `ok` once a frame showing its
effect has been drawn, and the commands after it wait for that: a `screen`
after a `click` shows what the click did.

## Targets

| target | is |
|---|---|
| `@12,3` | the cell at column 12, row 3, counting from 0 (`screen` rows line up); `@-1,-1` is outside the program |
| `Save` | a node whose id, role, type or key is `Save`; if none, one that shows the text `Save` |
| `"Save as"` | a node that shows that text |

When several nodes match, the topmost is the one, and the command acts on its
middle.

## The tree

```
* @0,0 80x24
  menubar @0,0 80x1
    menu key=File @0,0 6x1 clickable "File"
```

Each line is a node: its id, else its role, else its content type, else `*`;
its key; its place as `@col,row` and size; `clickable` and `focused` when it
is; and for a node with nothing inside it, the text it shows.

Name what a script will look for:

```c3
row.id("file").key(name).role(LIST_ITEM)
```

`id` says what kind of thing a node is, so many nodes can share one. `key`
tells them apart by something a person would recognise, such as a name or a
label. `role` comes from a fixed list close to the one accessibility uses.

## Leaving it out

Build with `-D NO_CONTROL` (or `"features": ["NO_CONTROL"]` in a target in
`project.json`) and none of this is in the binary: piped stdin is keys again,
and `--cmd` and the dialog are gone. Control costs about 20 KB.
