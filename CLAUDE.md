# icp-parameter-api

Estimates six physiologically interpretable parameters of cerebral CSF/venous dynamics from
an ICP recording, and serves them over HTTP — both as raw parameters and translated into
per-component abnormality weights.

## Running the API

```bash
python3 scripts/serve_api.py --check     # validate on disk, don't serve; exit 1 if incoherent
python3 scripts/serve_api.py             # http://127.0.0.1:8770
python3 scripts/serve_api.py --port 9000
```

Standard library only — **no venv needed**, plain `python3`. The server is file-backed: it
reads `api/` at request time, so a refit that is still running is served live and `?since=`
polls for new records.

`--check` first. It validates bound ordering, stream presence, and that every component in
the segmentation resolves to a real parameter. If it exits non-zero the server will still
start and serve something wrong.

### Routes

```
GET /                                  index, including route templates
GET /params            /params/<id>    parameter metadata + the four bounds
GET /stream/<patient>/<id>?since=<t>   raw parameter stream
GET /latest/<patient>                  most recent value of each parameter

GET /circuit                           the segmentation: compartments + interfaces
GET /components        /components/<id>
GET /components/<patient>/latest       most recent window, ranked by weight
GET /components/<patient>/stream?since=<t>
GET /dashboard                         standing-watch HTML page
```

Patients: `081 083 137 150`. Also on disk: `081_batch`, `081_filter` (different experiments,
not the canonical refit).

## Regenerating

| what | command | cost |
|---|---|---|
| parameter metadata + index | `julia --project=. model/api_spec.jl` | instant |
| **component view** | `python3 scripts/translate_stream.py` | ~1 s |
| one patient's refit | `_PATIENT=081 _NWIN=16 _WIN_ITERS=45 julia --project=. model/stream_refit.jl` | ~65 min |
| all four | `bash model/stream_all.sh 16 45` | ~70 min (parallel) |

`translate_stream.py` is pure post-processing over what the refit already wrote, so the
translation logic can be changed and re-run in a second without redoing a refit.

Data is **not** in git. `bash scripts/setup_data.sh /path/to/brainphysio_celia` restores it.

## Things that will bite you

**Port is 8770**, not 877. A stale server from an earlier session will hold it and you will
get `Address already in use`; find it with `ps -eo pid,args | grep "[s]erve_api"` and kill by
PID. Do **not** `pkill -f serve_api` — the pattern matches your own command line.

**`nohup ... &` inside a single shell invocation does not persist.** Start the server as a
proper background task.

**Two writers corrupt streams.** `083` was once truncated to 0 records because a second
process opened the same `.jsonl` with `"w"`. If a stream shrinks or `t_end` jumps backwards,
that is what happened — see RULEBOOK R9.

**`model/api_spec.jl` rewrites `api/index.json`**, including the component route block. If
you add a route, add it there too or the next regeneration drops it.

## Read RULEBOOK.md before interpreting any number

The six parameters are six coordinates of **one fit** of a model with known structural
failures. When the fit hits one, it does not fail loudly — it produces a plausible parameter
set with the error absorbed into a coordinate or two. RULEBOOK.md lists the combinations that
indict the model rather than the patient. R1 (tube-law escape) and R6 (the E/Ro_tot
degeneracy) are implemented in `scripts/circuit.py` and change a component's `attribution`
automatically; the rest need cross-window or raw-θ context and are left to the reader.

## What the numbers do and do not mean

- **`bound_provenance`** on every parameter: `clinical` (published human range), `model`
  (anchored on the source model's default — *not* physiology), `qc` (a check on the fit).
  Only 3 of 6 are `clinical`. Never present a `model` bound to a clinician as a normal range.
- **`identifiable: false`** means the value is guessed, not measured. Resting ICP is nearly
  blind to the venous outflow path, so before the compression enters the window those
  parameters are unconstrained — the jugular interval spans 500+ orders of magnitude there.
  Report the flag, not the point estimate.
- **An absent component has no weight because it was NOT ESTIMATED**, never because it is
  normal. Only 8 of 21 components are governed by a streamed parameter.
- **`attribution`** distinguishes a statement about the patient from one about the fit.
  `model_artifact`, `fit_quality` and `degenerate` are not diagnoses.
- **There are no healthy controls in this dataset.** Every bound is from literature.
- The underlying model **overestimates ICP pulse amplitude under jugular compression by ~7×**,
  from a diagnosed cause (the fit inflates the resting jugular ~10× to manufacture the ICP
  step). This is not a caveat to bury — it is why `jugular_resting_area` is `qc`.

## Layout

```
api/params/<id>.json          parameter metadata + bounds       (api_spec.jl)
api/circuit.json              the segmentation                  (translate_stream.py)
api/components/<id>.json      per-component metadata            (translate_stream.py)
api/stream/<patient>/<id>.jsonl        raw parameter stream     (stream_refit.jl)
api/stream/<patient>/_components.jsonl weights per window       (translate_stream.py)

model/ude_cv.jl               the 13-state compact ODE
model/stream_refit.jl         expanding-window refit + Fisher intervals
model/api_spec.jl             writes api/params + api/index.json
scripts/circuit.py            segmentation + translation logic
scripts/translate_stream.py   generates the component view
scripts/serve_api.py          HTTP server, stdlib only
RULEBOOK.md                   parameter combinations that indict the model
SENSORS.md                    what a physical sensor would add
```

## Conventions

- **Plot titles go in Markdown, not `update_layout(title=...)`** — a horizontal legend at
  `y≈1.12` occupies the same strip and they overlap. Applies to notebooks here and mirrors
  `.protocols/PLOT_CONVENTIONS.md` §14 in the source repo.
- Notebooks are **generated from builder scripts**, not hand-edited. Edit the builder.
- Patient ids are strings. `float("081") == 81.0`, so any CSV/JSON loader that auto-detects
  types will silently turn `patient == "081"` into an all-False mask and drop series without
  erroring.
