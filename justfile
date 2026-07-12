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
