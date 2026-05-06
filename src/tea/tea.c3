module tea;

enum MsgKind : char {
    NONE,
    KEY,
    WINDOW_SIZE,
    FOCUS,
    BLUR,
    MOUSE,
    BATCH,
    QUIT,
    USER,
}

struct WindowSizeMsg {
    int width;
    int height;
}

struct Msg {
    MsgKind kind;
    KeyMsg key;
    WindowSizeMsg window_size;
    MouseMsg mouse;
    int tag;
    void* user;
}

// Cmd: function pointer producing a Msg. A null Cmd means "no command".
alias Cmd = fn Msg();

interface Model {
    fn Cmd init();
    fn Cmd update(Msg msg);
    fn String view();
}

fn Msg make_quit_msg() @local {
    return { .kind = MsgKind.QUIT };
}

// Batch system: run multiple Cmds, dispatch each result
const usz MAX_BATCH = 16;

Cmd[MAX_BATCH] g_batch_cmds;
int g_batch_count = 0;

fn Msg make_batch_msg() @local {
    return { .kind = MsgKind.BATCH };
}

fn Cmd batch(Cmd[] cmds) {
    Cmd[16] filtered;
    int count = 0;
    for (usz i = 0; i < cmds.len && count < 16; i++) {
        if (cmds[i] != null) {
            filtered[count] = cmds[i];
            count++;
        }
    }
    if (count == 0) return null;
    if (count == 1) return filtered[0];
    for (int i = 0; i < count; i++) {
        g_batch_cmds[g_batch_count++] = filtered[i];
    }
    return &make_batch_msg;
}

fn Cmd quit() {
    return &make_quit_msg;
}

// Returns true if QUIT was seen.
fn bool dispatch(Model model, Msg m) @local {
    if (m.kind == MsgKind.QUIT) return true;
    if (m.kind == MsgKind.BATCH) {
        Cmd[16] cmds;
        int count = g_batch_count;
        for (int i = 0; i < count; i++) cmds[i] = g_batch_cmds[i];
        g_batch_count = 0;
        for (int i = 0; i < count; i++) {
            Msg sub = cmds[i]();
            if (sub.kind != MsgKind.NONE) {
                if (dispatch(model, sub)) return true;
            }
        }
        return false;
    }
    Cmd c = model.update(m);
    int chain = 0;
    while (c != null && chain < 16) {
        Msg next = c();
        if (next.kind == MsgKind.QUIT) return true;
        if (next.kind == MsgKind.NONE) break;
        if (next.kind == MsgKind.BATCH) {
            if (dispatch(model, next)) return true;
            break;
        }
        c = model.update(next);
        chain++;
    }
    return false;
}

// Timer system
const usz MAX_TIMERS = 32;

struct TimerEntry {
    bool active;
    usz deadline_ms;
    Cmd callback;
}

TimerEntry[MAX_TIMERS] g_timers;

fn Cmd tick(usz delay_ms, Cmd callback) {
    usz deadline = time_ms() + delay_ms;
    for (usz i = 0; i < MAX_TIMERS; i++) {
        if (!g_timers[i].active) {
            g_timers[i].active = true;
            g_timers[i].deadline_ms = deadline;
            g_timers[i].callback = callback;
            break;
        }
    }
    return null;
}

fn void? run(Model model) {
    TtyState saved = raw_mode_enter()!;
    defer raw_mode_restore(saved);
    defer show_cursor();
    defer disable_focus();
    defer disable_mouse();
    hide_cursor();
    enable_focus();
    setup_sigwinch();

    WinSize initial_ws = get_window_size();
    Msg init_wmsg = { .kind = MsgKind.WINDOW_SIZE, .window_size = { (int)initial_ws.ws_col, (int)initial_ws.ws_row } };
    if (dispatch(model, init_wmsg)) return;

    Cmd c0 = model.init();
    if (c0 != null) {
        Msg m0 = c0();
        if (m0.kind != MsgKind.NONE && dispatch(model, m0)) return;
    }
    @pool() {
        render_frame(model.view());
    };

    char[256] pending;
    usz pending_len = 0;
    char[64] tmp;

    while (true) {
        // Fire expired timers
        bool dirty = false;
        usz now = time_ms();
        for (usz i = 0; i < MAX_TIMERS; i++) {
            if (g_timers[i].active && now >= g_timers[i].deadline_ms) {
                Cmd cb = g_timers[i].callback;
                g_timers[i].active = false;
                Msg m = cb();
                if (m.kind != MsgKind.NONE && dispatch(model, m)) return;
                dirty = true;
                now = time_ms(); // refresh after dispatch may register new timers
            }
        }

        // Calculate poll timeout from nearest timer
        int timeout = 50;
        now = time_ms();
        for (usz i = 0; i < MAX_TIMERS; i++) {
            if (g_timers[i].active) {
                isz wait = (isz)(g_timers[i].deadline_ms - now);
                if (wait < 0) wait = 0;
                if (wait < (isz)timeout) timeout = (int)wait;
            }
        }

        isz n = read_stdin_timeout(tmp[..], timeout);

        if (g_win_resized) {
            g_win_resized = false;
            WinSize ws = get_window_size();
            Msg wm = { .kind = MsgKind.WINDOW_SIZE, .window_size = { (int)ws.ws_col, (int)ws.ws_row } };
            if (dispatch(model, wm)) return;
            dirty = true;
        }

        if (n > 0) {
            for (isz i = 0; i < n && pending_len < pending.len; i++) {
                pending[pending_len++] = tmp[(usz)i];
            }
        }

        while (pending_len > 0) {
            ParseResult pr = parse_key(pending[:pending_len]);
            if (pr.consumed == 0) break;

            for (usz i = pr.consumed; i < pending_len; i++) {
                pending[i - pr.consumed] = pending[i];
            }
            pending_len -= pr.consumed;

            if (pr.key.code == KeyCode.NONE && pr.kind == MsgKind.KEY) continue;

            Msg m;
            if (pr.kind == MsgKind.FOCUS) {
                m.kind = MsgKind.FOCUS;
            } else if (pr.kind == MsgKind.BLUR) {
                m.kind = MsgKind.BLUR;
            } else if (pr.kind == MsgKind.MOUSE) {
                m.kind = MsgKind.MOUSE;
                m.mouse = pr.mouse;
            } else {
                m.kind = MsgKind.KEY;
                m.key = pr.key;
            }
            if (dispatch(model, m)) return;
            dirty = true;
        }

        if (dirty) {
            @pool() {
                render_frame(model.view());
            };
        }
    }
}