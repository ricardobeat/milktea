#!/usr/bin/env python3
"""Regenerate the `examples/*` targets in project.json from the examples/ directory tree.

project.json hand-maintains ~40 near-identical `examples/*` targets, one per
directory under examples/. This script rebuilds ONLY the keys that start with
"examples/" (in their existing order, or appended in directory-sort order for
new ones), leaving every other key/target in project.json untouched.

Run via `just gen-targets`. To change an example's build config, edit the
OVERRIDES table below and re-run -- do not hand-edit the generated entries in
project.json.
"""
import json
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_JSON = os.path.join(PROJECT_ROOT, "project.json")
EXAMPLES_DIR = os.path.join(PROJECT_ROOT, "examples")

DEFAULT_C_SOURCES = ["milktea/tty_winsize.c"]

QUICKJS_C_SOURCES = [
    "milktea/tty_winsize.c",
    "taro/taro.c",
    "vendor/quickjs/quickjs.c",
    "vendor/quickjs/cutils.c",
    "vendor/quickjs/libregexp.c",
    "vendor/quickjs/libunicode.c",
    "vendor/quickjs/dtoa.c",
]

# Per-example overrides, keyed by the target name (without "examples/"
# prefix). Anything not specified here falls back to the default: sources =
# ["milktea/**", "glaze/**", "dye/**", "examples/<name>/**"], c-sources =
# ["milktea/tty_winsize.c"], opt = "Os", strip-unused = true.
#
# Recognized keys:
#   extra_dirs   - extra top-level source dirs prepended before the example's
#                  own dir, e.g. ["xray"] -> "xray/**"
#   sources      - full explicit `sources` list, overrides everything else
#                  (used for targets with per-file sources, e.g. doom-fire)
#   c_sources    - full explicit `c-sources` list (default: tty_winsize.c only)
#   opt          - opt level (default: "Os")
#   optsize      - value for "optsize" (omitted entirely by default)
#   strip_unused - whether to set "strip-unused": true (default: True; set to
#                  False to omit the key entirely, as cursors/inputbox do)
#   linked_libraries     - value for "linked-libraries"
#   linker_search_paths  - value for "linker-search-paths"
OVERRIDES = {
    "ai-harness": {
        "sources": [
            "milktea/**",
            "glaze/**",
            "dye/**",
            "boba/**",
            "xray/**",
            "examples/lib/http_shim.c3",
            "examples/ai-harness/**",
        ],
        "c_sources": ["milktea/tty_winsize.c", "examples/lib/http_shim.c"],
        "optsize": "tiny",
    },
    "component-viewer": {"extra_dirs": ["boba", "xray"]},
    "modal": {"extra_dirs": ["xray"]},
    "paste": {"extra_dirs": ["boba", "xray"]},
    "split-editors": {"extra_dirs": ["xray"]},
    "avian-assault": {"extra_dirs": ["xray"]},
    "clock": {"extra_dirs": ["xray"]},
    "flappybird": {"extra_dirs": ["xray"]},
    "nanobots": {"extra_dirs": ["xray"]},
    "paint": {"extra_dirs": ["xray"]},
    "minecraft": {"extra_dirs": ["boba", "xray", "taro", "src"]},
    "wolf3d": {"extra_dirs": ["boba", "xray", "taro", "src"]},
    "wolf3d-server": {
        "sources": ["src/**", "examples/wolf3d-server/**"],
        "linked_libraries": ["sqlite3"],
        "linker_search_paths": ["/opt/homebrew/lib"],
    },
    "cursors": {"extra_dirs": ["boba", "xray"], "opt": "O0", "strip_unused": False},
    "inputbox": {"extra_dirs": ["xray"], "opt": "O0", "strip_unused": False},
    "doom-fire": {
        "sources": ["milktea/**", "glaze/**", "dye/**", "examples/doom-fire/doom-fire.c3"],
    },
    "doom-fire-milktea": {
        "sources": ["milktea/**", "glaze/**", "dye/**", "examples/doom-fire/doom-fire-milktea.c3"],
    },
    "doom-fire-donut": {
        "sources": [
            "milktea/**",
            "glaze/**",
            "dye/**",
            "examples/lib/glb.c3",
            "examples/doom-fire-donut/**",
            "examples/lib/stb_json.c3",
        ],
        "c_sources": ["milktea/tty_winsize.c", "examples/lib/stb_json_impl.c"],
    },
    "glb-viewer": {
        "sources": [
            "milktea/**",
            "glaze/**",
            "dye/**",
            "examples/lib/glb.c3",
            "examples/lib/stb_json.c3",
            "examples/glb-viewer/**",
        ],
        "c_sources": ["milktea/tty_winsize.c", "examples/lib/stb_json_impl.c"],
    },
    "oiia-player": {
        "sources": [
            "milktea/**",
            "glaze/**",
            "dye/**",
            "examples/oiia-player/**",
            "examples/lib/stb_image.c3",
            "examples/lib/stb_json.c3",
        ],
        "c_sources": [
            "milktea/tty_winsize.c",
            "examples/lib/stb_image_impl.c",
            "examples/lib/stb_json_impl.c",
        ],
    },
    "taro": {
        "extra_dirs": ["xray", "boba", "taro"],
        "c_sources": QUICKJS_C_SOURCES,
        "linked_libraries": ["curl"],
        "strip_unused": False,
    },
}

# doom-fire's directory produces multiple targets (not a 1:1 dir->target
# mapping), so it's special-cased here instead of derived from a directory
# listing.
EXTRA_TARGETS_FROM_DOOM_FIRE_DIR = ["doom-fire-milktea"]


def discover_example_names():
    """Directory names under examples/ that should produce a target.

    Skips "lib" (a support-code dir pulled in by other targets, not a target
    of its own) and any dir with no .c3 file in it.
    """
    names = []
    for entry in sorted(os.listdir(EXAMPLES_DIR)):
        if entry == "lib":
            continue
        path = os.path.join(EXAMPLES_DIR, entry)
        if not os.path.isdir(path):
            continue
        has_c3 = any(f.endswith(".c3") for f in os.listdir(path))
        if not has_c3:
            continue
        names.append(entry)
    names.extend(EXTRA_TARGETS_FROM_DOOM_FIRE_DIR)
    return names


def build_target(name):
    override = OVERRIDES.get(name, {})

    if "sources" in override:
        sources = override["sources"]
    else:
        extra_dirs = override.get("extra_dirs", [])
        sources = ["milktea/**", "glaze/**", "dye/**"]
        sources.extend(f"{d}/**" for d in extra_dirs)
        sources.append(f"examples/{name}/**")

    target = {
        "type": "executable",
        "sources": sources,
        "c-sources": override.get("c_sources", list(DEFAULT_C_SOURCES)),
        "opt": override.get("opt", "Os"),
    }
    if "optsize" in override:
        target["optsize"] = override["optsize"]
    if override.get("strip_unused", True):
        target["strip-unused"] = True
    if "linked_libraries" in override:
        target["linked-libraries"] = override["linked_libraries"]
    if "linker_search_paths" in override:
        target["linker-search-paths"] = override["linker_search_paths"]
    return target


def dump_target_block(key, target):
    """Render one "examples/<name>": {...} target entry text, 4-space indent
    for the key line and 6-space indent for its fields (matching the style
    of the hand-written entries in project.json), with scalar arrays kept
    inline on a single line.
    """
    lines = [f'    {json.dumps(key)}: {{']
    field_lines = []
    for k, v in target.items():
        if isinstance(v, list):
            rendered = "[" + ", ".join(json.dumps(x) for x in v) + "]"
        else:
            rendered = json.dumps(v)
        field_lines.append(f'      {json.dumps(k)}: {rendered}')
    lines.append(",\n".join(field_lines))
    lines.append("    }")
    return "\n".join(lines)


def main():
    with open(PROJECT_JSON) as f:
        text = f.read()
    data = json.loads(text)

    existing_targets = data["targets"]
    existing_example_keys = [k for k in existing_targets if k.startswith("examples/")]
    existing_example_names = {k[len("examples/") :] for k in existing_example_keys}

    discovered = discover_example_names()
    new_names = [n for n in discovered if n not in existing_example_names]
    if new_names:
        print(
            "gen_targets: found examples/ directories with no existing target "
            "(adding them, please review): " + ", ".join(sorted(new_names))
        )

    # Preserve existing order for known targets; append any newly discovered
    # ones (sorted) at the end of the examples run.
    ordered_names = [k[len("examples/") :] for k in existing_example_keys]
    ordered_names.extend(sorted(new_names))

    if not existing_example_keys:
        raise SystemExit("gen_targets: no existing 'examples/*' targets found in project.json")

    # Locate the contiguous block of "examples/..." target entries in the
    # raw text so every other key/target is left byte-for-byte untouched.
    first_key = existing_example_keys[0]
    last_key = existing_example_keys[-1]

    first_marker = f'    {json.dumps(first_key)}: {{'
    first_idx = text.index(first_marker)

    last_marker = f'    {json.dumps(last_key)}: {{'
    last_marker_idx = text.rindex(last_marker)
    # Find the end of that target's block: the matching "\n    }," or "\n    }"
    # right before the next top-level key (4-space indent) or the closing
    # "targets" brace (2-space indent).
    tail_search_start = last_marker_idx + len(last_marker)
    end_idx = None
    for terminator in ("\n    },\n", "\n    }\n"):
        pos = text.find(terminator, tail_search_start)
        if pos != -1 and (end_idx is None or pos < end_idx):
            end_idx = pos
    if end_idx is None:
        raise SystemExit("gen_targets: could not find end of last examples/ target block")
    block_end = end_idx + len("\n    }")  # exclude trailing comma/newline

    new_blocks = [dump_target_block(f"examples/{name}", build_target(name)) for name in ordered_names]
    replacement = ",\n".join(new_blocks)

    new_text = text[:first_idx] + replacement + text[block_end:]

    with open(PROJECT_JSON, "w") as f:
        f.write(new_text)

    # Sanity check: result must still be valid JSON equivalent to the intent.
    json.loads(new_text)


if __name__ == "__main__":
    main()
