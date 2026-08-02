#!/usr/bin/env python3
"""Screen harness — render a milktea example's output to a cell grid.

Runs an example binary under a pty, feeds it a key script, applies the
captured ANSI stream to a persistent cell grid (a miniature terminal: CUP,
SGR, wide glyphs, alt-screen, erase ops), and dumps per-frame snapshots so
cursor/animation rendering can be inspected without a real terminal.

Frames are delimited by the synchronized-output markers (mode 2026) the
framework emits when it thinks the terminal supports sync; set TERM_PROGRAM to
a known-good value (the harness does this) to get them.

Usage:
    scripts/screen_harness.py out/examples/cursors [--keys "tab:400 q:100"] [--cols 80] [--rows 24]
"""

import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
import unicodedata

# ---------------------------------------------------------------- width table
# Mirror of scripts/gen_width.py's rules (EAW W/F wide, Mn/Me/Cf zero).

def char_width(cp: int) -> int:
    if cp == 0:
        return 0
    if 0x200B <= cp < 0x2010 or cp in (0x2060, 0xFEFF):
        return 0
    if 0xFE00 <= cp < 0xFE10 or 0xE0100 <= cp < 0xE01F0 or 0xE0020 <= cp < 0xE0080:
        return 0
    ch = chr(cp)
    cat = unicodedata.category(ch)
    if cat in ("Mn", "Me"):
        return 0
    if cat == "Cf" and cp != 0x00AD:
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def utf8_width(data: bytes) -> int:
    """Display width of a (valid) UTF-8 sequence starting at data[0]."""
    b0 = data[0]
    if b0 < 0x80:
        return char_width(b0)
    if 0xC2 <= b0 <= 0xDF and len(data) >= 2:
        return char_width(((b0 & 0x1F) << 6) | (data[1] & 0x3F))
    if 0xE0 <= b0 <= 0xEF and len(data) >= 3:
        cp = ((b0 & 0x0F) << 12) | ((data[1] & 0x3F) << 6) | (data[2] & 0x3F)
        return char_width(cp)
    if 0xF0 <= b0 <= 0xF4 and len(data) >= 4:
        cp = ((b0 & 0x07) << 18) | ((data[1] & 0x3F) << 12) | ((data[2] & 0x3F) << 6) | (data[3] & 0x3F)
        return char_width(cp)
    return 1  # lone byte / continuation / invalid lead


# ------------------------------------------------------------------ terminal
class Terminal:
    """A tiny ANSI terminal: a cell grid plus a parsing cursor/pen."""

    def __init__(self, cols: int, rows: int):
        self.cols = cols
        self.rows = rows
        self.reset()
        # cell is a str; "" = wide-glyph placeholder (blank), " " = space.
        self.grid = [[" " for _ in range(cols)] for _ in range(rows)]
        self.pen_fg = None       # (r, g, b) or None (default)
        self.pen_bg = None
        self.alt_on = False
        self.frame = 0
        self.osc_log = []        # OSC sequences seen since last snapshot
        self.ctrl_log = []       # DECSCUSR / show-hide seen since last snapshot

    def reset(self):
        self.r = 0
        self.c = 0

    def write_char(self, text: str, w: int):
        r, c = self.r, self.c
        if w == 0:
            return
        if r < 0 or r >= self.rows:
            return
        if c >= self.cols:
            return
        self.grid[r][c] = text
        if w == 2:
            if c + 1 < self.cols:
                self.grid[r][c + 1] = ""  # placeholder
        self.c = min(c + w, self.cols)

    def write_utf8(self, data: bytes):
        w = utf8_width(data)
        self.write_char(data.decode("utf-8", "replace"), w)

    def erase_line(self, mode: int):
        r = self.r
        if mode in (0, 2):
            for c in range(self.c, self.cols):
                self.grid[r][c] = " "
        elif mode == 1:
            for c in range(0, self.c + 1):
                self.grid[r][c] = " "

    def erase_display(self, mode: int):
        if mode == 2:
            for r in range(self.rows):
                for c in range(self.cols):
                    self.grid[r][c] = " "

    def snapshot(self) -> list:
        """Return the grid as a list of visible row strings."""
        out = []
        for r in range(self.rows):
            row = []
            for c in range(self.cols):
                cell = self.grid[r][c]
                row.append(" " if cell == "" else cell)
            out.append("".join(row).rstrip())
        return out


# ------------------------------------------------------------------- parsing
def parse_stream(term: Terminal, data: bytes, on_frame):
    """Apply ANSI bytes to term. on_frame() is called at sync boundaries."""
    i = 0
    n = len(data)
    buf = data
    while i < n:
        b = buf[i]
        if b == 0x1B:  # ESC
            if i + 1 >= n:
                return i
            nxt = buf[i + 1]
            if nxt == 0x5B:  # '[' -> CSI
                end = i + 2
                while end < n and not (0x40 <= buf[end] <= 0x7E):
                    end += 1
                if end >= n:
                    return i
                handle_csi(term, buf[i + 2:end], buf[end])
                i = end + 1
                continue
            elif nxt == 0x5D:  # ']' -> OSC
                end = i + 2
                while end < n and buf[end] != 0x07:
                    if buf[end] == 0x1B and end + 1 < n and buf[end + 1] == 0x5C:
                        end += 1
                        break
                    end += 1
                if end >= n:
                    return i
                term.osc_log.append(buf[i:end + (1 if buf[end] == 0x07 else 0)].decode("latin-1"))
                i = end + 1
                continue
            elif nxt == 0x50:  # 'P' -> DCS (sync payload, parse as plain output)
                end = i + 2
                while end + 1 < n and not (buf[end] == 0x1B and buf[end + 1] == 0x5C):
                    end += 1
                if end + 1 >= n:
                    return i
                i = end + 2
                continue
            else:  # two-byte escape (ESC M, ESC 7, ESC = ...)
                i += 2
                continue
        elif b == 0x0A:  # LF
            term.r += 1
            if term.r >= term.rows:
                term.r = term.rows - 1
            i += 1
            continue
        elif b == 0x0D:  # CR
            term.c = 0
            i += 1
            continue
        elif b == 0x08:  # BS
            term.c = max(0, term.c - 1)
            i += 1
            continue
        elif b < 0x20:  # other control
            i += 1
            continue
        # printable UTF-8
        w = utf8_width(buf[i:])
        nbytes = 1
        if b >= 0xC2:
            nbytes = 2 if b <= 0xDF else 3 if b <= 0xEF else 4
        if i + nbytes <= n:
            term.write_utf8(buf[i:i + nbytes])
            i += nbytes
        else:
            return i
    return n


def decode_csi_params(bs: bytes):
    """Split a CSI parameter string into a list of int params (sub-params flattened)."""
    out = []
    cur = 0
    neg = False
    for b in bs:
        if 0x30 <= b <= 0x39:
            cur = cur * 10 + (b - 0x30)
        elif b == 0x3B or b == 0x3A:
            out.append(-cur if neg else cur)
            cur = 0
            neg = False
        elif b == 0x2D:
            neg = True
    out.append(-cur if neg else cur)
    return out


def handle_csi(term: Terminal, params: bytes, final: int):
    if final in (0x48, 0x66):  # CUP
        p = decode_csi_params(params)
        term.r = (p[0] if len(p) > 0 and p[0] > 0 else 1) - 1
        term.c = (p[1] if len(p) > 1 and p[1] > 0 else 1) - 1
        if term.r >= term.rows:
            term.r = term.rows - 1
        if term.c >= term.cols:
            term.c = term.cols - 1
        return
    if final == 0x4B:  # EL
        p = decode_csi_params(params)
        term.erase_line(p[0] if p else 0)
        return
    if final == 0x4A:  # ED
        p = decode_csi_params(params)
        term.erase_display(p[0] if p else 0)
        term.reset()
        return
    if final == 0x6D:  # SGR
        p = decode_csi_params(params)
        i = 0
        while i < len(p):
            v = p[i]
            if v == 0:
                term.pen_fg = term.pen_bg = None
            elif v == 38 or v == 48:
                if i + 1 < len(p) and p[i + 1] == 5 and i + 2 < len(p):
                    i += 2
                elif i + 2 < len(p) and p[i + 1] == 2 and i + 4 < len(p):
                    col = (p[i + 2], p[i + 3], p[i + 4])
                    if v == 38:
                        term.pen_fg = col
                    else:
                        term.pen_bg = col
                    i += 4
            i += 1
        return
    if final == 0x51:  # DECSCUSR "ESC [ <n> q"
        term.ctrl_log.append(f"DECSCUSR:{decode_csi_params(params)[0]}")
        return
    if final == 0x68 or final == 0x6C:  # mode set/reset (?-prefixed)
        # ALT screen (1049), cursor (25), sync (2026) — nothing to do for the grid.
        return
    # anything else (CPR replies, scrolling, etc.) is ignored


# ----------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("binary")
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--keys", default="",
                    help="key script: space-separated tokens 'KEY:ms' or 'KEY' "
                         "where KEY is a literal like tab, esc, q; ms = pause before next")
    ap.add_argument("--sleep", type=float, default=1.0,
                    help="extra seconds to keep capturing after the key script ends")
    ap.add_argument("--every", type=int, default=1,
                    help="print only every Nth frame snapshot")
    args = ap.parse_args()

    # Tokenise the key script.
    actions = []
    for tok in args.keys.split():
        if ":" in tok:
            key, ms = tok.split(":", 1)
            actions.append((key, int(ms)))
        else:
            actions.append((tok, 0))

    def key_bytes(k: str) -> bytes:
        return {
            "tab": b"\t", "esc": b"\x1b", "q": b"q", "enter": b"\r",
            "left": b"\x1b[D", "right": b"\x1b[C", "backspace": b"\x7f",
            "space": b" ", "up": b"\x1b[A", "down": b"\x1b[B",
        }.get(k, k.encode())

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["TERM_PROGRAM"] = "ghostty"  # enable sync output markers
        os.execv(args.binary, [args.binary])
        os._exit(1)

    # Set the pty winsize so the example sees --cols/--rows, not the pty default.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))

    term = Terminal(args.cols, args.rows)

    buf = bytearray()
    frames = []
    last_print = 0
    t0 = time.time()

    def snapshot():
        frames.append((time.time() - t0, term.osc_log[:], term.ctrl_log[:], term.snapshot()))
        term.osc_log.clear()
        term.ctrl_log.clear()

    def drain(timeout: float):
        nonlocal buf
        # Read for up to `timeout` seconds, processing complete sync frames as
        # they arrive. A single select-0 read can return mid-frame, so frames
        # are only applied once both sync markers are present; anything else
        # is plain output (startup sequences, cursor positioning, OSC) parsed
        # into the grid. Time-bounded rather than quiet-bounded: examples that
        # re-arm their timer every frame never go quiet, and waiting for 80ms
        # of silence would hang forever.
        deadline = time.time() + timeout

        def process():
            while True:
                idx = buf.find(b"\x1b[?2026h")
                if idx < 0:
                    return  # no frame start; tail is plain output
                end = buf.find(b"\x1b[?2026l", idx)
                if end < 0:
                    return  # incomplete frame; wait for more bytes
                head = bytes(buf[:idx])
                if head:
                    parse_stream(term, head, None)
                parse_stream(term, bytes(buf[idx + len(b"\x1b[?2026h"):end]), None)
                snapshot()
                del buf[:end + len(b"\x1b[?2026l")]

        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            r, _, _ = select.select([fd], [], [], min(remaining, 0.05))
            if not r:
                continue
            while True:
                r2, _, _ = select.select([fd], [], [], 0)
                if not r2:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
            process()
        if buf:
            parse_stream(term, bytes(buf), None)
            buf.clear()

    # initial drain: let the first frames settle
    drain(0.25)
    try:
        for key, ms in actions:
            os.write(fd, key_bytes(key))
            time.sleep(ms / 1000.0)
            drain(0.1)
        drain(args.sleep)
        snapshot()
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(fd)

    # Print snapshots
    printed = 0
    for i, (t, oscs, ctrls, rows) in enumerate(frames):
        if i % args.every != 0:
            continue
        printed += 1
        print(f"==== frame {i} @ {t:.2f}s  osc={oscs}  ctrl={ctrls}")
        for line in rows:
            print(line)
        print()
    print(f"-- {len(frames)} frames captured, {printed} shown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
