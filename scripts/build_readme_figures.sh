#!/usr/bin/env bash
# Render the README's diagrams: figures/readme/pages.typ -> figures/readme/<name>.svg.
# The figures are defined once in figures/readme/figs.typ (also used by
# reports/readme_diagrams.typ). Needs typst >= 0.13; fletcher is fetched on first run.
set -euo pipefail
cd "$(dirname "$0")/../figures/readme"

# One name per page of pages.typ, in order.
NAMES=(pipeline bounds identifiability circuit weight attribution estimators)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
typst compile --format svg pages.typ "$tmp/page-{n}.svg"

n=$(ls "$tmp" | wc -l)
if [ "$n" -ne "${#NAMES[@]}" ]; then
  echo "pages.typ produced $n pages but NAMES lists ${#NAMES[@]}; update one to match" >&2
  exit 1
fi
for i in "${!NAMES[@]}"; do
  mv "$tmp/page-$((i + 1)).svg" "${NAMES[$i]}.svg"
  echo "figures/readme/${NAMES[$i]}.svg"
done
