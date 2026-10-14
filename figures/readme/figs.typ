// figs.typ — the README's diagrams, defined once.
//
// Imported by pages.typ (one figure per auto-sized page -> the SVGs README.md embeds; build
// with scripts/build_readme_figures.sh) and by reports/readme_diagrams.typ (the PDF).
// House colours and fletcher idiom of brainphysio_celia/reports/el-kamouh-report.
//
// Every number was read off api/ on 2026-10-14, not typed from memory:
//   - bounds:              api/params/<id>.json
//   - 137 latest values:   GET /latest/137
//   - 137 weights:         last line of api/stream/137/_components.jsonl
//   - interval collapse:   api/stream/081/craniospinal_compliance.jsonl
// After a refit, re-read them; nothing here regenerates itself.

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

// ── house colours (el-kamouh-report/report.typ) ─────────────────────────────
#let C = (
  navy: rgb("#14213D"), rust: rgb("#C4572F"), green: rgb("#2E7D4F"),
  blue: rgb("#2B5C8A"), purple: rgb("#5E4B8B"), grey: rgb("#5A6069"),
  card: rgb("#F1F4F8"),
)
#let csf = rgb("#2d40bd")
#let ven = rgb("#db2777")
#let ink = rgb("#1a1a1a")
#let muted = rgb("#5c5c5c")
#let healthy-f = rgb("#e3f1e8")
#let border-f = rgb("#fbf0dc")
#let patho-f = rgb("#f8e1d9")
#let mono = "DejaVu Sans Mono"

// provenance → colour; the one distinction the README insists on
#let prov-col = (clinical: C.green, model: C.purple, qc: C.rust)
#let prov(p) = box(stroke: 1pt + prov-col.at(p), inset: (x: 4pt, y: 2pt), radius: 1pt,
  text(7.5pt, fill: prov-col.at(p), weight: "bold")[#p])

#let small(body) = text(7.5pt, fill: muted)[#body]
#let card(body, fill: C.card, stroke: none) = block(fill: fill, stroke: stroke, inset: 8pt,
  radius: 3pt, width: 100%, body)

// fletcher shorthands
#let box-node(pos, body, fill: C.card, stroke: C.grey, ..rest) = node(pos, align(center, body),
  shape: rect, fill: fill, stroke: 0.8pt + stroke, corner-radius: 4pt, inset: 6pt, ..rest)
#let file-node(pos, body) = node(pos, align(center, text(7.5pt, font: mono)[#body]),
  shape: rect, fill: white, stroke: (paint: C.grey, thickness: 0.7pt, dash: "dashed"), inset: 5pt)
#let arr(..args, colour: ink) = edge(..args, "-|>", stroke: 0.9pt + colour)

// ═════════════════════════════════════════════════════════════════════════════
// 1 · pipeline
#let fig-pipeline = diagram(spacing: (16pt, 22pt), node-stroke: 0.8pt, {
  box-node((0, 0), [*ICU recording* \ #small[100 Hz ICP, ABP, TCD, CO₂ \ `data/` (gitignored)]],
    fill: white)
  box-node((0, 1.4), [*`stream_refit.jl`* \ #small[batch: refit all data up to `t_end` \ ≈65 min / patient]],
    fill: rgb("#e6ecf4"), stroke: C.blue)
  box-node((1.7, 1.4), [*`stream_filter.jl`* \ #small[sequential filter, 1 Hz \ ≈4.5× faster than real time]],
    fill: rgb("#e6ecf4"), stroke: C.blue)
  file-node((0.6, 2.7), [api/stream/\<patient\>/\<id\>.jsonl \ #text(fill: C.rust)[one per parameter · appended + flushed]])
  box-node((0.6, 3.9), [*`translate_stream.py`* \ #small[pure post-processing, ≈1 s \ `scripts/circuit.py` holds the logic]],
    fill: rgb("#e8f2ec"), stroke: C.green)
  file-node((0.6, 5.0), [api/stream/\<patient\>/\_components.jsonl \ api/circuit.json · api/components/\<id\>.json])

  box-node((-1.6, 2.7), [*`api_spec.jl`* \ #small[instant]], fill: rgb("#efeaf5"), stroke: C.purple)
  file-node((-1.6, 3.9), [api/params/\<id\>.json \ api/index.json])

  box-node((-0.5, 6.3), [*`serve_api.py`* · :8770 \ #small[stdlib only · threaded · reads `api/` at request time]],
    fill: C.navy.lighten(88%), stroke: C.navy)
  box-node((-1.6, 7.4), [`/dashboard` \ #small[one window per patient]], fill: white)
  box-node((-0.5, 7.4), [`curl` / `?since=` poll], fill: white)
  box-node((0.6, 7.4), [`stream_explorer.ipynb`], fill: white)

  arr((0, 0), (0, 1.4)); arr((0, 0), (1.7, 1.4))
  arr((0, 1.4), (0.6, 2.7), colour: C.blue); arr((1.7, 1.4), (0.6, 2.7), colour: C.blue)
  edge((0, 1.4), (1.7, 1.4), "<|-|>", stroke: (paint: C.rust, thickness: 0.8pt, dash: "dashed"),
    label: box(fill: white, inset: 1pt, text(6.5pt, fill: C.rust)[never both \ on one patient]), label-side: center)
  arr((0.6, 2.7), (0.6, 3.9), colour: C.green); arr((0.6, 3.9), (0.6, 5.0), colour: C.green)
  arr((-1.6, 2.7), (-1.6, 3.9), colour: C.purple)
  arr((-1.6, 3.9), (-0.5, 6.3), colour: C.navy)
  arr((0.6, 5.0), (-0.5, 6.3), colour: C.navy)
  arr((0.6, 2.7), (-0.5, 6.3), colour: C.navy, bend: -30deg)
  arr((-0.5, 6.3), (-1.6, 7.4)); arr((-0.5, 6.3), (-0.5, 7.4)); arr((-0.5, 6.3), (0.6, 7.4))
})

// ═════════════════════════════════════════════════════════════════════════════
// 2 · six parameters on a severity-scaled axis
// Piecewise-linear map value → [0,1]: lo_p→.2, lo_h→.4, hi_h→.6, hi_p→.8, extrapolated
// with the adjacent span beyond, clipped to the strip.
#let sx(v, b) = {
  let (lp, lh, hh, hp) = b
  let s = if v < lh { -(lh - v) / (lh - lp) } else if v > hh { (v - hh) / (hp - hh) } else { (v - lh) / (hh - lh) - 0.5 }
  // inside the healthy band s ∈ [-0.5, 0.5] is a position, not a severity
  let x = if v < lh { 0.4 + 0.2 * s } else if v > hh { 0.6 + 0.2 * s } else { 0.5 + 0.2 * s }
  calc.max(0.0, calc.min(1.0, x))
}
#let BW = 255pt
#let strip(b, v, lo, hi, ident: true) = box(width: BW, height: 22pt, {
  let zone(a, z, f) = place(dx: a * BW, dy: 5pt, rect(width: (z - a) * BW, height: 12pt, fill: f, stroke: none))
  zone(0, 0.2, patho-f); zone(0.2, 0.4, border-f); zone(0.4, 0.6, healthy-f)
  zone(0.6, 0.8, border-f); zone(0.8, 1.0, patho-f)
  for (i, x) in (0.2, 0.4, 0.6, 0.8).enumerate() {
    place(dx: x * BW, dy: 3pt, line(length: 16pt, angle: 90deg, stroke: 0.5pt + C.grey))
    place(dx: x * BW - 15pt, dy: 18pt, box(width: 30pt, align(center, text(6pt, fill: muted)[#b.at(i)])))
  }
  let (xl, xh, xv) = (sx(lo, b), if hi == none { 1.0 } else { sx(hi, b) }, sx(v, b))
  let col = if ident { ink } else { C.grey }
  place(dx: xl * BW, dy: 10.5pt, line(length: calc.max(xh - xl, 0.004) * BW, stroke: (paint: col, thickness: 1.6pt, dash: if ident { none } else { "dotted" })))
  place(dx: xv * BW - 3pt, dy: 8pt, circle(radius: 3pt, fill: if ident { C.rust } else { white }, stroke: 1pt + col))
  if xv >= 1.0 or xv <= 0.0 { place(dx: xv * BW + (if xv >= 1.0 { 4pt } else { -9pt }), dy: 5pt, text(8pt, fill: col)[#if xv >= 1.0 [▸] else [◂]]) }
})
#let prow(id, unit, p, b, v, lo, hi, status, ident: true) = (
  [#text(8pt, font: mono)[#id] \ #small[#unit]],
  prov(p),
  strip(b, v, lo, hi, ident: ident),
  [#text(8pt)[*#v*] \ #small[#status]],
)
#let fig-bounds = grid(columns: (auto, auto, auto, auto), column-gutter: 8pt, row-gutter: 9pt, align: horizon,
  [], [], box(width: BW, text(6.5pt, fill: muted)[
    #h(0.02 * BW)pathological #h(1fr) borderline #h(1fr) *healthy* #h(1fr) borderline #h(1fr) pathological]), [],
  ..prow("craniospinal_compliance", [mL/mmHg], "clinical", (0.1, 0.5, 1.1, 2.0), 0.2309, 0.2009, 0.2654, "borderline"),
  ..prow("csf_outflow_resistance", [mmHg/(mL/min)], "clinical", (3.0, 6.0, 10.0, 18.0), 0.9406, 0.8924, 0.9914, "pathological"),
  ..prow("sagittal_sinus_pressure", [mmHg], "clinical", (2.0, 5.0, 8.0, 15.0), 8.073, 7.997, 8.149, "borderline"),
  ..prow("arterial_compliance", [mL/mmHg], "model", (0.005, 0.015, 0.05, 0.1), 0.00611, 0.00521, 0.00716, "borderline"),
  ..prow("collateral_outflow_resistance", [mmHg·s/mL], "model", (0.01, 0.02, 0.2, 2.0), 12.11, 1.594, 91.96, "unidentifiable", ident: false),
  ..prow("jugular_resting_area", [cm² per vein], "qc", (0.3, 0.8, 2.0, 4.0), 4.465, 3.855, 5.171, "pathological"),
  [], [], box(width: BW, text(6.5pt, fill: muted)[
    #box(baseline: 1pt, circle(radius: 3pt, fill: C.rust, stroke: 1pt + ink)) identifiable, 95 % interval as a bar
    #h(6pt) #box(baseline: 1pt, circle(radius: 3pt, fill: white, stroke: 1pt + C.grey)) unidentifiable
    #h(6pt) ▸ beyond the drawn range]), [],
)

// ═════════════════════════════════════════════════════════════════════════════
// 3 · the expanding window, and 081's interval collapsing once the manoeuvre is in it
#let TW = 470pt
#let tx(t) = (t + 70) / 400 * TW
#let fig-window = box(width: TW, height: 80pt, {
  for (i, te) in (-60, -16.22, 49.46, 137.02, 268.37).enumerate() {
    place(dx: tx(-60), dy: i * 11pt, rect(width: tx(te) - tx(-60), height: 6pt,
      fill: if te < 0 { C.grey.lighten(60%) } else { C.blue.lighten(45%) }, stroke: none))
    place(dx: calc.max(tx(te), tx(0)) + 4pt, dy: i * 11pt - 1pt, text(6.5pt, fill: muted)[$t_"end"$ = #te s])
  }
  place(dx: tx(0), dy: -4pt, line(length: 60pt, angle: 90deg, stroke: (paint: C.rust, thickness: 1pt, dash: "dashed")))
  place(dx: tx(0) - 40pt, dy: 58pt, text(7pt, fill: C.rust, weight: "bold")[jugular compression, t = 0])
  place(dx: 0pt, dy: 70pt, text(7pt, fill: muted)[baseline only: the venous path is invisible])
  place(dx: tx(150), dy: 70pt, text(7pt, fill: C.blue)[manoeuvre inside the window: information arrives])
})

#let CW = 420pt
#let CH = 120pt
#let cx(t) = (t + 70) / 350 * CW
#let cy(v) = CH - v / 1.4 * CH
#let ci081 = (
  (-60.0, 0.1399, 0.0146, 1.3427), (-38.11, 0.2418, 0.0290, 2.0166), (-16.22, 0.2415, 0.0729, 0.7996),
  (5.67, 0.2413, 0.1573, 0.3703), (27.57, 0.2408, 0.1649, 0.3515), (49.46, 0.2401, 0.1684, 0.3422),
  (71.35, 0.2380, 0.2139, 0.2649), (93.24, 0.2368, 0.2185, 0.2567), (115.13, 0.2353, 0.2252, 0.2459),
  (137.02, 0.2327, 0.2225, 0.2434), (158.91, 0.2294, 0.2060, 0.2555), (180.8, 0.2261, 0.2029, 0.2520),
  (202.7, 0.2261, 0.2041, 0.2504), (224.59, 0.2261, 0.2048, 0.2496), (246.48, 0.2261, 0.2051, 0.2492),
  (268.37, 0.2261, 0.2053, 0.2490),
)
#let fig-collapse = box(width: CW + 40pt, height: CH + 40pt, inset: (left: 34pt, top: 16pt), {
  place(dx: 0pt, dy: cy(1.1), rect(width: CW, height: cy(0.5) - cy(1.1), fill: healthy-f, stroke: none))
  place(dx: CW - 70pt, dy: cy(0.85), text(7pt, fill: C.green)[healthy 0.5–1.1])
  place(dx: cx(0), dy: 0pt, line(length: CH, angle: 90deg, stroke: (paint: C.rust, thickness: 0.8pt, dash: "dashed")))
  place(dx: 0pt, dy: CH, line(length: CW, stroke: 0.6pt + muted))
  place(dx: 0pt, dy: 0pt, line(length: CH, angle: 90deg, stroke: 0.6pt + muted))
  for v in (0, 0.5, 1.0) { place(dx: -22pt, dy: cy(v) - 4pt, text(6.5pt, fill: muted)[#v]) }
  for t in (-60, 0, 100, 200) { place(dx: cx(t) - 8pt, dy: CH + 3pt, text(6.5pt, fill: muted)[#t s]) }
  place(dx: -34pt, dy: -12pt, text(7pt, fill: muted)[patient 081 · craniospinal_compliance, mL/mmHg · 95 % interval per window])
  for (t, v, lo, hi) in ci081 {
    let id = t > 0
    let top = calc.min(hi, 1.4)
    let col = if id { C.navy } else { C.grey }
    place(dx: cx(t), dy: cy(top), line(length: cy(lo) - cy(top), angle: 90deg,
      stroke: (paint: col, thickness: 2pt, dash: if id { none } else { "dotted" })))
    if hi > 1.4 { place(dx: cx(t) - 3pt, dy: -6pt, text(7pt, fill: col)[▴]) }
    place(dx: cx(t) - 2.2pt, dy: cy(v) - 2.2pt, circle(radius: 2.2pt, fill: if id { C.rust } else { white }, stroke: 0.8pt + col))
  }
})

// ═════════════════════════════════════════════════════════════════════════════
// 4 · the circuit, weights from patient 137's last window
#let comp(pos, name, label, param: none, w: none, attr: none, panel: none, colour: C.navy) = {
  let obs = param != none
  node(pos, align(center, {
    text(7.5pt, weight: "bold", fill: if obs { colour } else { muted })[#label]
    linebreak()
    text(6.2pt, font: mono, fill: muted)[#name]
    if obs [ \ #text(6.5pt, fill: colour)[#param] \ #text(8pt, weight: "bold")[w = #w] #text(6pt, fill: muted)[#attr]]
    if panel != none [ \ #text(6pt, fill: C.blue, style: "italic")[#panel]]
  }), shape: rect, corner-radius: 4pt, inset: 5pt,
    fill: if obs { colour.lighten(88%) } else { white },
    stroke: if obs { 1.2pt + colour } else { (paint: muted, thickness: 0.6pt, dash: "dashed") })
}
#let iface(verts, name, colour, param: none, w: none, attr: none, ..rest) = {
  let obs = param != none
  edge(..verts, "-|>", ..rest,
    stroke: if obs { 2pt + colour } else { (paint: colour.lighten(40%), thickness: 0.8pt, dash: "dashed") },
    label: box(fill: white, inset: 1.5pt, align(center, {
      text(6pt, font: mono, fill: if obs { colour } else { muted })[#name]
      if obs [ \ #text(6.3pt, fill: colour)[#param] \ #text(7.5pt, weight: "bold")[w = #w] #text(6pt, fill: muted)[#attr]]
    })), label-sep: 1pt)
}
#let fig-circuit = diagram(spacing: (30pt, 22pt), mark-scale: 70%, {
  comp((0, 0), "cerebral_arterial", [Cerebral arterial bed], param: "arterial_compliance", w: "0.84", attr: "model_ref.", colour: C.purple)
  comp((2, 0), "cerebral_venous", [Cerebral venous])
  comp((4, 0), "dural_sinus", [Dural venous sinus], param: "sagittal_sinus_pressure", w: "0.01", attr: "patient", panel: "heart panel", colour: ven)
  comp((6, 0), "jugular_bulb", [Jugular bulb])
  comp((8, 0), "systemic_venous", [Systemic venous], panel: "heart panel")
  comp((2, -1.7), "intracranial_csf", [Intracranial CSF / brain], param: "craniospinal_compliance", w: "0.60", attr: "patient", panel: "heart panel", colour: csf)
  comp((2, 3.2), "spinal_dural_sac", [Spinal dural sac], param: "craniospinal_compliance", w: "0.60", attr: "patient", panel: "spine panel", colour: csf)
  comp((6, 1.6), "vertebral_plexus", [Vertebral venous plexus], panel: "spine panel")
  comp((6, 3.2), "paravertebral", [Paravertebral / azygos], panel: "spine panel")

  iface(((0, 0), (2, 0)), "arteriolar_bed", ven, bend: 25deg)
  iface(((0, 0), (2, 0)), "capillary_bed", ven, bend: -25deg)
  iface(((2, 0), (4, 0)), [cerebral_venous\_ \ outflow], ven, label-side: center)
  iface(((4, 0), (6, 0)), "sinus_to_jugular", ven)
  iface(((6, 0), (8, 0)), "internal_jugular", C.rust, param: "jugular_resting_area", w: "0.00", attr: "fit_quality")
  iface(((2, -1.7), (4, 0)), "csf_absorption_cranial", csf, param: "csf_outflow_resistance", w: "1.64", attr: "patient")
  iface(((2, -1.7), (-1, -1.7), (-1, 3.2), (2, 3.2)), "craniospinal_csf_channel", csf, label-pos: 0.5)
  iface(((2, 3.2), (6, 3.2)), "csf_absorption_spinal", csf, param: "csf_outflow_resistance", w: "1.64", attr: "patient")
  iface(((6, 0), (6, 1.6)), "vertebral_collateral", C.purple, param: "collateral_outflow_res.", w: "0.00", attr: "unidentif.")
  iface(((6, 1.6), (6, 3.2)), "plexus_drainage", ven)
  iface(((6, 1.6), (8, 0)), "plexus_shunt", ven)
  iface(((6, 3.2), (8, 3.2), (8, 0)), "azygos_return", ven, label-pos: 0.75)
})
#let fig-circuit-key = text(7pt, fill: muted)[
  #box(width: 18pt, line(length: 18pt, stroke: 2pt + csf)) #h(2pt) observable, with patient 137's weight
  #h(14pt)
  #box(width: 18pt, line(length: 18pt, stroke: (paint: muted, thickness: 0.8pt, dash: "dashed"))) #h(2pt)
  fixed at a model default: *NOT ESTIMATED, never "normal"* (13 of 21)
  #h(14pt) colours: #text(fill: csf)[CSF] · #text(fill: ven)[blood] · #text(fill: C.rust)[qc] · #text(fill: C.purple)[model-referenced]
]

// ═════════════════════════════════════════════════════════════════════════════
// 5 · from a parameter to a weight (137, csf_outflow_resistance → csf_absorption_cranial)
#let fig-weight = diagram(spacing: (14pt, 18pt), {
  box-node((0, 0), [*value* \ #small[0.9406]], fill: white)
  box-node((0, 1.3), [*4 bounds* \ #small[3 · 6 · 10 · 18]], fill: white)
  box-node((0, 2.6), [*95 % interval* \ #small[\[0.892, 0.991\]]], fill: white)
  box-node((2, 0.65), [*severity* \ #small[signed distance from the healthy edge \ in units of healthy edge → pathological bound] \ $-(6 - 0.9406)/(6 - 3) = bold(-1.687)$],
    fill: border-f, stroke: C.rust)
  box-node((2, 2.6), [*confidence* \ #small[1 − (CI width ÷ healthy band width), clipped to \[0, 1\] \ 0 if `identifiable` is false] \ $1 - 0.099\/4 = bold(0.975)$],
    fill: rgb("#e6ecf4"), stroke: C.blue)
  box-node((4, 1.6), [*weight* \ $|"sev"| times "conf"$ \ #text(12pt, weight: "bold", fill: C.rust)[1.645] \ #small[largest among a component's \ governing parameters, *not* the sum]],
    fill: patho-f, stroke: C.rust)
  arr((0, 0), (2, 0.65)); arr((0, 1.3), (2, 0.65)); arr((0, 1.3), (2, 2.6)); arr((0, 2.6), (2, 2.6))
  arr((2, 0.65), (4, 1.6), colour: C.rust); arr((2, 2.6), (4, 1.6), colour: C.blue)
})

// ═════════════════════════════════════════════════════════════════════════════
// 6 · the attribution ladder (scripts/circuit.py, translate(): first match wins)
#let rung(cond, attr, colour, ex) = (
  text(8pt)[#cond],
  sym.arrow.r,
  box(fill: colour.lighten(85%), stroke: 1pt + colour, inset: (x: 5pt, y: 3pt), radius: 2pt,
    text(8pt, font: mono, fill: colour, weight: "bold")[#attr]),
  small(ex),
)
#let fig-ladder = block(width: 520pt, grid(columns: (1.6fr, auto, auto, 1.2fr), column-gutter: 8pt, row-gutter: 7pt,
  align: (left + horizon, center + horizon, left + horizon, left + horizon),
  text(7pt, fill: muted, weight: "bold")[CHECKED TOP-DOWN · FIRST MATCH WINS], [], [], text(7pt, fill: muted, weight: "bold")[EXAMPLE],
  ..rung([no governing parameter identifiable in this window], "unidentifiable", C.grey, [137 `vertebral_collateral`]),
  ..rung([*R1 fired* (collateral AND jugular both pathological) and the component is `internal_jugular` / `vertebral_collateral`], "model_artifact", C.rust, [tube-law escape: the fit inflated the jugular and blocked the collateral]),
  ..rung([a governing bound is `qc`], "fit_quality", C.rust, [137 `internal_jugular`]),
  ..rung([*R6 fired* (CSF outflow resistance AND compliance both pathological) and the component is CSF], "degenerate", C.purple, [$E$ and $R_"o,tot"$ trade off along a valley: read the pair as one finding]),
  ..rung([a governing bound is `model`], "model_referenced", C.purple, [137 `cerebral_arterial`]),
  ..rung([otherwise: clinical bounds, identifiable], "patient", C.green, [137 `csf_absorption_cranial`: the only rung that is about the patient]),
))

// ═════════════════════════════════════════════════════════════════════════════
// 7 · the two estimators against real time
#let SW = 300pt
#let speed(label, factor, colour, note) = grid(columns: (80pt, SW, 150pt), column-gutter: 6pt, align: horizon,
  text(8pt, weight: "bold", fill: colour)[#label],
  box(width: SW, height: 10pt, {
    place(rect(width: factor / 11.5 * SW, height: 10pt, fill: colour.lighten(30%), stroke: none))
    place(dx: SW / 11.5, dy: -3pt, line(length: 16pt, angle: 90deg, stroke: (paint: C.rust, thickness: 1pt, dash: "dashed")))
  }),
  text(7.5pt)[#note])
#let fig-speed = block(width: 550pt, {
  text(8pt, weight: "bold")[Compute time per second of recording]
  h(4pt)
  small[(dashed line: real time, 1 s per s)]
  v(2pt)
  speed("stream_refit.jl", 11, C.blue, [≈11 s: falls behind · *the reference*])
  v(1pt)
  speed("stream_filter.jl", 1 / 4.5, C.green, [≈0.22 s: runs ahead · *deployable*])
})
