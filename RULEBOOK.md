# Rulebook: parameter combinations that indict the model

The six streamed parameters are not six independent measurements. They are six coordinates
of one fit, and the model they come from — Model 3's physics, fitted in Model 5, recompiled
compactly in Model 6 — has **known structural failures**. When the fit runs into one of
those, it does not fail loudly. It produces a plausible-looking parameter set in which one
or two coordinates have absorbed the error.

This file is how to read that. Each rule is a **combination** of streamed values whose
joint appearance points at a specific place in the model, not at the patient.

Read it alongside `api/params/<id>.json`, which carries each bound's provenance
(`clinical` / `model` / `qc`), and the caveat that no healthy controls exist in this
dataset.

---

## The model, in the two sentences the rules need

The cerebral venous outflow leaves `brain.out` through **two paths in parallel**: the
internal jugular `Rijvs`, a collapsible tube with a nonlinear tube law, and `Rvvs`, the
vertebral venous plexus collateral. A jugular compression is modelled as an external
pressure `P_jc` applied to the tube, collapsing its area `A` and raising its resistance
as roughly `A⁻²`.

Everything below follows from those two facts.

---

## R1 — The tube-law escape *(the signature failure)*

**Trigger.** `collateral_outflow_resistance` far above `max_healthy` **and**
`jugular_resting_area` above `max_healthy`, in the same window.

**What it means.** The fit cannot make the jugular collapse hard enough to produce the
measured ICP step, so it buys the step two other ways: it inflates the resting vein and it
blocks the collateral. Neither is a statement about the patient.

**Why the model does this.** With `Rvvs` at its M3 default of 0.04 mmHg/(mL/s), the
vertebral collateral carries the entire cerebral outflow at almost no pressure cost — so
closing the jugular simply diverts the flow and costs nothing. Run unfitted, M3 answers a
default 8 mmHg neck compression with **+0.25 mmHg** of ICP against the patient's **+10.24**,
a factor of 40, *from a vein that is already 85% collapsed* (`Rijvs.A` 1.254 → 0.191 cm²).
And the tube law
`in.p − ext.p = k·((A/A0)^b1 − (A/A0)^−b2)`
collapses the *area* smoothly while the *resistance* saturates slowly, so reaching the
extra outflow resistance a 10 mmHg step needs at 12.5 mL/s would take a transmural pressure
of several hundred mmHg.

**The diagnostic history.** The first Model 5 fit left `k_ijvs` out and came back with
**both** `Rvvs` and `P_jc_amp` pinned at their upper bounds and still 3 mmHg short on the
step. That pairing is what put `k_ijvs` in the fit and brought `P_jc_amp`'s ceiling down to
80 mmHg — a bound permitting a 150 mmHg manual compression is a bound that lets the fit
dodge the tube law again.

**Action.** Report neither parameter clinically. `jugular_resting_area` carries
`bound_provenance: "qc"` precisely for this: a value outside its band is evidence the
**fit** is wrong, not the patient. A bedside ultrasound falsifies it in thirty seconds.

---

## R2 — Sinus pressure is a POSITIVE control, not a negative one *(revised 2026-08-29)*

**Trigger.** `sagittal_sinus_pressure` rising above `max_healthy` (8.0 mmHg) as the window
grows to include the compression.

**This rule previously said the opposite.** It read: *"Psinus is streamed as a negative
control because it stayed inside its healthy band across all four recordings. A pipeline
reporting it as abnormal is reporting on itself. Stop."* That was written when only the
static per-recording fits existed, where Psinus sat at 5.87–8.07 mmHg.

**What the completed expanding-window run showed.** Across all four patients Psinus rises
monotonically as the compression enters the window, and ends outside the healthy band in
three of them:

| patient | first window | final window | final status |
|---|---|---|---|
| 081 | 6.80 | 8.79 | borderline |
| 083 | 7.27 | 9.57 | borderline |
| 137 | 7.59 | 8.07 | borderline |
| 150 | 5.63 | 6.97 | healthy |

**Why the old rule was wrong.** Occluding the jugular raises venous back-pressure upstream
of the occlusion, and the dural sinus is upstream. A rising Psinus during a jugular
compression is the *expected* physiology, not a bug — so a parameter that responds to the
manoeuvre was never a candidate for a negative control. As written, the old R2 would have
halted reading on three of four patients for doing the right thing.

**Action.** Read a rise through the compression as confirmation the manoeuvre reached the
venous compartment. Treat Psinus as abnormal only if it is elevated in the *pre-compression*
windows, where no such mechanism applies. There is currently **no negative control** in the
stream; the honest statement is that the pipeline has none, not that it has one.

---

## R3 — A pinned parameter is not an estimate

**Trigger.** Any fitted parameter within a few percent of `LO` or `HI`
([model/stream_contract.jl:13-14](model/stream_contract.jl#L13-L14)).

**What it means.** The search is reporting that the model cannot get to where the data is
along that direction. It is a structural statement wearing the costume of a measurement.

**Why you will miss it.** No RMSE will tell you. The objective penalises infeasibility
*more* than divergence, so a pinned point can still score well. Nothing in the streamed
record exposes the raw θ against its bounds — the API publishes derived quantities, and the
derivation hides the pin.

**Action.** Check θ against `LO`/`HI` directly. Treat a pinned coordinate as unestimated,
whatever its confidence interval says.

---

## R4 — Unidentifiable before the manoeuvre is correct; after it is a failed experiment

**Trigger.** `identifiable: false` on a venous parameter (`collateral_outflow_resistance`,
`jugular_resting_area`, `sagittal_sinus_pressure`) at `t_end` **after** the compression
ends.

**What it means.** The manoeuvre did not deliver the information it exists to deliver —
the compression was too weak, or the collateral carried the flow anyway (which is R1 seen
from the other side).

**What is *not* a failure.** The same flag *before* the compression. Resting ICP is
essentially blind to the venous outflow path: the sensitivity `|dlog(ICP_base)/dlog·|` is
**0.0000** for `Rvvs`, **0.0000** for `Pjc` and **0.0004** for `k_ijvs`. In every
pre-compression window those parameters are not estimated, they are guessed, and the flag
is the model being honest.

**Action.** The whole point of the expanding-window stream is watching intervals collapse
at the moment the manoeuvre supplies information. If they never collapse, the experiment
failed — that is the finding, and it is not visible in any single window.

---

## R5 — The amplitude contradiction

**Trigger.** `craniospinal_compliance` low (high `E`) together with `arterial_compliance`
at or below `min_pathological`.

**What it means.** The `(E, Ca)` pair is being asked to satisfy both the mean ICP step and
the pulse, and no pair can. This is the model's largest known disagreement with the data,
and it **survives the fit** rather than being absorbed by it:

| window | Model 5 | recording |
|---|---|---|
| baseline | 2.32 | 3.81 mmHg |
| **plateau** | **22.46** | **4.01 mmHg** |
| recovery | 1.69 | 3.83 mmHg |

The patient's ICP pulse amplitude does not move — **+5%** while mean ICP rises 10.3 mmHg.
The model's rises **tenfold**. With the jugular collapsed, each beat's arterial volume has
nowhere to go in the model; something in the patient absorbs it and nothing in the model
does. A Marmarou-type exponential P–V relation predicts roughly a doubling, so the model is
far worse than even the wrong analytic answer.

**Action.** `Ca` is scanned against the **baseline** amplitude only, deliberately — no
`(E, Ca)` pair satisfies both ends, and fitting an average would bury the finding. So read
`arterial_compliance` as a statement about the baseline pulse and about nothing at the
plateau. This is the failure Model 6 exists to interrogate, by replacing the constant venous
compliance with a learned law or adding a reservoir outside the skull at `brain.out`.

---

## R6 — Elastance doing the outflow resistance's job

**Trigger.** `csf_outflow_resistance` below `min_pathological` **and**
`craniospinal_compliance` below `min_pathological`.

**What it means.** A degenerate direction, not two findings. Both quantities raise the mean
ICP step, and the streaming objective sees only mean ICP — so `Ro_tot` pushed down and `E`
pushed up trade against each other along a valley the residual barely distinguishes.

**Action.** Treat the pair as one poorly-determined combination. Their individual intervals
are computed from the diagonal of the inverse FIM and therefore **understate** the
correlated uncertainty; the FIM's off-diagonal terms are where this degeneracy lives, and
the stream does not publish them.

---

## R7 — A frozen estimate

**Trigger.** A value byte-identical across consecutive windows while `rmse` keeps changing
and `n_solves` stays constant.

**What it means.** The warm-started Nelder-Mead is not moving that coordinate. This is not
convergence — a converged coordinate has been *visited*; a frozen one may never have moved
off its initial value.

**Observed.** In a `stream_filter.jl` run captured 2026-08-29,
`collateral_outflow_resistance` sat at **2.60587** for 14 consecutive windows with
`n_solves` fixed at 39. That value is the Model 5 fitted `Rvvs` of **2.61** — i.e. its
starting point, never departed.

**Action.** A frozen coordinate is unestimated regardless of how tight its interval looks.
The interval is computed from the FIM at the reported point and knows nothing about whether
the optimiser ever explored.

---

## R8 — Basin ambiguity

**Trigger.** The same parameters converging to different steady states across runs or
seeds.

**What it means.** The autoregulation feedback loop — `brain.Art.V`, `brain.Art.C`,
`brain.Art.q_avg`, driven by the sigmoidal positive/negative feedback of compliance against
flow error — has **multiple basins of attraction at fixed parameters**. Model 4's
`bistability_test.jl` holds every parameter exactly at baseline and perturbs only the
initial condition over 10⁻²–10² of each state's baseline; any spread in the converged state
is the ODE having several attractors, not different physics.

**Action.** Reproducibility of a parameter across windows is not proof of uniqueness. In an
expanding-window fit each window is warm-started from the last, so the whole stream can sit
in one basin and never reveal that another exists.

---

## R9 — Two writers *(an infrastructure rule, and it fires today)*

**Trigger.** A stream shrinking, `t_end` jumping backwards between reads, or every value
changing wholesale.

**What it means.** Two estimators are writing the same patient's directory. Both
`stream_refit.jl` and `stream_filter.jl` open the six `.jsonl` files with `"w"`; run
together they truncate each other and interleave records at their own file offsets. Every
line still parses, so the API serves a coherent-looking mixture of two different runs. The
damage is silent.

**Guard.** `take_stream_lock` in
[model/stream_contract.jl:96-120](model/stream_contract.jl#L96-L120) — advisory, by pid,
reclaimed if the holder died. A guard in a client cannot prevent this, because the second
writer is usually a terminal.

**Action.** Check `api/stream/<patient>/.writer.pid` before trusting a snapshot. Any rule
above, evaluated across a torn stream, is meaningless.

---

## Quick reference

| Rule | Trigger | Points at |
|---|---|---|
| R1 | high collateral **+** large jugular area | tube law cannot collapse; parallel outflow path |
| R2 | sinus pressure out of band | a bug — stop reading |
| R3 | θ on `LO`/`HI` | model cannot reach the data along that direction |
| R4 | venous params unidentifiable *after* compression | the manoeuvre failed |
| R5 | low compliance **+** floor arterial compliance | the pulse-amplitude failure |
| R6 | low outflow resistance **+** low compliance | degenerate `(E, Ro_tot)` valley |
| R7 | value frozen, rmse moving | coordinate never explored |
| R8 | same params, different steady state | autoregulation bistability |
| R9 | stream shrank or jumped | two writers |

**R2 outranks everything.** R1 and R5 are the two that will actually fire on this dataset,
and both are findings about the model rather than about a patient.

---

## What this rulebook cannot do

It reads combinations of six published numbers. It cannot see the raw θ against its bounds
(R3), the FIM's off-diagonal terms (R6), or which basin a solve landed in (R8) — all three
would need the estimator to publish more than it currently does. Rules R3, R6 and R8 are
therefore stated as *checks to run against the fit*, not as tests you can evaluate from the
API alone.
