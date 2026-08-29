#!/usr/bin/env python3
"""The circuit segmentation, and the translation from fitted parameters to per-component
abnormality weights.

WHY THIS EXISTS. The API published six model parameters. A parameter is not a place — `E`
is a coefficient in a compliance law, `Ro_tot` is a lumped resistance split two ways — so a
reader has to already know the model to know *what* is abnormal. This module translates a
parameter vector into weights on the things a clinician can point at: the compartments whose
pressures the plotter draws against their hydrostatic columns, and the flow interfaces
between them.

THE SEGMENTATION follows the two hydrostatic panels in `Model_5/plotting.jl` /
`panels_shared.jl` (`build_tilt_panels`), which is what the user's plotter draws:

  tilt_pressures_heart   brain.ext.p (Pic) | brain.Rss.in.p (Psinus) | Hs_Pa.out.p (Psys)
                         against the HS brain column Hs_Rvvs.Δp
  tilt_pressures_spine   Ro_spine.in.p (Pds) | Ro_spine.out.p (Po_spine) |
                         Rivp.in.p (Pivp) | Revp.in.p (Pevp)
                         against the HS spine column Hs_Revp.Δp

Compartments carrying `hydrostatic_panel` are those the plotter references to a column;
the rest are nodes the circuit needs to close but which the panels do not draw.

WHAT A WEIGHT IS, AND IS NOT. `weight` is how far the governing parameter sits outside its
healthy band, on [0,1] to the pathological bound and above 1 beyond it, discounted by how
well that window identified the parameter. It is NOT a probability, and it is NOT
necessarily a statement about the patient: `attribution` says which. RULEBOOK.md R1 in
particular means a jugular/collateral excursion indicts the fit, so those components are
attributed `model_artifact` when R1 fires rather than reported as pathology.
"""

# --------------------------------------------------------------------------- (a) compartments
# Pressure nodes. `hydrostatic_panel` names the plotter panel that draws this pressure
# against a hydrostatic column; null means the circuit needs the node but no panel draws it.
COMPARTMENTS = [
    dict(id="cerebral_arterial", label="Cerebral arterial bed",
         state="V_a / C_a", hydrostatic_panel=None,
         description="The intracranial arterial compartment, with autoregulating compliance. "
                     "Its stroke volume is what each beat must push into the cranium.",
         plotter_trace=None),
    dict(id="intracranial_csf", label="Intracranial CSF / brain",
         state="Pic", hydrostatic_panel="tilt_pressures_heart",
         description="The intracranial compartment whose pressure IS the measured ICP. "
                     "Referenced to the heart-to-brain hydrostatic column.",
         plotter_trace="brain.ext.p"),
    dict(id="cerebral_venous", label="Cerebral venous compartment",
         state="Pv / V_v", hydrostatic_panel=None,
         description="Cerebral veins between the capillary bed and the dural sinus.",
         plotter_trace=None),
    dict(id="dural_sinus", label="Dural venous sinus",
         state="Psinus", hydrostatic_panel="tilt_pressures_heart",
         description="The sagittal/dural sinus. Sets the downstream pressure both cerebral "
                     "venous outflow and cranial CSF absorption drain into.",
         plotter_trace="brain.Rss.in.p"),
    dict(id="jugular_bulb", label="Jugular bulb / outflow junction",
         state="P_j", hydrostatic_panel=None,
         description="The junction where cerebral outflow divides between the internal "
                     "jugular and the vertebral collateral. This is where the compression acts.",
         plotter_trace=None),
    dict(id="spinal_dural_sac", label="Spinal dural sac",
         state="Psas", hydrostatic_panel="tilt_pressures_spine",
         description="The spinal CSF space (Pds). Takes CSF displaced from the cranium and "
                     "is the compliant reserve the craniospinal system draws on.",
         plotter_trace="Ro_spine.in.p"),
    dict(id="vertebral_plexus", label="Vertebral venous plexus",
         state="P_vv", hydrostatic_panel="tilt_pressures_spine",
         description="Internal/external vertebral plexus (Pivp ≡ Pevp). The alternative "
                     "drainage route when the jugular is occluded or the patient is upright.",
         plotter_trace="Rivp.in.p / Revp.in.p"),
    dict(id="paravertebral", label="Paravertebral / azygos",
         state="P_px", hydrostatic_panel="tilt_pressures_spine",
         description="The paravertebral compartment spinal CSF absorbs into and the plexus "
                     "drains through (Po_spine).",
         plotter_trace="Ro_spine.out.p"),
    dict(id="systemic_venous", label="Systemic venous return",
         state="P_sys", hydrostatic_panel="tilt_pressures_heart",
         description="The systemic venous pool returning to the right heart (Psys).",
         plotter_trace="Hs_Pa.out.p"),
]

# --------------------------------------------------------------------------- (b) interfaces
# Flow elements. `frm`/`to` are compartment ids above.
INTERFACES = [
    dict(id="arteriolar_bed", label="Arteriolar bed (autoregulated)",
         frm="cerebral_arterial", to="cerebral_venous", element="Ra",
         description="Autoregulating arteriolar resistance. Sets cerebral blood flow and, "
                     "through its compliance, the size of the arterial pulse entering the cranium."),
    dict(id="capillary_bed", label="Capillary bed",
         frm="cerebral_arterial", to="cerebral_venous", element="Rc",
         description="Capillary resistance between the arterial and venous compartments."),
    dict(id="cerebral_venous_outflow", label="Cerebral venous outflow",
         frm="cerebral_venous", to="dural_sinus", element="Rv",
         description="Drainage from the cerebral veins into the dural sinus."),
    dict(id="csf_absorption_cranial", label="CSF absorption, cranial",
         frm="intracranial_csf", to="dural_sinus", element="Ro (0.069·Ro_tot)",
         description="Arachnoid granulation absorption of CSF into the sinus. One-way."),
    dict(id="craniospinal_csf_channel", label="Craniospinal CSF channel",
         frm="intracranial_csf", to="spinal_dural_sac", element="Rspine",
         description="The foramen magnum route. Lets CSF displace from cranium to spinal sac, "
                     "which is how the craniospinal compliance reserve is reached."),
    dict(id="csf_absorption_spinal", label="CSF absorption, spinal",
         frm="spinal_dural_sac", to="paravertebral", element="Ro_spine (0.931·Ro_tot)",
         description="Spinal CSF absorption — the larger share of total outflow resistance."),
    dict(id="sinus_to_jugular", label="Sinus to jugular bulb",
         frm="dural_sinus", to="jugular_bulb", element="Rss",
         description="Transverse/sigmoid sinus run from the dural sinus to the bulb."),
    dict(id="internal_jugular", label="Internal jugular vein",
         frm="jugular_bulb", to="systemic_venous", element="Rijvs (collapsible tube law)",
         description="The dominant venous outflow route when supine. A collapsible tube: "
                     "external pressure collapses its area A and its resistance rises as ~A⁻². "
                     "This is the vessel the compression manoeuvre occludes."),
    dict(id="vertebral_collateral", label="Vertebral venous collateral",
         frm="jugular_bulb", to="vertebral_plexus", element="Rvvs",
         description="The parallel outflow path. Carries cerebral outflow when the jugular "
                     "closes; if its resistance is low the occlusion costs almost nothing."),
    dict(id="plexus_drainage", label="Vertebral plexus drainage",
         frm="vertebral_plexus", to="paravertebral", element="Rivp / Revp",
         description="Drainage of the vertebral plexus into the paravertebral compartment."),
    dict(id="azygos_return", label="Azygos return",
         frm="paravertebral", to="systemic_venous", element="Razy",
         description="Azygos/hemiazygos return to the systemic venous pool."),
    dict(id="plexus_shunt", label="Plexus to systemic shunt",
         frm="vertebral_plexus", to="systemic_venous", element="Rt",
         description="Direct low-resistance connection from the plexus to systemic return."),
]

# --------------------------------------------------------------------------- the mapping
# Which streamed parameter governs which component, and with what share. `share` weights a
# parameter that is split across several components (Ro_tot is 0.069/0.931 cranial/spinal);
# it does NOT rescale severity, it apportions attribution.
#
# `role` records WHAT the parameter says about the component, so a reader can tell a
# storage property from a conductance one without knowing the model.
GOVERNS = [
    dict(param="craniospinal_compliance", component="intracranial_csf",
         share=0.3, role="storage",
         note="E sets Ctot = 1/(E·(Pic−Pcv)); α=0.3 of it is the cranial share."),
    dict(param="craniospinal_compliance", component="spinal_dural_sac",
         share=0.7, role="storage",
         note="the remaining 1−α of craniospinal compliance is spinal."),
    dict(param="csf_outflow_resistance", component="csf_absorption_cranial",
         share=0.069, role="conductance",
         note="Ro = 0.069·Ro_tot."),
    dict(param="csf_outflow_resistance", component="csf_absorption_spinal",
         share=0.931, role="conductance",
         note="Ro_spine = 0.931·Ro_tot — the dominant share."),
    dict(param="arterial_compliance", component="cerebral_arterial",
         share=1.0, role="storage",
         note="Ca is the arterial compartment's compliance; it also scales the "
              "autoregulatory range ΔC."),
    dict(param="collateral_outflow_resistance", component="vertebral_collateral",
         share=1.0, role="conductance",
         note="Rvvs is the collateral resistance directly."),
    dict(param="jugular_resting_area", component="internal_jugular",
         share=1.0, role="geometry",
         note="derived from k_ijvs through the tube law at rest; governs how readily the "
              "vein collapses under the compression."),
    dict(param="sagittal_sinus_pressure", component="dural_sinus",
         share=1.0, role="boundary_pressure",
         note="Psinus is the sinus compartment's operating pressure, a boundary condition "
              "rather than a property of a wall."),
]


# --------------------------------------------------------------------------- severity
def severity(value, b):
    """Signed distance outside the healthy band, in units of 'healthy edge -> pathological edge'.

    0.0 anywhere inside [min_healthy, max_healthy]; 1.0 exactly at a pathological bound;
    >1 beyond it. Sign is the DIRECTION of the excursion (+ high, − low).

    Piecewise-linear rather than smooth on purpose: a clinician reading this needs
    'how many bands out' to be arithmetic they can check, not a curve with a shape
    that has to be justified.
    """
    lo_p, lo_h, hi_h, hi_p = (b["min_pathological_bound"], b["min_healthy_bound"],
                              b["max_healthy_bound"], b["max_pathological_bound"])
    if value is None or value != value:            # None or NaN
        return None
    if lo_h <= value <= hi_h:
        return 0.0
    if value > hi_h:
        span = hi_p - hi_h
        return (value - hi_h) / span if span > 0 else float("inf")
    span = lo_h - lo_p
    return -((lo_h - value) / span) if span > 0 else float("-inf")


def confidence(rec, b):
    """How much of the healthy band the confidence interval spans, mapped to [0,1].

    An interval wider than the whole healthy band tells you nothing about which side of it
    the value is on, so it scores 0. `identifiable: false` is hard 0 regardless — the
    stream sets that flag when the Fisher interval is uninformative, and no width
    calculation should be allowed to override it.
    """
    if not rec.get("identifiable", False):
        return 0.0
    lo, hi = rec.get("ci_lo"), rec.get("ci_hi")
    if lo is None or hi is None or hi != hi or lo != lo:
        return 0.0
    band = b["max_healthy_bound"] - b["min_healthy_bound"]
    if band <= 0:
        return 0.0
    frac = (hi - lo) / band
    return max(0.0, min(1.0, 1.0 - frac))


# --------------------------------------------------------------------------- rulebook
def rules_fired(values, statuses):
    """RULEBOOK.md rules evaluable from one window's values. Returns {rule: explanation}.

    Only the rules that change ATTRIBUTION are implemented — R1 (the tube-law escape) and
    R6 (the E/Ro_tot degeneracy). The rest need cross-window or raw-θ context the component
    view does not carry, and inventing a single-window proxy for them would be worse than
    leaving them to the reader.
    """
    fired = {}
    if statuses.get("collateral_outflow_resistance") in ("pathological", "critical") and \
       statuses.get("jugular_resting_area") in ("pathological", "critical"):
        fired["R1"] = ("tube-law escape: the fit inflated the resting jugular AND blocked "
                       "the collateral to manufacture the ICP step. Neither is a statement "
                       "about the patient.")
    if statuses.get("csf_outflow_resistance") in ("pathological", "critical") and \
       statuses.get("craniospinal_compliance") in ("pathological", "critical"):
        fired["R6"] = ("degenerate pair: Ro_tot down and E up trade against each other along "
                       "a valley the mean-ICP residual barely distinguishes. Read as ONE "
                       "poorly-determined combination, not two findings.")
    return fired


R1_COMPONENTS = {"internal_jugular", "vertebral_collateral"}
R6_COMPONENTS = {"csf_absorption_cranial", "csf_absorption_spinal",
                 "intracranial_csf", "spinal_dural_sac"}


def translate(window, metas):
    """One window of parameter records -> component weights.

    `window`  {param_id: stream record}
    `metas`   {param_id: parameter metadata (bounds)}
    returns   (components, rules)
    """
    values   = {k: r.get("value") for k, r in window.items()}
    statuses = {k: r.get("status") for k, r in window.items()}
    fired = rules_fired(values, statuses)

    by_component = {}
    for g in GOVERNS:
        pid, cid = g["param"], g["component"]
        rec, b = window.get(pid), metas.get(pid)
        if rec is None or b is None:
            continue
        sev = severity(rec.get("value"), b)
        if sev is None:
            continue
        conf = confidence(rec, b)
        by_component.setdefault(cid, []).append(dict(
            param=pid, severity=sev, confidence=conf, share=g["share"],
            role=g["role"], value=rec.get("value"),
            status=rec.get("status"), identifiable=rec.get("identifiable", False),
            provenance=b.get("bound_provenance"), note=g["note"]))

    out = []
    for cid, contribs in by_component.items():
        # The component's weight is the LARGEST confidence-discounted excursion among its
        # governing parameters, not their sum: two parameters both mildly out is not
        # evidence of one severely-abnormal component, and summing would say it was.
        scored = [abs(c["severity"]) * c["confidence"] for c in contribs]
        weight = max(scored) if scored else 0.0
        lead = contribs[int(max(range(len(scored)), key=lambda i: scored[i]))] if scored else None

        if all(not c["identifiable"] for c in contribs):
            attribution, why = "unidentifiable", ("no governing parameter was identifiable in "
                                                  "this window — the value is guessed, not measured")
        elif "R1" in fired and cid in R1_COMPONENTS:
            attribution, why = "model_artifact", fired["R1"]
        elif any(c["provenance"] == "qc" for c in contribs):
            attribution, why = "fit_quality", ("this component's bound is a QC check on the fit, "
                                               "not a physiological range")
        elif "R6" in fired and cid in R6_COMPONENTS:
            attribution, why = "degenerate", fired["R6"]
        elif any(c["provenance"] == "model" for c in contribs):
            attribution, why = "model_referenced", ("bounds anchored on the source model's "
                                                    "default, not on a published human range")
        else:
            attribution, why = "patient", "clinical bounds, identifiable in this window"

        out.append(dict(
            component=cid, weight=round(weight, 4),
            direction=("high" if lead and lead["severity"] > 0 else
                       "low" if lead and lead["severity"] < 0 else "within"),
            attribution=attribution, attribution_reason=why,
            lead_parameter=lead["param"] if lead else None,
            contributions=[dict(param=c["param"], severity=round(c["severity"], 4),
                                confidence=round(c["confidence"], 4), role=c["role"],
                                value=c["value"], status=c["status"],
                                identifiable=c["identifiable"]) for c in contribs]))
    out.sort(key=lambda d: -d["weight"])
    return out, fired
