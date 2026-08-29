#!/usr/bin/env python3
"""Serve the Model_6 parameter API over HTTP. Standard library only — no new deps.

The API is FILE-BACKED: model/stream_refit.jl appends a JSON object per window and
flushes, so this server reads whatever is on disk at request time. A refit that is still
running is served live; `?since=` lets a client poll for only the new records.

    .venv-dash/bin/python3 scripts/serve_api.py            # http://127.0.0.1:877
    .venv-dash/bin/python3 scripts/serve_api.py --check     # validate, don't serve

Endpoints
    GET /                                  index: parameters, patients, route templates
    GET /params                            all parameter metadata, as one object
    GET /params/<id>                       one parameter's description + bounds
    GET /stream/<patient>/<id>             the full stream, newest last
    GET /stream/<patient>/<id>?since=<t>   only records with t_end > t  (incremental poll)
    GET /latest/<patient>                  most recent value of every parameter + status
"""
import json, os, sys, argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "api")


def _index():
    with open(os.path.join(API, "index.json")) as f:
        return json.load(f)


def _meta(pid):
    p = os.path.join(API, "params", f"{pid}.json")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        return json.load(f)


def _stream(patient, pid, since=None):
    """Read a .jsonl. Tolerates a partially-written final line: a refit in progress may be
    mid-write, and dropping that one record is correct rather than raising."""
    p = os.path.join(API, "stream", patient, f"{pid}.jsonl")
    if not os.path.isfile(p):
        return None
    out = []
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue          # torn final line while the writer is running
            if since is None or rec.get("t_end", -1e9) > since:
                out.append(rec)
    return out


def _latest(patient):
    idx = _index()
    out = {}
    for pid in idx["params"]:
        recs = _stream(patient, pid)
        if not recs:
            continue
        r = recs[-1]
        m = _meta(pid) or {}
        out[pid] = {
            "value": r.get("value"),
            "ci_lo": r.get("ci_lo"),
            "ci_hi": r.get("ci_hi"),
            "status": r.get("status"),
            "identifiable": r.get("identifiable"),
            "t_end": r.get("t_end"),
            "unit": m.get("unit"),
            "healthy_range": [m.get("min_healthy_bound"), m.get("max_healthy_bound")],
            "bound_provenance": m.get("bound_provenance"),
            "n_records": len(recs),
        }
    return out


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        q = parse_qs(u.query)
        try:
            if not parts:
                return self._send(_index())
            if parts[0] == "params":
                if len(parts) == 1:
                    return self._send({p: _meta(p) for p in _index()["params"]})
                m = _meta(parts[1])
                return self._send(m) if m else self._send({"error": "no such parameter"}, 404)
            if parts[0] == "stream" and len(parts) == 3:
                since = float(q["since"][0]) if "since" in q else None
                s = _stream(parts[1], parts[2], since)
                if s is None:
                    return self._send({"error": "no such stream"}, 404)
                return self._send({"patient": parts[1], "param": parts[2],
                                   "n": len(s), "records": s})
            if parts[0] == "latest" and len(parts) == 2:
                return self._send({"patient": parts[1], "params": _latest(parts[1])})
            return self._send({"error": "unknown route", "see": "/"}, 404)
        except Exception as e:                      # never 500 silently
            return self._send({"error": type(e).__name__, "detail": str(e)}, 500)

    def log_message(self, *a):
        pass                                        # quiet


def check():
    """Validate the API on disk without serving. Exit non-zero if it is not coherent."""
    bad = 0
    if not os.path.isdir(API):
        print(f"MISSING: {API} — run model/api_spec.jl"); return 1
    idx = _index()
    print(f"index: {len(idx['params'])} params, {len(idx['patients'])} patients\n")
    REQ = ["physiological_equivalent_description", "min_pathological_bound",
           "min_healthy_bound", "max_healthy_bound", "max_pathological_bound"]
    for pid in idx["params"]:
        m = _meta(pid)
        if m is None:
            print(f"  {pid}: METADATA MISSING"); bad += 1; continue
        miss = [k for k in REQ if k not in m]
        if miss:
            print(f"  {pid}: missing keys {miss}"); bad += 1; continue
        b = [m["min_pathological_bound"], m["min_healthy_bound"],
             m["max_healthy_bound"], m["max_pathological_bound"]]
        if not (b[0] < b[1] < b[2] < b[3]):
            print(f"  {pid}: BOUNDS NOT ORDERED {b}"); bad += 1; continue
        print(f"  {pid:<32} {str(b):<28} [{m['bound_provenance']}]")
    print()
    for pat in idx["patients"]:
        got = {p: _stream(pat, p) for p in idx["params"]}
        n = {k: (len(v) if v else 0) for k, v in got.items()}
        tot = sum(n.values())
        print(f"  patient {pat}: {tot} records" +
              ("" if tot else "   (no stream yet — run model/stream_refit.jl)"))
    return 1 if bad else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--port", type=int, default=877)
    a = ap.parse_args()
    if a.check:
        sys.exit(check())
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"serving {API}\n  http://127.0.0.1:{a.port}/")
    print(f"  http://127.0.0.1:{a.port}/params/craniospinal_compliance")
    print(f"  http://127.0.0.1:{a.port}/latest/081")
    srv.serve_forever()
