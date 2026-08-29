#!/usr/bin/env python3
"""Generate the component view: circuit spec + per-window component weights.

Reads what the refit already wrote (`api/params/*.json`, `api/stream/<patient>/*.jsonl`)
and writes the translated view beside it. No solving, no Julia — this is post-processing,
so it can be re-run in a second whenever the translation logic changes without redoing a
70-minute refit.

    python3 scripts/translate_stream.py            # all patients found on disk
    python3 scripts/translate_stream.py 081 083    # only these

Writes
    api/circuit.json                             the segmentation: compartments + interfaces
    api/components/<id>.json                     one file per component, static metadata
    api/stream/<patient>/_components.jsonl       one record per window, weights for all
"""
import json, os, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from circuit import COMPARTMENTS, INTERFACES, GOVERNS, translate   # noqa: E402

ROOT = os.path.dirname(HERE)
API = os.path.join(ROOT, "api")


def _load_metas():
    metas = {}
    for f in glob.glob(os.path.join(API, "params", "*.json")):
        d = json.load(open(f))
        metas[d["id"]] = d
    return metas


def _load_streams(patient):
    """{param_id: [records]} for one patient, only the six real parameter streams."""
    out = {}
    d = os.path.join(API, "stream", patient)
    for f in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
        pid = os.path.basename(f)[:-6]
        if pid.startswith("_"):          # our own output, not an input
            continue
        recs = []
        for line in open(f):
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError:
                continue                 # torn final line while a writer runs
        if recs:
            out[pid] = recs
    return out


def write_circuit():
    """The segmentation, plus the parameter->component map, as one served document."""
    gov_by_component = {}
    for g in GOVERNS:
        gov_by_component.setdefault(g["component"], []).append(
            dict(param=g["param"], share=g["share"], role=g["role"], note=g["note"]))

    def _decorate(items, kind):
        out = []
        for it in items:
            d = dict(it); d["kind"] = kind
            d["governed_by"] = gov_by_component.get(it["id"], [])
            d["observable"] = bool(d["governed_by"])
            out.append(d)
        return out

    doc = dict(
        description=(
            "Segmentation of the Model 6 cerebral circuit into (a) COMPARTMENTS — pressure "
            "nodes, of which those carrying `hydrostatic_panel` are the ones the plotter "
            "draws against their hydrostatic column — and (b) INTERFACES, the flow elements "
            "between them."),
        hydrostatic_panels={
            "tilt_pressures_heart": "Pic, Psinus, Psys against the heart->brain column (Hs_Rvvs.Δp)",
            "tilt_pressures_spine": "Pds, Po_spine, Pivp, Pevp against the spine column (Hs_Revp.Δp)",
        },
        caveat=(
            "Only 6 of the 21 components are governed by a streamed parameter "
            "(`observable: true`). The rest are fixed at model defaults and are listed so the "
            "topology is complete — an absent weight means NOT ESTIMATED, never NORMAL."),
        compartments=_decorate(COMPARTMENTS, "compartment"),
        interfaces=_decorate(INTERFACES, "interface"),
    )
    with open(os.path.join(API, "circuit.json"), "w") as f:
        json.dump(doc, f, indent=2)

    cdir = os.path.join(API, "components")
    os.makedirs(cdir, exist_ok=True)
    for it in doc["compartments"] + doc["interfaces"]:
        with open(os.path.join(cdir, f"{it['id']}.json"), "w") as f:
            json.dump(it, f, indent=2)
    n_obs = sum(1 for it in doc["compartments"] + doc["interfaces"] if it["observable"])
    print(f"circuit.json: {len(COMPARTMENTS)} compartments + {len(INTERFACES)} interfaces "
          f"({n_obs} observable)")


def translate_patient(patient, metas):
    streams = _load_streams(patient)
    if not streams:
        print(f"  {patient}: no streams"); return 0
    # windows are keyed by t_end; a parameter missing a window simply does not contribute
    t_ends = sorted({r["t_end"] for recs in streams.values() for r in recs})
    outp = os.path.join(API, "stream", patient, "_components.jsonl")
    n = 0
    with open(outp, "w") as f:
        for t in t_ends:
            window = {}
            for pid, recs in streams.items():
                hit = [r for r in recs if r["t_end"] == t]
                if hit:
                    window[pid] = hit[-1]
            comps, fired = translate(window, metas)
            rec = dict(t_end=t, n_parameters=len(window),
                       rules_fired=sorted(fired.keys()),
                       rule_detail=fired, components=comps)
            f.write(json.dumps(rec) + "\n")
            n += 1
    top = comps[0] if comps else None
    print(f"  {patient}: {n} windows -> _components.jsonl"
          + (f"   final lead: {top['component']} w={top['weight']:.2f} "
             f"({top['attribution']})" if top else ""))
    return n


def main():
    want = sys.argv[1:]
    metas = _load_metas()
    if not metas:
        sys.exit("no api/params/*.json — run model/api_spec.jl first")
    write_circuit()
    pats = want or sorted(d for d in os.listdir(os.path.join(API, "stream"))
                          if os.path.isdir(os.path.join(API, "stream", d)))
    print(f"translating {len(pats)} patient(s)")
    for p in pats:
        translate_patient(p, metas)


if __name__ == "__main__":
    main()
