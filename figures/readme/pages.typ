// pages.typ — one README figure per auto-sized page. Do not compile directly; run
//   bash scripts/build_readme_figures.sh
// which renders each page to SVG and names it. The page order here is the NAMES order there.
#import "figs.typ": *

#set page(width: auto, height: auto, margin: 12pt, fill: white)
#set text(size: 9.5pt, lang: "en")
#set par(justify: false)

#fig-pipeline
#pagebreak()
#fig-bounds
#pagebreak()
#stack(dir: ttb, spacing: 14pt, fig-window, fig-collapse)
#pagebreak()
#stack(dir: ttb, spacing: 10pt, fig-circuit, align(center, fig-circuit-key))
#pagebreak()
#fig-weight
#pagebreak()
#fig-ladder
#pagebreak()
#fig-speed
