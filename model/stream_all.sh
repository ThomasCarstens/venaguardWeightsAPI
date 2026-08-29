#!/bin/bash
# Refit every patient in parallel and stream the six API parameters.
#   bash model/stream_all.sh [nwin] [iters]
# Each window is ~76 solves (~4 min), so 16 windows is ~65 min per patient; the four run
# concurrently. Streams are flushed per window, so the API serves partial results live.
set -u
cd "$(dirname "$0")/.." || exit 1
NWIN=${1:-16}; ITERS=${2:-45}
mkdir -p api
for p in 081 083 137 150; do
    _PATIENT=$p _NWIN=$NWIN _WIN_ITERS=$ITERS \
        julia --project=. model/stream_refit.jl > api/refit_$p.log 2>&1 &
done
wait
echo "=== all four done $(date +%H:%M) ==="
