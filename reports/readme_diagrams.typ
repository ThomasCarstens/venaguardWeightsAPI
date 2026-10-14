// =============================================================================
//  readme_diagrams.typ — README.md as a set of diagrams, with real outputs at the
//  places a reader most needs to see one.
//
//  Compile:   typst compile --root . reports/readme_diagrams.typ   (from the repo root)
//  Style:     house colours and fletcher idiom of
//             brainphysio_celia/reports/el-kamouh-report (report.typ, model98_firstpass.typ).
//
//  Every number below was read off api/ on 2026-10-14, not typed from memory:
//    - bounds:              api/params/<id>.json
//    - 137 latest values:   GET /latest/137
//    - 137 weights:         last line of api/stream/137/_components.jsonl
//    - interval collapse:   api/stream/081/{craniospinal_compliance,jugular_resting_area}.jsonl
//  After a refit, re-read them; nothing here regenerates itself.
// =============================================================================

#import "/figures/readme/figs.typ": *

#set page(paper: "a4", margin: (x: 1.5cm, y: 1.5cm),
  footer: context align(right, text(7.5pt, fill: rgb("#5A6069"))[icp-parameter-api · README in diagrams · #counter(page).display()]))
#set text(size: 9.5pt, lang: "en")
#set par(justify: false)
#show raw: set text(size: 8pt)
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  block(below: 0.9em, text(15pt, fill: rgb("#14213D"), weight: "bold", it.body))
}
#show heading.where(level: 2): set text(11pt, fill: rgb("#2B5C8A"))

// A real output, labelled with where it came from.
#let example(src, body) = block(breakable: false, width: 100%, {
  text(7.5pt, fill: C.blue, weight: "bold")[EXAMPLE OUTPUT]
  h(4pt)
  small(src)
  v(-4pt)
  block(fill: rgb("#f7f7f5"), stroke: (left: 2pt + C.blue), inset: 7pt, width: 100%, body)
})
#let warn(body) = card(fill: patho-f, stroke: (left: 2.5pt + C.rust))[#text(fill: C.rust, weight: "bold")[⚠ ] #body]

// ─────────────────────────────────────────────────────────────────────────────
#align(center)[
  #text(20pt, weight: "bold", fill: C.navy)[ICP parameter API]
  #v(-6pt)
  #text(11pt, fill: C.grey)[the README, as diagrams]
]
#v(4pt)

Six physiologically interpretable parameters of cerebral CSF/venous dynamics, fitted from
an ICP recording and served over HTTP with confidence intervals and four bounds each, and
translated into weights on the parts of the circuit.
Extracted from `brainphysio_celia` (`Model_6`), 2026-08-26.

#v(4pt)
#card[
  #text(weight: "bold", fill: C.navy)[Read in this order.]
  #grid(columns: (auto, 1fr), column-gutter: 8pt, row-gutter: 5pt,
    [*1*], [The pipeline: what writes which file, what it costs.],
    [*2*], [The six parameters and their bounds, and which bounds you may show a clinician.],
    [*3*], [Why `identifiable` is the field to read first: the intervals collapse when the manoeuvre arrives.],
    [*4*], [The circuit: 21 components, only 8 of them observable.],
    [*5*], [From a parameter to a component weight, and the attribution ladder that says whether a weight is about the patient or the fit.],
    [*6*], [The two estimators.],
    [*7*], [Routes, setup, and the things that bite.],
  )
]

#v(6pt)
#warn[*Patient data is not in this repository.* `data/` is gitignored. Restore it with
`bash scripts/setup_data.sh /path/to/brainphysio_celia`. If you ever `git add -f data/`,
the repository must stay private.]

#v(4pt)
#warn[*There are no healthy controls.* All four recordings are ICU patients. Every
"healthy" bound below is from literature, not from a control group measured with this
pipeline. This is the weakest assumption in the project.]

// ═════════════════════════════════════════════════════════════════════════════
= 1 · The pipeline

#align(center, fig-pipeline)

#v(4pt)
#grid(columns: (1fr, 1fr), column-gutter: 10pt,
  card[
    #text(weight: "bold", fill: C.navy)[File-backed, so a refit is served live.]
    The estimator appends one JSON object per window and flushes. The server reads the
    file on each request, so `?since=<t>` returns only what is new, and a running server
    always serves current data. Re-running `translate_stream.py` never needs a refit.
  ],
  card(fill: patho-f)[
    #text(weight: "bold", fill: C.rust)[Two writers corrupt a stream.]
    Both estimators open the same `.jsonl` with `"w"`. Stream `083` was once truncated to
    0 records this way. If a stream shrinks or `t_end` jumps backwards, that is what
    happened (RULEBOOK R9).
  ],
)

#v(4pt)
#example[`python3 scripts/serve_api.py --check` · validates without serving, exit 1 if incoherent][
```
index: 6 params, 4 patients

  craniospinal_compliance          [0.1, 0.5, 1.1, 2.0]         [clinical]
  csf_outflow_resistance           [3.0, 6.0, 10.0, 18.0]       [clinical]
  arterial_compliance              [0.005, 0.015, 0.05, 0.1]    [model]
  collateral_outflow_resistance    [0.01, 0.02, 0.2, 2.0]       [model]
  jugular_resting_area             [0.3, 0.8, 2.0, 4.0]         [qc]
  sagittal_sinus_pressure          [2.0, 5.0, 8.0, 15.0]        [clinical]

  patient 081: 96 records
  ...
circuit: 9 compartments + 12 interfaces, 8 observable
  patient 137: 16 windows, lead csf_absorption_cranial w=1.64 (patient)   rules=-
```
]

// ═════════════════════════════════════════════════════════════════════════════
= 2 · Six parameters, four bounds each

Each parameter carries four bounds, which split its axis into five zones. Each also carries
a *provenance* tag that says how far the bounds can be trusted:

#grid(columns: (auto, 1fr), column-gutter: 8pt, row-gutter: 6pt,
  prov("clinical"), [a published human reference range for a directly measured quantity.],
  prov("model"), [*no* human range exists. The bounds are anchored on the source model's
    default, so they describe the model, not physiology. *Never present these to a
    clinician as normal ranges.*],
  prov("qc"), [a check on the fit, not a property of the patient. The fit drives the jugular
    to 5–12 cm² against a physiological 0.8–2.0. A value outside the band is evidence that
    the *fit* is wrong, and a bedside ultrasound falsifies it in thirty seconds.],
)

== The axis is drawn in severity units

Each bound sits one unit from the next, so the horizontal distance you see is the
`severity` that §5 turns into a weight. The values are patient *137*'s last window
($t_"end"$ = 268.6 s), with the Fisher 95 % interval as a bar.

#align(center, fig-bounds)

#small[Filled dot: identifiable estimate. Hollow dot, dotted bar: unidentifiable (its interval
runs from 1.6 to 92, past the right edge). ▸ marks a value beyond the drawn range.
`status` is computed from the zones; it is `unidentifiable` whenever the flag is false,
whatever zone the point estimate falls in.]

#example[`GET /latest/137` · one of six entries][
```json
"csf_outflow_resistance": {
  "value": 0.940584, "ci_lo": 0.892404, "ci_hi": 0.991365,
  "status": "pathological", "identifiable": true, "t_end": 268.62,
  "unit": "mmHg/(mL/min)", "healthy_range": [6.0, 10.0],
  "bound_provenance": "clinical", "n_records": 16
}
```
]

#example[`GET /params/craniospinal_compliance` · the contract, abridged][
```json
{ "id": "craniospinal_compliance", "unit": "mL/mmHg", "fitted_parameter": "E",
  "min_pathological_bound": 0.1, "min_healthy_bound": 0.5,
  "max_healthy_bound": 1.1,      "max_pathological_bound": 2.0,
  "direction_of_concern": "low", "bound_provenance": "clinical",
  "caveat": "No healthy controls exist in this dataset - ..." }
```
]

// ═════════════════════════════════════════════════════════════════════════════
= 3 · Read `identifiable` first

The estimate uses an *expanding* window. At each step the model is refitted on all mean-ICP
data from the start of the recording up to $t_"end"$, then $t_"end"$ moves forward. Each
record answers the question *"what would we have estimated, knowing only what had happened
by now?"* The window does not slide, because the model is an initial-value problem: every
evaluation integrates from $t = 0$ anyway.

#align(center, fig-window)

Resting ICP barely sees the venous outflow path: $|partial log "ICP"_"baseline" \/ partial log theta|$
is *0.0000* for the collateral resistance and *0.0004* for the jugular tube law. Before the
compression enters the window, those parameters are guessed, not estimated.

== Patient 081: the interval collapses when the manoeuvre enters the window

#align(center, fig-collapse)

#grid(columns: (1fr, 1fr), column-gutter: 10pt,
  card[
    #text(weight: "bold")[craniospinal_compliance, mL/mmHg]
    #table(columns: 3, stroke: none, inset: 3pt,
      [$t_"end"$], [95 % interval], [status],
      [−60 s], [[0.015, 1.34]], text(fill: C.grey)[unidentifiable],
      [+5.7 s], [[0.157, 0.370]], [borderline],
      [+268 s], [[0.205, 0.249]], [borderline])
  ],
  card[
    #text(weight: "bold")[jugular_resting_area, cm²]
    #table(columns: 3, stroke: none, inset: 3pt,
      [$t_"end"$], [95 % interval], [status],
      [−38 s], [[6·10#super[−275], 7·10#super[275]]], text(fill: C.grey)[unidentifiable],
      [+5.7 s], [[7.35, 18.3]], text(fill: C.rust)[pathological],
      [+268 s], [[5.07, 7.38]], text(fill: C.rust)[pathological])
    #small[550 orders of magnitude, then a factor 1.5.]
  ],
)

#example[`GET /stream/081/jugular_resting_area` · first window and last window][
```json
{"t_end": -38.11, "value": 6.16555, "ci_lo": 5.66e-275, "ci_hi": 6.71e+275,
 "status": "unidentifiable", "identifiable": false, "rmse": 0.1667, "n_solves": 92}
 ...
{"t_end": 268.37, "value": 6.1156,  "ci_lo": 5.07058,   "ci_hi": 7.37598,
 "status": "pathological",   "identifiable": true,  "rmse": 0.7261, "n_solves": 73}
```
]

#warn[A stream that emitted the −38 s value as a bare number would look like a measurement,
but it would be fiction. `identifiable` is set when the fractional σ is below 0.5.
*Watching the intervals collapse is the intended use of this API*, more than any single
value. And the jugular figure that does collapse, 6.1 cm², is the known fit artefact (§2,
`qc`): it is precise and wrong.]

// ═════════════════════════════════════════════════════════════════════════════
#set page(flipped: true)
= 4 · The circuit: 21 components, 8 observable

The six parameters are coordinates of the model, not places in the head. `GET /circuit`
splits the model into *9 compartments* (pressure nodes) and *12 interfaces* (flow elements,
`frm → to`). A component is *observable* only when a streamed parameter governs it. The
weights shown are patient 137's last window.

#align(center, fig-circuit)

#grid(columns: (1fr, 1fr), column-gutter: 10pt,
  card[
    #text(weight: "bold")[Solid, coloured:] observable, with a weight. \
    #text(weight: "bold", fill: muted)[Dashed, grey:] fixed at a model default. *An absent
    weight means NOT ESTIMATED, never normal.* 13 of the 21 components are in this state.
  ],
  card[
    #text(weight: "bold")[Hydrostatic panels] follow the plotter's `build_tilt_panels`. The
    *heart panel* (Pic, Psinus, Psys) is drawn against `Hs_Rvvs.Δp`. The *spine panel*
    (Pds, Po_spine, Pivp, Pevp) is drawn against `Hs_Revp.Δp`.
  ],
)

#small[One parameter can govern two components: `csf_outflow_resistance` is the lumped
$R_"o,tot"$, split 0.069 / 0.931 between cranial and spinal absorption. Both components then
carry the same weight.]

// ═════════════════════════════════════════════════════════════════════════════
#set page(flipped: false)
= 5 · From a parameter to a weight

#align(center, fig-weight)
#align(center, small[Worked through on patient 137, `csf_outflow_resistance` → `csf_absorption_cranial`.])

#small[Severity is piecewise linear on purpose: "how many bands out" has to be arithmetic a
clinician can check. 0 inside the band, ±1 at a pathological bound, beyond ±1 past it; the
sign gives `direction`. A weight is *not* a probability.]

== Why a pathological parameter can have weight 0

#card[
  Patient 137, `jugular_resting_area` = 4.47 cm², `pathological`, severity *+1.23*. Its
  interval [3.86, 5.17] is 1.32 cm² wide, and the healthy band (0.8–2.0) is only 1.2 wide.
  An interval wider than the band cannot say which side of the band the value is on, so the
  confidence is *0* and `internal_jugular` gets *w = 0.00*. The zero comes from the interval
  width, not from the parameter being healthy.
]

== The attribution ladder: is this about the patient, or the fit?

The checks run top-down, and the first that matches wins. *Only `patient` is a statement
about the patient.*

#align(center, scale(95%, reflow: true, fig-ladder))

#card(fill: border-f)[
  *Read the headline finding sceptically.* All four patients lead with
  `csf_absorption_cranial/spinal` at w = 1.1–1.7, direction `low`, because
  `csf_outflow_resistance` sits below its clinical floor in every patient. Abnormally *low*
  CSF outflow resistance is the opposite of the NPH/IIH pattern, and in the static prefit
  137 and 150 had $R_"o,tot"$ pinned at a search bound. The cause may be the 0.069 / 0.931
  cranial/spinal split rather than the patients. In 081 the latest parameters have both the
  collateral and the jugular pathological, so *R1 applies*, and its jugular and collateral
  weights are `model_artifact`.
]

#example[`GET /components/137/latest` · the lead component of the latest window, ranked by weight][
```json
{ "patient": "137",
  "window": { "t_end": 268.62, "n_parameters": 6, "rules_fired": [], "components": [
    { "component": "csf_absorption_cranial", "weight": 1.6447, "direction": "low",
      "attribution": "patient",
      "attribution_reason": "clinical bounds, identifiable in this window",
      "lead_parameter": "csf_outflow_resistance",
      "contributions": [ { "param": "csf_outflow_resistance", "severity": -1.6865,
          "confidence": 0.9753, "role": "conductance", "value": 0.940584,
          "status": "pathological", "identifiable": true } ] },
    ... 7 more ] } }
```
]


// ═════════════════════════════════════════════════════════════════════════════
= 6 · Two estimators

Both estimators write the same six streams in the same format. *Never run both on one
patient at once.*

#card(align(center, scale(90%, reflow: true, fig-speed)))

#table(columns: (auto, 1fr, 1fr), stroke: 0.4pt + C.grey.lighten(50%), inset: 5pt,
  fill: (x, y) => if y == 0 { C.navy.lighten(88%) },
  [], [*`stream_refit.jl`* · batch, *the reference*], [*`stream_filter.jl`* · sequential, *the deployable one*],
  [method], [refit the whole recording at each $t_"end"$], [joint state + parameter filter, one step per sample],
  [cost / record], [≈55 full integrations, ≈2.5 min], [39 one-second integrations, ≈0.2 s],
  [resolution], [as many windows as you can afford], [every sample, 1 Hz],
  [interval], [Fisher information at a converged optimum], [filter covariance, *given an assumed process noise*],
  [parameters], [constant within a window], [random walk (`_QTHETA`)],
)

#grid(columns: (1fr, 1fr), column-gutter: 10pt,
  card[
    #text(weight: "bold")[Why the batch fit cannot be made incremental.] The six quantities
    are structural parameters of the ODE. Changing $E$ changes the trajectory from the first
    step, so every candidate costs a fresh integration of the whole recording: ≈62 million
    RK4 steps per emitted record. There is nothing incremental to reuse.
  ],
  card(fill: patho-f)[
    #text(weight: "bold", fill: C.rust)[The filter's failure mode.] If `_QTHETA` is set too
    high, the filter explains genuine model error by letting the parameters wander. The
    stream will look responsive and mean nothing. Where the two estimators disagree, the
    batch fit is the one the README's numbers refer to.
  ],
)

// ═════════════════════════════════════════════════════════════════════════════
= 7 · Routes, setup, and what bites

#let route(path, what) = ([#text(8pt, font: "DejaVu Sans Mono", weight: "bold")[#path]], small(what))
#let rgroup(title, colour, ..rows) = block(stroke: (left: 2.5pt + colour), fill: colour.lighten(93%), inset: 7pt, width: 100%, {
  text(8pt, weight: "bold", fill: colour)[#title]
  v(-2pt)
  grid(columns: (auto, 1fr), column-gutter: 8pt, row-gutter: 5pt, align: horizon, ..rows.pos().flatten())
})
#grid(columns: (1fr, 1fr), column-gutter: 10pt, row-gutter: 8pt,
  rgroup([Parameters · `api_spec.jl`, the estimators], C.purple,
    route("/", [index, with route templates]),
    route("/params[/<id>]", [metadata + four bounds]),
    route("/stream/<p>/<id>", [raw stream, newest last]),
    route("  ?since=<t>", [only `t_end > t`: poll this]),
    route("/latest/<p>", [latest value of each parameter])),
  rgroup([Components · `translate_stream.py`], C.green,
    route("/circuit", [the segmentation]),
    route("/components[/<id>]", [component metadata]),
    route("/components/<p>/latest", [latest window, ranked by weight]),
    route("/components/<p>/stream", [all windows, `?since=<t>`]),
    route("/dashboard", [standing-watch page, one window per patient])),
)
#align(center, small[`<p>` ∈ `081 083 137 150`. Also on disk, *not* the canonical refit:
`081_batch`, `081_filter`. Patient ids are strings: `float("081") == 81.0`.])

== Quick start

```bash
bash scripts/setup_data.sh /path/to/brainphysio_celia   # fetch recordings
julia --project=. -e 'using Pkg; Pkg.instantiate()'     # only dependency is Optim
julia --project=. model/api_spec.jl                     # -> api/params/*.json
_PATIENT=081 julia --project=. model/stream_filter.jl   # -> api/stream/081/*.jsonl  (~90 s)
python3 scripts/translate_stream.py                     # -> component view (~1 s)
python3 scripts/serve_api.py --check                    # validate first
python3 scripts/serve_api.py                            # http://127.0.0.1:8770
bash model/stream_all.sh 16 45                          # all four, batch refit (~70 min)
```

== Things that bite

#grid(columns: (1fr, 1fr), column-gutter: 10pt, row-gutter: 8pt,
  card[
    #text(weight: "bold", fill: C.rust)[Port 8770 already in use.] A server from an earlier
    session is usually still running. It is stateless and file-backed, so *reuse it*.
    #example[`python3 scripts/serve_api.py`][
#show raw: set text(size: 6.8pt)
```
port 8770 is already in use
  held by pid 34833: python3 scripts/serve_api.py
  reuse it:  curl -s http://127.0.0.1:8770/
  or stop it: kill 34833
```
    ]
  ],
  card[
    #text(weight: "bold", fill: C.rust)[Don't `pkill -f serve_api`.] The pattern matches your own
    command line and kills the caller. Use the pid from the message.
    #v(4pt)
    #text(weight: "bold", fill: C.rust)[`nohup … &` in a one-shot shell does not persist.] Start the
    server as a proper background task.
    #v(4pt)
    #text(weight: "bold", fill: C.rust)[`api_spec.jl` rewrites `api/index.json`,] including the
    component route block. A route added only by hand is dropped at the next regeneration.
  ],
)

== Known limitations

#table(columns: (auto, 1fr), stroke: none, inset: 4pt, row-gutter: 2pt,
  text(fill: C.rust, weight: "bold")[1], [*No healthy controls.* This is the single largest caveat.],
  text(fill: C.rust, weight: "bold")[2], [*n = 4*: one manoeuvre each, one model.],
  text(fill: C.rust, weight: "bold")[3], [*≈7× overestimate of the ICP pulse under compression.* The cause is diagnosed: the fit inflates the jugular to ≈205 mL, which makes it the dominant beat-scale buffer, and the compression then removes it. This is why `jugular_resting_area` is `qc`.],
  text(fill: C.rust, weight: "bold")[4], [*Values on search bounds* (137 had three in the source fits) are not estimates. The interval is how you detect them.],
  text(fill: C.rust, weight: "bold")[5], [`sagittal_sinus_pressure` *as a negative control is provisional*: under refitting it reaches 8.07–8.33 mmHg (borderline).],
)
#small[Before interpreting any number, read *RULEBOOK.md*, which lists the parameter
combinations that indict the model rather than the patient.]
