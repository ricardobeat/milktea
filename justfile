# Build the milktea static library
build:
    c3c build milktea

# Run the test suite (unit + snapshot tests in test/)
test:
    c3c test

# Re-record snapshot tests (writes snapshots/*/*.snap)
update-snapshots:
    UPDATE_SNAPSHOTS=1 c3c test

# Build all example programs
examples:
    #!/usr/bin/env sh
    for dir in examples/*/; do
        name=$(basename "$dir")
        [ "$name" = "lib" ] && continue
        echo "Building examples/$name..."
        c3c build "examples/$name" || exit 1
    done

format:
    c3fmt --in-place .

# Regenerate examples/* targets in project.json (edit scripts/gen_targets.py OVERRIDES first)
gen-targets:
    python3 scripts/gen_targets.py

# Regenerate the character-width tables in xray/width.c3 and glaze/style.c3
# from Unicode data (edit scripts/gen_width.py first)
gen-width:
    python3 scripts/gen_width.py

# Measure mouse-move-to-frame latency in a GUI example with fake input
# (MILKTEA_FAKE_INPUT; the real pointer is not touched). y is the row swept,
# in points from the top of the window.
latency target="dos-app-gui" y="8" ms="4000" hz="120":
    c3c build examples/{{target}}
    MILKTEA_DEBUG_LATENCY=1 MILKTEA_FAKE_INPUT="wait 300; sweep {{y}} 5 235 {{ms}} {{hz}}; quit" ./out/examples/{{target}}

# The same through the WindowServer, with real events (moves the real cursor).
latency-real target="dos-app-gui" seconds="6" hz="120":
    c3c build examples/{{target}}
    mkdir -p build
    cc -O2 -o build/latency-mover scripts/latency/mover.c -framework ApplicationServices
    MILKTEA_DEBUG_LATENCY=1 ./out/examples/{{target}} & app=$!; \
        build/latency-mover $app {{seconds}} {{hz}}; \
        kill $app; wait $app 2>/dev/null || true
