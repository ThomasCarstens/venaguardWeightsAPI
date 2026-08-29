# Could this be instrumented in a field surgical facility?

An engineering answer to one question: **what signals does the code in this repository
actually consume, and what hardware would produce them?**

This is a read of the pipeline, not clinical advice and not a recommendation to place an
ICP monitor anywhere. The clinical questions — whether a given patient should have an
intracranial pressure monitor at all, and who is qualified to place one — are outside what
the code can tell you.

---

## Short answer

**Two of the four recorded channels are never read by any code in this repository.** The
estimator that feeds the parameter API needs one invasive signal, one scalar, and a
stopwatch. Everything else in the dataset is either unused or derived.

The blocker is not instrumentation. Every transducer in the chain is a commodity part
already present in any facility that runs arterial lines. The blocker is that intracranial
pressure cannot be measured from outside the skull, so the requirement is a burr hole and
the neurosurgical capability to make one safely.

If that capability exists, the rest is within reach of basic hardware — including, at the
lowest tier, a monitor display and someone writing numbers down.

---

## What was recorded versus what is read

The four ICU recordings (`data/jugular_prepared/*.csv`) carry five channels at 100 Hz:

| channel | in the CSVs | read by the model | what it feeds |
|---|---|---|---|
| `icp` | yes | **yes** | the entire fit |
| `abp` | yes | **yes** | arterial boundary; beat segmentation |
| `left_doppler` | yes | **no** | nothing |
| `right_doppler` | yes | **no** | nothing |
| `co2` | yes | **no** | nothing |

The transcranial Doppler and capnography channels are prepared, written to disk, and never
opened. `load_rec` ([model/ude_cv.jl:78-108](model/ude_cv.jl#L78-L108)) reads only `t`,
`abp` and `icp` from the waveform file, the same three from the 1 Hz mean file, and
`t`/`period`/`icp_mean`/`icp_amp` from the beat table. A grep for `doppler` or `co2` across
`model/` and `scripts/` returns nothing.

This is deliberate, and Model_5's README says why the Dopplers are not scored: they are
blood *velocities* in one insonated artery, while `brain.in.q` is a total cerebral volume
*flow*. The two are proportional only if the insonated vessel's cross-section and its share
of total flow are both constant, and neither is given.

**So two channels of the recording can be dropped without changing a single number the API
serves.** That matters for this question, because TCD is the expensive, operator-skilled,
hard-to-field part of the setup.

---

## Three tiers of instrumentation

### Tier 1 — everything the streaming API actually needs

[model/stream_refit.jl](model/stream_refit.jl) is the estimator behind `api/stream/`. Its
residual is mean ICP and nothing else:

```julia
icp[idx] .- REC.icpm[m]        # 1 Hz mean ICP, up to t_end
```

The complete input list:

1. **Mean ICP at 1 Hz.** Not a waveform — a mean. 420 numbers over the seven-minute window.
2. **One scalar: baseline mean ABP.** It enters at exactly one place, as the anchor for
   arterial resistance: `Ra0 = (abp_base − 25.0)/12.5`
   ([model/ude_cv.jl:128](model/ude_cv.jl#L128)). A cuff reading would serve, at the cost of
   one stated assumption.
3. **The manoeuvre's start and stop times.** Recorded in
   [data/jugular_prepared/events.jl](data/jugular_prepared/events.jl) as `t_on`/`t_off`. A
   stopwatch and an honest note produce these.

That is the whole requirement for the six streamed parameters. A 1 Hz mean ICP trace is
loggable by hand off a bedside monitor display — this tier would run on a paper chart
transcribed into a CSV.

### Tier 2 — adds the pulse

The arterial compliance estimate (`Ca`, stage B of the fit) is scanned against the
**baseline ICP pulse amplitude**, which needs beat-resolved systolic and diastolic ICP —
the `_beat.csv` table. That requires:

- an ICP waveform fast enough to resolve a pulse: the recordings are 100 Hz, and the
  preprocessing low-passes to 20 Hz, so ~50 Hz sampling is the honest floor;
- beat segmentation, from the ABP waveform or an ECG lead.

### Tier 3 — recorded, unused

Bilateral TCD and capnography. Present in the dataset, consumed by nothing.

---

## The hardware, item by item

**Intracranial pressure — the hard requirement.** Two routes:

- *Intraparenchymal microsensor* (Codman, Camino, Raumedic): a twist drill, a bolt, a
  single-use probe, and the vendor's own monitor. Accurate and quick to place, but
  consumable- and vendor-locked — the worst properties for an austere setting.
- *External ventricular drain with a fluid-coupled transducer*: a burr hole, a ventricular
  catheter, sterile tubing, and a **standard disposable pressure transducer** — the same
  commodity part used for every arterial line — levelled to the foramen of Monro and read
  by any monitor with an invasive-pressure channel.

The EVD route is the field-plausible one. Its consumables are generic, its readout is a
channel most transport and field monitors already have, and it is therapeutic as well as
diagnostic. What it is not is a monitoring add-on: it is an intracranial procedure needing
sterile conditions, neurosurgical skill, and the ability to manage its complications.

**Arterial pressure.** An arterial line into the same class of disposable transducer. For
Tier 1 the waveform is not needed at all — `abp_base` is one number.

**Digitisation.** Any monitor with a data-export port, or a hand-transcribed 1 Hz trace.
The preprocessing that produces `_mean.csv` is a decimation with a respiration filter; a
clean 1 Hz mean from the monitor's own display substitutes for it directly.

**The manoeuvre itself.** Manual bilateral jugular compression, held about two minutes.
No hardware whatsoever. The four recordings agree to within a couple of seconds — 118 ± 2 s
— which is what makes them one standardised stimulus rather than four different ones.

---

## What a field version would give up

- **The pulse-amplitude channel**, if ICP is logged at 1 Hz rather than sampled as a
  waveform. That costs the `arterial_compliance` estimate — and, more importantly, costs
  the check that exposes the model's largest known failure (see
  [RULEBOOK.md](RULEBOOK.md), rule R5). The failing check is arguably the most valuable
  output in the pipeline, so this is not a cheap loss.
- **Beat-level artefact rejection.** At 1 Hz you cannot see that a step was a cough.
- **Any hope of validating the fit against flow.** Already true of the full dataset, since
  the Dopplers are unscored.

## What it would not give up

Nothing else. The six streamed parameters, their confidence intervals, and the
identifiability flags all come out of Tier 1.

---

## Caveats that travel with any answer here

- **The dataset has no healthy controls.** All four recordings are ICU patients. Every
  "healthy" bound in `api/params/` is from literature, not from a control group measured on
  this equipment with this pipeline. This is recorded in every metadata file and is the
  weakest link in the API.
- **The model is not validated outside the jugular compression.** A parameter estimated
  against a 120 s neck compression carries no promise about anything else.
- **Two of the six streamed parameters are not patient findings.** `jugular_resting_area`
  is quality control and `sagittal_sinus_pressure` is a negative control. See
  [RULEBOOK.md](RULEBOOK.md).
- **The model has known structural failures** that the fit does not absorb — it reproduces
  the mean ICP step and gets the pulse amplitude wrong by an order of magnitude. Better
  instrumentation does not fix that; it only measures it more precisely.
