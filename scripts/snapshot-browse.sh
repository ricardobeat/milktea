#!/bin/sh
# Browse snapshot files with fzf and render ANSI preview.
# Usage: ./scripts/snapshot-browse.sh [snapshots/dir]

SNAP_DIR="${1:-snapshots}"

find "$SNAP_DIR" -name '*.snap' -type f | sort | \
  fzf --preview="sed 's/\x1b\[[0-9;]*[HJ]//g' {}" \
      --preview-window='right:60%:wrap' \
      --bind='ctrl-/:toggle-preview' \
      --header='snapshots — ctrl-/ to toggle preview'
