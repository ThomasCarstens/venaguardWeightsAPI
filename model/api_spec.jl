# The parameter API: what each streamed quantity MEANS and where its bounds come from.
# ---------------------------------------------------------------------------
# Written as data, not prose, because every bound below is a claim someone will act on and
# each one needs its provenance attached. Three tiers of provenance appear here and they
# are NOT equivalent:
#
#   :clinical   a published human reference range for a directly measured quantity
#               (craniospinal compliance, CSF outflow resistance, sinus pressure, IJV area)
#   :model      no human reference range exists; the bounds are anchored on the model's own
#               literature default and are therefore a statement about M3/M5, not about
#               physiology. Do not report these to a clinician as normal ranges.
#   :qc         the quantity is being streamed as a CHECK on the fit rather than as a
#               property of the patient.
#
# THE DATASET HAS NO HEALTHY CONTROLS. All four recordings are ICU patients. Every
# "healthy" bound is literature, not a control group measured on this equipment with this
# pipeline. That is the weakest link in the whole API and it is recorded in every file.
#
#     julia --project=. Model_6/api_spec.jl    -> output/ude_cv_m6/api/params/*.json

ENV["_STAGE"] = "smoke"
include(joinpath(@__DIR__, "ude_cv.jl"))

const API   = OUT
const PDIR  = joinpath(API, "params")
mkpath(PDIR)

# derived-quantity converters, so the API streams CLINICAL units and not raw fit values
const SPEC = [
 (id = "craniospinal_compliance",
  unit = "mL/mmHg",
  from = "E",
  physiological_equivalent_description =
    "Craniospinal compliance: the volume the craniospinal space accepts per mmHg of ICP " *
    "rise. The bedside quantity behind PVI, RAP and 'compensatory reserve'. Falls as the " *
    "cranium is loaded; a low value means a small further volume produces a large ICP rise. " *
    "Computed as 1/(E*(ICP_baseline - Pcv)) from the fitted elastance coefficient E.",
  min_pathological_bound = 0.10, min_healthy_bound = 0.50,
  max_healthy_bound = 1.10,      max_pathological_bound = 2.00,
  bound_provenance = "clinical",
  bound_source = "craniospinal compliance 0.5-1.1 mL/mmHg in adults; <0.4 is reduced reserve",
  direction_of_concern = "low"),

 (id = "csf_outflow_resistance",
  unit = "mmHg/(mL/min)",
  from = "Ro_tot",
  physiological_equivalent_description =
    "Resistance to CSF absorption (Rout) - the quantity a lumbar infusion study measures " *
    "directly. Elevated in normal-pressure hydrocephalus and IIH; abnormally LOW suggests a " *
    "CSF leak, an open shunt, or a mis-specified cranial/spinal absorption split. Computed " *
    "as the parallel combination of the cranial (0.069) and spinal (0.931) routes.",
  min_pathological_bound = 3.0, min_healthy_bound = 6.0,
  max_healthy_bound = 10.0,     max_pathological_bound = 18.0,
  bound_provenance = "clinical",
  bound_source = "Rout 6-10 mmHg/(mL/min) normal; >12-13 supports NPH",
  direction_of_concern = "both"),

 (id = "arterial_compliance",
  unit = "mL/mmHg",
  from = "Ca",
  physiological_equivalent_description =
    "Cerebral arterial compliance: the arterial bed's volume response within a cardiac " *
    "cycle. Sets how much of each beat's stroke volume the arteries themselves absorb, and " *
    "is the parameter cerebrovascular reactivity indices (PRx) are sensitive to.",
  min_pathological_bound = 0.005, min_healthy_bound = 0.015,
  max_healthy_bound = 0.050,      max_pathological_bound = 0.100,
  bound_provenance = "model",
  bound_source = "anchored on M3's literature default Ca = 0.03 mL/mmHg; no human range",
  direction_of_concern = "low"),

 (id = "collateral_outflow_resistance",
  unit = "mmHg.s/mL",
  from = "Rvvs",
  physiological_equivalent_description =
    "Resistance of the vertebral venous plexus, the collateral route cerebral blood takes " *
    "when the jugular is obstructed. A high value means outflow CANNOT redistribute and the " *
    "jugular is functionally the only exit - which is what makes a compression raise ICP.",
  min_pathological_bound = 0.01, min_healthy_bound = 0.02,
  max_healthy_bound = 0.20,      max_pathological_bound = 2.00,
  bound_provenance = "model",
  bound_source = "anchored on M3's default Rvvs = 0.04 mmHg.s/mL; NO published human range",
  direction_of_concern = "high"),

 (id = "jugular_resting_area",
  unit = "cm2 per vein",
  from = "k_ijvs",
  physiological_equivalent_description =
    "Resting internal jugular cross-section implied by the fitted tube-law stiffness. " *
    "STREAMED AS QUALITY CONTROL, NOT AS A DIAGNOSIS: Model_6/structural_diagnosis shows " *
    "the fit drives this to 5-12 cm2 (about 205 mL of jugular) which is roughly ten times " *
    "physiological, and that this artefact is what causes the model's ICP pulse-amplitude " *
    "failure. A bedside ultrasound falsifies it in thirty seconds. Read a value outside the " *
    "healthy band as evidence the FIT is wrong, not that the patient is.",
  min_pathological_bound = 0.30, min_healthy_bound = 0.80,
  max_healthy_bound = 2.00,      max_pathological_bound = 4.00,
  bound_provenance = "qc",
  bound_source = "supine IJV cross-section ~0.8-2.0 cm2; posture- and respiration-dependent",
  direction_of_concern = "high"),

 (id = "sagittal_sinus_pressure",
  unit = "mmHg",
  from = "Psinus",
  physiological_equivalent_description =
    "Superior sagittal sinus pressure, the downstream boundary for cerebral venous outflow. " *
    "Elevated in venous sinus stenosis and IIH. STREAMED AS A NEGATIVE CONTROL: it is the " *
    "one parameter that stayed inside its healthy band in all four recordings, so a pipeline " *
    "that reports it as pathological has a bug rather than a finding.",
  min_pathological_bound = 2.0, min_healthy_bound = 5.0,
  max_healthy_bound = 8.0,      max_pathological_bound = 15.0,
  bound_provenance = "clinical",
  bound_source = "supine SSS pressure ~5-8 mmHg",
  direction_of_concern = "high"),
]

esc(s) = replace(string(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => " ")

function main()
    ids = String[]
    for s in SPEC
        push!(ids, s.id)
        open(joinpath(PDIR, "$(s.id).json"), "w") do io
            println(io, "{")
            println(io, "  \"id\": \"$(s.id)\",")
            println(io, "  \"unit\": \"$(esc(s.unit))\",")
            println(io, "  \"fitted_parameter\": \"$(s.from)\",")
            println(io, "  \"physiological_equivalent_description\": \"$(esc(s.physiological_equivalent_description))\",")
            println(io, "  \"min_pathological_bound\": $(s.min_pathological_bound),")
            println(io, "  \"min_healthy_bound\": $(s.min_healthy_bound),")
            println(io, "  \"max_healthy_bound\": $(s.max_healthy_bound),")
            println(io, "  \"max_pathological_bound\": $(s.max_pathological_bound),")
            println(io, "  \"direction_of_concern\": \"$(s.direction_of_concern)\",")
            println(io, "  \"bound_provenance\": \"$(s.bound_provenance)\",")
            println(io, "  \"bound_source\": \"$(esc(s.bound_source))\",")
            println(io, "  \"caveat\": \"No healthy controls exist in this dataset - all four ",
                        "recordings are ICU patients. Healthy bounds are from literature, not ",
                        "from a control group measured with this pipeline.\",")
            println(io, "  \"stream\": \"../stream/{patient}/$(s.id).jsonl\"")
            println(io, "}")
        end
        println("  wrote params/$(s.id).json  [$(s.bound_provenance)]")
    end
    open(joinpath(API, "index.json"), "w") do io
        println(io, "{")
        println(io, "  \"params\": [", join("\"" .* ids .* "\"", ", "), "],")
        println(io, "  \"patients\": [\"081\", \"083\", \"137\", \"150\"],")
        println(io, "  \"param_metadata\": \"params/{id}.json\",")
        println(io, "  \"stream\": \"stream/{patient}/{id}.jsonl\",")
        println(io, "  \"stream_record\": \"{t_end, value, ci_lo, ci_hi, status, identifiable, rmse, n_solves}\",")
        println(io, "  \"status_values\": [\"healthy\", \"borderline\", \"pathological\", \"unidentifiable\"],")
        # The COMPONENT view is generated by scripts/translate_stream.py, not here — but its
        # routes are advertised here, so regenerating this file must not silently drop them.
        println(io, "  \"components\": {")
        println(io, "    \"circuit\": \"circuit.json\",")
        println(io, "    \"component_meta\": \"components/{id}.json\",")
        println(io, "    \"stream\": \"stream/{patient}/_components.jsonl\",")
        println(io, "    \"record\": \"{t_end, n_parameters, rules_fired, rule_detail, components[]}\",")
        println(io, "    \"component\": \"{component, weight, direction, attribution, attribution_reason, lead_parameter, contributions[]}\",")
        println(io, "    \"attributions\": [\"patient\", \"model_referenced\", \"fit_quality\", \"model_artifact\", \"degenerate\", \"unidentifiable\"],")
        println(io, "    \"note\": \"weight 0 at the healthy edge, 1.0 at the pathological bound, discounted by identifiability. An ABSENT component is NOT ESTIMATED, not normal. attribution says whether the excursion is about the patient or about the fit.\",")
        println(io, "    \"regenerate\": \"python3 scripts/translate_stream.py\"")
        println(io, "  }")
        println(io, "}")
    end
    println("  wrote index.json ($(length(ids)) parameters)")
end
main()
