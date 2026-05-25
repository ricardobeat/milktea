# Build the tea static library
build:
    c3c build tea

# Build all example programs
examples:
    #!/usr/bin/env sh
    for dir in examples/*/; do
        name=$(basename "$dir")
        echo "Building $name..."
        c3c build "$name" || exit 1
    done

format:
    c3fmt --in-place .
