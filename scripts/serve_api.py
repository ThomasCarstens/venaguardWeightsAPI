#!/usr/bin/env python3
"""Serve the Model_6 parameter API over HTTP. Standard library only — no new deps.

The API is FILE-BACKED: model/stream_refit.jl appends a JSON object per window and
flushes, so this server reads whatever is on disk at request time. A refit that is still
running is served live; `?since=` lets a client poll for only the new records.

    .venv-dash/bin/python3 scripts/serve_api.py            # http://127.0.0.1:8770
    .venv-dash/bin/python3 scripts/serve_api.py --check     # validate, don't serve

Endpoints
    GET /                                  index: parameters, patients, route templates
    GET /params                            all parameter metadata, as one object
    GET /params/<id>                       one parameter's description + bounds
    GET /stream/<patient>/<id>             the full stream, newest last
    GET /stream/<patient>/<id>?since=<t>   only records with t_end > t  (incremental poll)
    GET /latest/<patient>                  most recent value of every parameter + status
    GET /events/<patient>                  the compression window, for marking on a time axis
    GET /dashboard                         standing-watch page (web/dashboard.html)

  The COMPONENT view — the same fit expressed as weights on circuit parts rather than on
  model parameters. This is what a reader who does not know the model should consume.
    GET /circuit                           the segmentation: compartments + interfaces
    GET /components                        every component's static metadata
    GET /components/<id>                   one component
    GET /components/<patient>/stream       component weights, one record per window
        ?since=<t>                         only windows with t_end > t
    GET /components/<patient>/latest       the most recent window, ranked by weight
"""
import json, os, re, sys, argparse, errno, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "api")
WEB = os.path.join(ROOT, "web")


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


def _events(patient):
    """The jugular compression, as prepared: the CSVs are re-based so t = 0 is t_on, so the
    manoeuvre occupies [0, duration]. Without this a client cannot say WHEN an interval
    collapsed relative to the thing that supplied the information. Returns None if data/ is
    absent (it is gitignored) and clients must degrade rather than fail."""
    p = os.path.join(ROOT, "data", "jugular_prepared", "events.json")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        ev = json.load(f).get(patient)
    if ev is None:
        return None
    return {"t_on": 0.0, "t_off": ev["duration"], "duration": ev["duration"],
            "icp_base": ev.get("icp_base"), "icp_plateau": ev.get("icp_plateau"),
            "hr_bpm": ev.get("hr_bpm")}


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


def _port_holder(port):
    """(pid, cmdline) of whoever is listening on `port`, or None. Best-effort: parses `ss`,
    and simply gives up if it is unavailable rather than guessing."""
    try:
        out = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if f":{port} " not in line and not line.rstrip().endswith(f":{port}"):
            if f":{port}" not in line:
                continue
        m = re.search(r"pid=(\d+)", line)
        if not m:
            continue
        pid = m.group(1)
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            cmd = "?"
        return pid, cmd
    return None


def _circuit():
    p = os.path.join(API, "circuit.json")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        return json.load(f)


def _component_meta(cid):
    p = os.path.join(API, "components", f"{cid}.json")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        return json.load(f)


def _components(patient, since=None):
    """The translated stream. Same torn-final-line tolerance as _stream: translate_stream.py
    may be re-running while a client polls."""
    p = os.path.join(API, "stream", patient, "_components.jsonl")
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
                continue
            if since is None or rec.get("t_end", -1e9) > since:
                out.append(rec)
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

    def _send_html(self, path):
        """Serve the dashboard from the API's own origin, so N browser windows can poll it
        with no CORS and no build step. Read per request: edit the file, reload the tab."""
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            return self._send({"error": "not found", "detail": path}, 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        q = parse_qs(u.query)
        try:
            if not parts:
                return self._send(_index())
            if parts[0] == "dashboard":
                return self._send_html(os.path.join(WEB, "dashboard.html"))
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
            if parts[0] == "circuit":
                c = _circuit()
                return self._send(c) if c else self._send(
                    {"error": "no circuit.json", "fix": "python3 scripts/translate_stream.py"}, 404)
            if parts[0] == "components":
                if len(parts) == 1:
                    c = _circuit()
                    if not c:
                        return self._send({"error": "no circuit.json"}, 404)
                    return self._send({d["id"]: d for d in c["compartments"] + c["interfaces"]})
                # /components/<patient>/stream|latest  vs  /components/<component_id>
                if len(parts) == 3 and parts[2] in ("stream", "latest"):
                    since = float(q["since"][0]) if "since" in q else None
                    recs = _components(parts[1], since if parts[2] == "stream" else None)
                    if recs is None:
                        return self._send({"error": "no component stream", "patient": parts[1],
                                           "fix": "python3 scripts/translate_stream.py"}, 404)
                    if parts[2] == "latest":
                        return self._send({"patient": parts[1],
                                           "window": recs[-1] if recs else None,
                                           "n_windows": len(recs)})
                    return self._send({"patient": parts[1], "n": len(recs), "records": recs})
                m = _component_meta(parts[1])
                return self._send(m) if m else self._send({"error": "no such component"}, 404)
            if parts[0] == "events" and len(parts) == 2:
                e = _events(parts[1])
                return self._send(e) if e else self._send({"error": "no events"}, 404)
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

    # --- the component view -------------------------------------------------
    print()
    c = _circuit()
    if c is None:
        print("  circuit.json MISSING — run python3 scripts/translate_stream.py")
        return 1 if bad else 0
    comps = c["compartments"] + c["interfaces"]
    obs = [x["id"] for x in comps if x["observable"]]
    print(f"circuit: {len(c['compartments'])} compartments + {len(c['interfaces'])} "
          f"interfaces, {len(obs)} observable")
    # every component a parameter claims to govern must exist in the segmentation
    known = {x["id"] for x in comps}
    for x in comps:
        for g in x["governed_by"]:
            if g["param"] not in idx["params"]:
                print(f"  {x['id']}: governed_by unknown parameter {g['param']}"); bad += 1
    # and every parameter must govern something, or it is published and unreachable
    governed = {g["param"] for x in comps for g in x["governed_by"]}
    orphan = [p for p in idx["params"] if p not in governed]
    if orphan:
        print(f"  parameters governing NO component: {orphan}"); bad += 1
    for pat in idx["patients"]:
        recs = _components(pat)
        if not recs:
            print(f"  patient {pat}: no component stream"
                  "   (run python3 scripts/translate_stream.py)")
            continue
        last = recs[-1]
        unknown = [d["component"] for d in last["components"] if d["component"] not in known]
        if unknown:
            print(f"  patient {pat}: components not in circuit.json {unknown}"); bad += 1
            continue
        att = {}
        for d in last["components"]:
            att[d["attribution"]] = att.get(d["attribution"], 0) + 1
        top = last["components"][0] if last["components"] else None
        print(f"  patient {pat}: {len(recs)} windows, "
              f"lead {top['component']} w={top['weight']:.2f} ({top['attribution']})"
              f"   rules={last['rules_fired'] or '-'}   {att}")
    return 1 if bad else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--port", type=int, default=8770)
    a = ap.parse_args()
    if a.check:
        sys.exit(check())
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        # A traceback here says "socketserver.py line 457", which is true and useless. The
        # actual situation is always the same: an earlier server is still up. Say so, name
        # the process, and give the two ways out.
        holder = _port_holder(a.port)
        print(f"port {a.port} is already in use", file=sys.stderr)
        if holder:
            pid, cmd = holder
            print(f"  held by pid {pid}: {cmd}", file=sys.stderr)
            print(f"  reuse it:  curl -s http://127.0.0.1:{a.port}/", file=sys.stderr)
            print(f"  or stop it: kill {pid}", file=sys.stderr)
        else:
            print("  (could not identify the process; try `ss -ltnp | grep "
                  f"{a.port}`)", file=sys.stderr)
        print(f"  or pick another port:  {sys.argv[0]} --port {a.port + 1}", file=sys.stderr)
        sys.exit(2)
    print(f"serving {API}\n  http://127.0.0.1:{a.port}/")
    print(f"  http://127.0.0.1:{a.port}/params/craniospinal_compliance")
    print(f"  http://127.0.0.1:{a.port}/latest/081")
    print(f"  http://127.0.0.1:{a.port}/dashboard      <- open in as many windows as you like")
    srv.serve_forever()
