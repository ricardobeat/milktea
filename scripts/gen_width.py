#!/usr/bin/env python3
"""Generate the character-width range tables used by xray and glaze.

Terminal cell width is decided per codepoint: 0 for combining marks and other
zero-advance characters, 2 for East Asian Wide/Fullwidth and emoji-presentation
characters, 1 for everything else. The rules were previously hand-written as a
cascade of range checks in two places, which drifted from real Unicode data —
BMP emoji (U+231A watch, U+2615 coffee, U+2705 check mark) were reported narrow,
and every combining mark outside Latin (Arabic, Hebrew, Devanagari, Thai,
Khmer, Tibetan) was reported as one column instead of zero. Both errors
desynchronise the cursor by a column per character.

Sources, via Python's unicodedata (UCD 15.0):
  width 0 — general category Mn (nonspacing mark), Me (enclosing mark), Cf
            (format) except the ones terminals do advance for, plus the
            explicit zero-width and variation-selector blocks.
  width 2 — east_asian_width in {W, F}.

Run `just gen-width` after changing this file; it rewrites the generated block
in xray/width.c3 and glaze/style.c3 in place. The two tables are identical by
construction, and test_glaze_and_xray_widths_agree proves it at build time.
"""

import re
import sys
import unicodedata
from pathlib import Path

MAX_CP = 0x110000

# Zero-width regardless of category: these are format/space characters that
# terminals render with no advance.
EXPLICIT_ZERO = set()
EXPLICIT_ZERO |= set(range(0x200B, 0x2010))  # ZWSP, ZWNJ, ZWJ, LRM, RLM
EXPLICIT_ZERO.add(0x2060)  # WORD JOINER
EXPLICIT_ZERO.add(0xFEFF)  # ZWNBSP / BOM
EXPLICIT_ZERO |= set(range(0xFE00, 0xFE10))  # variation selectors 1-16
EXPLICIT_ZERO |= set(range(0xE0100, 0xE01F0))  # variation selectors supplement
EXPLICIT_ZERO |= set(range(0xE0020, 0xE0080))  # tag characters
EXPLICIT_ZERO.add(0)  # NUL, by terminal convention

# Soft hyphen is a format char but occupies a column when rendered.
FORMAT_WITH_WIDTH = {0x00AD}


def width_of(cp: int) -> int:
    if cp in EXPLICIT_ZERO:
        return 0
    ch = chr(cp)
    cat = unicodedata.category(ch)
    if cat in ("Mn", "Me"):
        return 0
    if cat == "Cf" and cp not in FORMAT_WITH_WIDTH:
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def ranges_for(target: int):
    """Collapse the codepoints of a given width into (start, end) ranges."""
    out = []
    start = None
    for cp in range(MAX_CP):
        if width_of(cp) == target:
            if start is None:
                start = cp
        elif start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, MAX_CP - 1))
    return out


def emit(zero, wide, prefix: str) -> str:
    """Render the ranges plus a binary-search lookup, as C3 source.

    `prefix` distinguishes the two copies' private symbols so the modules can
    be compiled together (as the test target does) without colliding.
    """

    def table(name, rs):
        lines = [f"const CodepointRange[{len(rs)}] {name} = {{"]
        for lo, hi in rs:
            lines.append(f"\t{{ 0x{lo:04X}, 0x{hi:04X} }},")
        lines.append("};")
        return "\n".join(lines)

    zero_name = f"{prefix}_ZERO_RANGES"
    wide_name = f"{prefix}_WIDE_RANGES"
    search = f"{prefix.lower()}_in_ranges"

    return "\n".join(
        [
            "// A half-open-free inclusive codepoint range, sorted ascending.",
            "struct CodepointRange { uint lo; uint hi; }",
            "",
            table(zero_name, zero),
            "",
            table(wide_name, wide),
            "",
            f"fn bool {search}(CodepointRange[] ranges, uint cp) @local {{",
            "\tusz lo = 0;",
            "\tusz hi = ranges.len;",
            "\twhile (lo < hi) {",
            "\t\tusz mid = lo + (hi - lo) / 2;",
            "\t\tif (cp < ranges[mid].lo) {",
            "\t\t\thi = mid;",
            "\t\t} else if (cp > ranges[mid].hi) {",
            "\t\t\tlo = mid + 1;",
            "\t\t} else {",
            "\t\t\treturn true;",
            "\t\t}",
            "\t}",
            "\treturn false;",
            "}",
            "",
            f"fn int {prefix.lower()}_lookup(uint cp) @local {{",
            "\t// Fast path: ASCII is by far the most common input and is",
            "\t// entirely width 1 apart from NUL, which the zero table covers.",
            "\tif (cp >= 0x20 && cp < 0x7F) return 1;",
            f"\tif ({search}({zero_name}[..], cp)) return 0;",
            f"\tif ({search}({wide_name}[..], cp)) return 2;",
            "\treturn 1;",
            "}",
        ]
    )


BEGIN = "// BEGIN GENERATED WIDTH TABLES — edit scripts/gen_width.py, run `just gen-width`"
END = "// END GENERATED WIDTH TABLES"


def splice(path: Path, block: str) -> bool:
    text = path.read_text()
    pattern = re.compile(
        re.escape(BEGIN) + r".*?" + re.escape(END), re.DOTALL
    )
    if not pattern.search(text):
        print(f"error: {path} has no generated block ({BEGIN!r})", file=sys.stderr)
        return False
    path.write_text(pattern.sub(BEGIN + "\n" + block + "\n" + END, text))
    return True


def main() -> int:
    zero = ranges_for(0)
    wide = ranges_for(2)
    print(f"zero-width ranges: {len(zero)}   wide ranges: {len(wide)}")

    root = Path(__file__).resolve().parent.parent
    ok = True
    for rel, prefix in (("xray/width.c3", "XRAY_WIDTH"), ("glaze/style.c3", "GLAZE_WIDTH")):
        ok &= splice(root / rel, emit(zero, wide, prefix))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
