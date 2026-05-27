#!/bin/bash
# memprofile.sh - Graph and summarize a profile.log file
#
# Usage:
#   ./memprofile.sh [profile_log_path]
#
# Examples:
#   ./memprofile.sh                    # reads ./profile.log
#   ./memprofile.sh path/to/profile.log

set -euo pipefail

PROFILE_LOG="${1:-profile.log}"

if [ ! -f "$PROFILE_LOG" ]; then
    echo "Error: $PROFILE_LOG not found." >&2
    exit 1
fi

LINES=$(wc -l < "$PROFILE_LOG" | tr -d ' ')
if [ "$LINES" -lt 2 ]; then
    echo "Error: $PROFILE_LOG has no frame data." >&2
    exit 1
fi

echo "Captured $LINES frame samples."
echo ""

# ── Summary Stats ────────────────────────────────────────────────────────
echo "=== Memory Profile Summary ==="
awk -F',' '
NR==1 { next }
{
    frames++
    qjs_used = $2
    qjs_obj = $3
    qjs_str = $4
    shim_a = $5
    shim_f = $6
    shim_b = $7
    rss = $8

    if (frames == 1) {
        first_qjs = qjs_used; first_rss = rss; first_shim_a = shim_a; first_shim_f = shim_f
        min_qjs = qjs_used; max_qjs = qjs_used
        min_rss = rss; max_rss = rss
    }
    sum_qjs += qjs_used; sum_rss += rss
    if (qjs_used < min_qjs) min_qjs = qjs_used
    if (qjs_used > max_qjs) max_qjs = qjs_used
    if (rss < min_rss) min_rss = rss
    if (rss > max_rss) max_rss = rss
    last_qjs = qjs_used; last_rss = rss; last_shim_a = shim_a; last_shim_f = shim_f
    last_obj = qjs_obj; last_str = qjs_str
}
END {
    avg_qjs = sum_qjs / frames
    avg_rss = sum_rss / frames
    printf "  Frames:           %d\n", frames
    printf "  QJS heap (first): %d bytes (%.1f KB)\n", first_qjs, first_qjs/1024
    printf "  QJS heap (last):  %d bytes (%.1f KB)\n", last_qjs, last_qjs/1024
    printf "  QJS heap (min):   %d bytes (%.1f KB)\n", min_qjs, min_qjs/1024
    printf "  QJS heap (max):   %d bytes (%.1f KB)\n", max_qjs, max_qjs/1024
    printf "  QJS heap (avg):   %d bytes (%.1f KB)\n", avg_qjs, avg_qjs/1024
    printf "  QJS objects:      %d\n", last_obj
    printf "  QJS strings:      %d\n", last_str
    printf "  Process RSS (first): %d KB\n", first_rss
    printf "  Process RSS (last):  %d KB\n", last_rss
    printf "  Process RSS (min):   %d KB\n", min_rss
    printf "  Process RSS (max):   %d KB\n", max_rss
    printf "  Process RSS (avg):   %d KB\n", avg_rss
    printf "  Shim mallocs:     %d (net: %+d)\n", last_shim_a, last_shim_a - last_shim_f
    printf "  Leakage check:    heap_d=%.1f%%, rss_d=%.1f%%\n",
        (first_qjs > 0 ? (last_qjs - first_qjs) * 100.0 / first_qjs : 0),
        (first_rss > 0 ? (last_rss - first_rss) * 100.0 / first_rss : 0)
}
' "$PROFILE_LOG"
echo ""

# ── ASCII Graph ──────────────────────────────────────────────────────────
echo "=== QJS Heap Usage Over Time ==="
awk -F',' '
BEGIN {
    W = 60  # graph width in chars
    H = 15  # graph height in chars
}
NR==1 { next }
{
    frames++
    val[frames] = $2 + 0  # qjs_memory_used
    rss[frames] = $8 + 0  # process RSS
}
END {
    if (frames == 0) exit

    # Find min/max for QJS heap
    min_v = val[1]; max_v = val[1]
    for (i = 2; i <= frames; i++) {
        if (val[i] < min_v) min_v = val[i]
        if (val[i] > max_v) max_v = val[i]
    }
    # Add 5% padding
    range = max_v - min_v
    if (range == 0) range = 1
    min_v = min_v - range * 0.05
    max_v = max_v + range * 0.05
    if (min_v < 0) min_v = 0

    # Downsample to W columns
    step = frames / W
    if (step < 1) step = 1

    # Build graph rows
    for (row = H; row >= 1; row--) {
        threshold = min_v + (max_v - min_v) * (row / H)
        line = ""
        for (col = 1; col <= W; col++) {
            idx = int((col - 1) * step) + 1
            if (idx > frames) idx = frames
            if (val[idx] >= threshold) {
                line = line "#"
            } else {
                line = line " "
            }
        }
        if (row == H || row == int(H/2) || row == 1) {
            printf "%10s |%s\n", sprintf("%.0f", threshold), line
        } else {
            printf "%10s |%s\n", "", line
        }
    }
    # X axis
    sep = ""
    for (i = 0; i < W; i++) sep = sep "-"
    printf "%10s +%s\n", "", sep
    printf "%10s  frame 1%*sframe %d\n", "", W - 12, "", frames
}
' "$PROFILE_LOG"

echo ""
echo "=== Process RSS Over Time ==="
awk -F',' '
BEGIN {
    W = 60
    H = 12
}
NR==1 { next }
{
    frames++
    val[frames] = $8 + 0  # RSS in KB
}
END {
    if (frames == 0) exit

    min_v = val[1]; max_v = val[1]
    for (i = 2; i <= frames; i++) {
        if (val[i] < min_v) min_v = val[i]
        if (val[i] > max_v) max_v = val[i]
    }
    range = max_v - min_v
    if (range == 0) range = 1
    min_v = min_v - range * 0.05
    max_v = max_v + range * 0.05
    if (min_v < 0) min_v = 0

    step = frames / W
    if (step < 1) step = 1

    for (row = H; row >= 1; row--) {
        threshold = min_v + (max_v - min_v) * (row / H)
        line = ""
        for (col = 1; col <= W; col++) {
            idx = int((col - 1) * step) + 1
            if (idx > frames) idx = frames
            if (val[idx] >= threshold) {
                line = line "."
            } else {
                line = line " "
            }
        }
        if (row == H || row == int(H/2) || row == 1) {
            printf "%8s KB |%s\n", sprintf("%.0f", threshold), line
        } else {
            printf "%8s   |%s\n", "", line
        }
    }
    sep = ""
    for (i = 0; i < W; i++) sep = sep "-"
    printf "%8s   +%s\n", "", sep
}
' "$PROFILE_LOG"
