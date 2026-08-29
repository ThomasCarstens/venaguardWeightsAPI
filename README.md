# ICP parameter API

A streaming estimator for six physiologically-interpretable parameters of cerebral
CSF/venous dynamics, fitted from an intracranial pressure recording and served over HTTP
with confidence intervals and healthy/pathological bounds.

Extracted from the `brainphysio_celia` research repository (`Model_6`), 2026-08-26.

---


## The component view — what is actually abnormal, and where

The six streamed parameters are model coordinates, not places. `E` is a coefficient in a
compliance law; `Ro_tot` is one lumped resistance split two ways. A reader has to already
know the model to know *what* is wrong. The component view translates a fitted parameter
vector into weights on parts of the circuit.

**The segmentation** (`GET /circuit`) follows the plotter's two hydrostatic panels
(`build_tilt_panels` in the source repo):

| | drawn against | compartments |
|---|---|---|
| `tilt_pressures_heart` | heart→brain column `Hs_Rvvs.Δp` | Pic, Psinus, Psys |
| `tilt_pressures_spine` | spine column `Hs_Revp.Δp` | Pds, Po_spine, Pivp, Pevp |

**(a) 9 compartments** — pressure nodes. Those carrying `hydrostatic_panel` are the ones
the plotter references to a column; the rest close the circuit but are not drawn.
**(b) 12 interfaces** — the flow elements between them (`frm` → `to`).

**Only 8 of the 21 are observable.** A component with no governing parameter has no weight,
and an absent weight means NOT ESTIMATED — never *normal*.

### What a weight is

`weight` is how far the governing parameter sits outside its healthy band — 0 inside,
1.0 at the pathological bound, above 1 beyond it — multiplied by how well that window
identified the parameter. Where several parameters govern one component the **largest**
discounted excursion wins, not the sum: two parameters mildly out is not evidence of one
severely abnormal component.

It is **not** a probability, and not necessarily a claim about the patient. `attribution`
says which:

| attribution | meaning |
|---|---|
| `patient` | clinical bounds, identifiable in this window |
| `model_referenced` | bounds anchored on the source model's default, not a human range |
| `fit_quality` | a QC check on the fit (jugular geometry), not physiology |
| `model_artifact` | RULEBOOK R1 fired — the excursion indicts the fit, not the patient |
| `degenerate` | RULEBOOK R6 — read the pair as one poorly-determined combination |
| `unidentifiable` | no governing parameter was identifiable; the value is guessed |

### Routes

```
GET /circuit                        the segmentation
GET /components                     every component's metadata
GET /components/<id>                one component
GET /components/<patient>/latest    most recent window, ranked by weight
GET /components/<patient>/stream    all windows   (?since=<t> to poll)
```

Regenerate after any refit — it is pure post-processing, about a second:

```bash
python3 scripts/translate_stream.py
```

### What the four patients show

Every patient leads with **`csf_absorption_cranial` / `csf_absorption_spinal`**, weight
1.1–1.7, direction `low`. That is `csf_outflow_resistance` below its clinical floor in all
four — and it is worth reading sceptically rather than as a finding: abnormally *low* CSF
outflow resistance is the opposite of the NPH/IIH pattern, and 137 and 150 had `Ro_tot`
pinned at a search bound in the static prefit. It may be telling you about the 0.069/0.931
cranial/spinal split rather than about the patients.

081 is the only patient where **R1 fires**, so its jugular and collateral weights are
attributed `model_artifact` and should not be read clinically.


## ⚠ Patient data is NOT in this repository

`data/` is **gitignored**. The estimator needs four de-identified 100 Hz ICU recordings
(ICP, ABP, transcranial doppler, CO₂) that are not distributed here. Run:

```bash
bash scripts/setup_data.sh /path/to/brainphysio_celia
```

to copy them in from the source repository.

If you later choose to commit the recordings (`git add -f data/`), **this repository must
stay private.** The default is to exclude them precisely so that the code can be shared
without that decision being made by accident.

---

## What it estimates

Six quantities, each with a description, four bounds, and a provenance tag. **The provenance
tags are not decorative — they mark how much the bounds can be trusted:**

| id | unit | provenance |
|---|---|---|
| `craniospinal_compliance` | mL/mmHg | `clinical` |
| `csf_outflow_resistance` | mmHg/(mL/min) | `clinical` |
| `sagittal_sinus_pressure` | mmHg | `clinical` |
| `arterial_compliance` | mL/mmHg | `model` |
| `collateral_outflow_resistance` | mmHg·s/mL | `model` |
| `jugular_resting_area` | cm² per vein | `qc` |

- **`clinical`** — a published human reference range for a directly measured quantity.
- **`model`** — *no* human reference range exists. Bounds are anchored on the source model's
  literature default, so they are a statement about the model, not about physiology. **Do
  not present these to a clinician as normal ranges.**
- **`qc`** — streamed as a check on the fit rather than as a property of the patient.
  `jugular_resting_area` is the only one: the fit drives it to 5–12 cm² against a
  physiological 0.8–2.0, which is a known artefact of the underlying model. A value outside
  the band is evidence the **fit** is wrong, not that the patient is sick. A bedside
  ultrasound falsifies it in thirty seconds, which makes it the best quality-control channel
  in the set.

### The dataset has no healthy controls

All four recordings are ICU patients. Every "healthy" bound is from literature, not from a
control group measured with this pipeline. This is the weakest assumption in the project and
it is repeated in every metadata file rather than stated once here.

---

## Quick start

```bash
bash scripts/setup_data.sh /path/to/brainphysio_celia   # fetch recordings
julia --project=. -e 'using Pkg; Pkg.instantiate()'     # only dependency is Optim
julia --project=. model/api_spec.jl                     # -> api/params/*.json
_PATIENT=081 julia --project=. model/stream_filter.jl   # -> api/stream/081/*.jsonl  (~90 s)
python3 scripts/serve_api.py                            # http://127.0.0.1:8770
```

`notebooks/stream_explorer.ipynb` drives all of this and watches the intervals collapse live.
For a **standing watch**, open `http://127.0.0.1:8770/dashboard` instead — a Jupyter kernel
has one execution queue, so a polling cell blocks the whole notebook, while the dashboard is
a plain page you can open in as many windows as you want (one per patient, say). The server
is threaded and file-backed, so readers never contend with each other or with the estimator.

Validate without serving:

```bash
python3 scripts/serve_api.py --check     # bound ordering + stream presence; exit 1 on failure
```

All four patients in parallel (~70 min):

```bash
bash model/stream_all.sh 16 45           # 16 windows, 45 Nelder-Mead iterations each
```

---

## Endpoints

```
GET /                                    index: parameters, patients, route templates
GET /params                              all metadata as one object
GET /params/<id>                         one parameter's description + bounds
GET /stream/<patient>/<id>               full stream, newest last
GET /stream/<patient>/<id>?since=<t>     only records with t_end > t  (incremental poll)
GET /latest/<patient>                    most recent value of every parameter + status
GET /dashboard                           standing-watch page, open in as many windows as you like
```

A stream record:

```json
{"t_end": 268.4, "value": 2.096, "ci_lo": 1.84, "ci_hi": 2.39,
 "status": "pathological", "identifiable": true, "rmse": 0.765, "n_solves": 77}
```

The API is **file-backed**. `stream_refit.jl` appends one JSON object per window and
flushes, so a refit still in progress is served live and `?since=` polls only what is new.

---

## Two estimators, and why there are two

`stream_filter.jl` and `stream_refit.jl` write the same six streams in the same format and
must never run at once for one patient — they open the same files with `"w"`.

| | `stream_refit.jl` (batch) | `stream_filter.jl` (sequential) |
|---|---|---|
| method | re-fit the whole recording at each `t_end` | joint state+parameter filter, one step per sample |
| cost per record | ~55 full re-integrations, ~2.5 min | 39 one-second integrations, ~0.2 s |
| vs. real time | **~11x slower** | **~4.5x faster** |
| resolution | as many windows as you can afford | every sample, 1 Hz |
| interval | Fisher information at a converged optimum | filter covariance, given assumed process noise |
| parameters | constant within a window | random walk (`_QTHETA`) |

**The batch fit cannot run continuously and this is not an implementation problem.** The six
fitted quantities are structural parameters of the ODE: change `E` and the trajectory differs
from the first step, so no part of the previous window's simulation can be reused. Every
candidate parameter vector costs a fresh integration of the entire recording — ~62 million
RK4 steps per emitted record. Nothing incremental exists to exploit.

The filter inverts that. It carries the state forward instead of re-deriving it, so a new
sample costs one second of integration per perturbation direction rather than a full re-fit, and it
runs ahead of the patient. What it gives up is stated in the file header and is not small:
the interval becomes a filter covariance whose width depends on the process noise you assume,
and parameters are permitted to drift rather than being constant. **Set `_QTHETA` too high
and the filter will explain genuine model error by wandering the parameters — the stream
will look responsive and mean nothing.**

Treat the batch fit as the reference and the filter as the deployable one. Where they
disagree, the batch fit is the claim the README's numbers are about.

## How the estimate is produced

An **expanding window**: at each step the model is refitted against all mean-ICP data from
the start of the recording up to `t_end`, and `t_end` walks forward. Each record answers
*"what would we have estimated knowing only what had happened by now"* — what a bedside
monitor could have shown at that instant.

It is deliberately **not** a sliding window. The model is an initial-value problem, so every
objective evaluation integrates from the start of the recording regardless of which window
is scored. Sliding buys nothing and discards the settling.

### `identifiable` is the field to read first

Resting ICP is nearly blind to the venous outflow path — sensitivity
`|∂log(ICP_baseline)/∂log θ|` is **0.0000** for collateral resistance and **0.0004** for the
jugular tube law. In any window *before* the compression manoeuvre, those parameters are not
estimated, they are guessed:

```
t_end = −60 s   (baseline only)        t_end = +268 s  (manoeuvre included)
craniospinal   CI [0.020, 0.596]   →   CI [0.101, 0.116]     unidentifiable → borderline
jugular area   CI [3.6e-274, 7e274] →  CI [4.53, 5.67]       unidentifiable → pathological
```

A stream emitting a bare number in the left column would look like a measurement and would
be fiction. Every record therefore carries a Fisher-information interval and an
`identifiable` flag (fractional σ < 0.5). **Watching the intervals collapse as the manoeuvre
supplies the information is the intended use of this API**, more than any single value.

`status` is `unidentifiable` whenever the flag is false, regardless of where the point
estimate happens to fall.

---

## Layout

```
model/ude_cv.jl        13-state compact model of the craniospinal circuit (RK4, ~2.5 s/solve)
model/api_spec.jl      writes api/params/*.json — the bounds contract
model/stream_contract.jl  what both estimators must agree on: bounds, derivations, record bytes
model/stream_refit.jl  the expanding-window refitter (batch, the reference)
model/stream_filter.jl the sequential joint state-parameter filter (runs faster than real time)
model/stream_all.sh    all four patients in parallel
fit/*_compact.jl       per-patient starting parameters
scripts/setup_data.sh  copy recordings from the source repository
scripts/serve_api.py   HTTP server, standard library only
web/dashboard.html     standing-watch page served at /dashboard (no build, no dependencies)
api/params/*.json      generated metadata (committed — it is the contract)
api/stream/            generated streams (gitignored)
data/                  patient recordings (gitignored)
```

---

## Known limitations

1. **No healthy controls** (above). The single largest caveat.
2. **n = 4**, one manoeuvre each, one model.
3. **The underlying model has a known structural error**: it overestimates the ICP pulse
   amplitude under jugular compression by roughly sevenfold. The cause is diagnosed —
   the fit inflates the jugular to ~205 mL, making it the model's dominant beat-scale
   buffer, which the compression then removes. `craniospinal_compliance` and
   `csf_outflow_resistance` are fitted against the *mean* ICP response and are not directly
   implicated, but the coupling has not been ruled out.
4. **Some fitted values sit on search bounds** in the source fits (patient 137 had three).
   A value at a bound is not an estimate; the confidence interval is the way to detect this.
5. **`sagittal_sinus_pressure` was intended as a negative control** — the one parameter that
   stayed in range across all four static fits. Under expanding-window refitting it drifted
   to 8.33 mmHg (borderline) in at least one window, so that framing is provisional and
   should not be relied on until it has been checked across all four patients.
