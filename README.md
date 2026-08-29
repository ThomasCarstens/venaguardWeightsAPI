# ICP parameter API

A streaming estimator for six physiologically-interpretable parameters of cerebral
CSF/venous dynamics, fitted from an intracranial pressure recording and served over HTTP
with confidence intervals and healthy/pathological bounds.

Extracted from the `brainphysio_celia` research repository (`Model_6`), 2026-08-26.

---

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
_PATIENT=081 julia --project=. model/stream_refit.jl    # -> api/stream/081/*.jsonl
python3 scripts/serve_api.py                            # http://127.0.0.1:877
```

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
```

A stream record:

```json
{"t_end": 268.4, "value": 2.096, "ci_lo": 1.84, "ci_hi": 2.39,
 "status": "pathological", "identifiable": true, "rmse": 0.765, "n_solves": 77}
```

The API is **file-backed**. `stream_refit.jl` appends one JSON object per window and
flushes, so a refit still in progress is served live and `?since=` polls only what is new.

---

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
model/stream_refit.jl  the expanding-window refitter
model/stream_all.sh    all four patients in parallel
fit/*_compact.jl       per-patient starting parameters
scripts/setup_data.sh  copy recordings from the source repository
scripts/serve_api.py   HTTP server, standard library only
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
