#!/bin/bash
# Copy the prepared recordings in from the source research repository.
#
#   bash scripts/setup_data.sh /path/to/brainphysio_celia
#
# These are de-identified 100 Hz ICU recordings. They are gitignored here on purpose —
# see the PRIVACY section of README.md before committing them.
set -eu
SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: bash scripts/setup_data.sh /path/to/brainphysio_celia"; exit 1; }
FROM="$SRC/data/jugular_prepared"
[ -d "$FROM" ] || { echo "not found: $FROM"; exit 1; }
DST="$(cd "$(dirname "$0")/.." && pwd)/data/jugular_prepared"
mkdir -p "$DST"
cp "$FROM"/*.csv "$FROM"/events.jl "$FROM"/events.json "$DST/"
echo "copied $(ls "$DST" | wc -l) files ($(du -sh "$DST" | cut -f1)) -> data/jugular_prepared/"
echo "next: julia --project=. model/api_spec.jl"
