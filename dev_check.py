#!/usr/bin/env python3
"""Self-tests for FieldLab's Mac half — the stream server and the file format between the phone
and this machine. Stdlib only; runs without the analysis venv and uses it when present.

    python3 dev_check.py

Most of these pin a REFUSAL (a bad chunk is rejected, a blocked path is blocked) or a PARITY
(three copies of the CSV header in three languages agree; the Swift-written fixture decodes here).
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "analysis"))

PASS, FAIL = [], []


def _iso_z(epoch: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")



def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(f"{name}{(' — ' + detail) if detail else ''}")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def http(method, url, body=None, headers=None, timeout=10):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# ---------------------------------------------------------------- parity: one CSV header, three files
swift = (HERE / "BiomimeticRadar/Processing/StreamChunk.swift").read_text()
m = re.search(r'static let csvHeader = "([^"]+)"', swift)
swift_header = m.group(1) if m else None
import serve  # noqa: E402

with tempfile.TemporaryDirectory() as _envdir:
    _env = Path(_envdir, "fieldlab.env")
    _env.write_text("# a comment\nFIELDLAB_ANALYSIS=study/analysis\nFIELDLAB_PREFIXES=a,b\nNOT_OURS=x\n")
    _saved = {k: os.environ.pop(k, None) for k in ("FIELDLAB_ANALYSIS", "FIELDLAB_PREFIXES", "NOT_OURS")}
    os.environ["FIELDLAB_PREFIXES"] = "from-env"
    serve._load_local_env(_env)
    check("fieldlab.env: relative paths resolve beside the file, the real environment wins, other keys ignored",
          os.environ.get("FIELDLAB_ANALYSIS") == str(Path(_envdir, "study/analysis").resolve())
          and os.environ.get("FIELDLAB_PREFIXES") == "from-env" and "NOT_OURS" not in os.environ)
    for _k, _v in _saved.items():
        os.environ.pop(_k, None)
        if _v is not None:
            os.environ[_k] = _v
check("parity: StreamChunk.swift csvHeader == serve.py CSV_HEADER", swift_header == serve.CSV_HEADER, str(swift_header)[:60])
# The writer and the reader of the format live in this repo, so the parity check cannot be skipped.
sys.path.insert(0, str(HERE / "analysis"))
session_py = (HERE / "session.py").read_text()
for col in ("monotonic_s", "mx_uT", "my_uT", "mz_uT", "magnitude_uT", "wall_clock"):
    check(f"parity: session.py reads column {col}", f'"{col}"' in session_py)

import ast as _ast
_ALLOWED = {"__future__", "csv", "json", "dataclasses", "datetime", "pathlib", "numpy", "bands", "store"}
for _name in ("session.py", "census.py"):
    _tree = _ast.parse((HERE / _name).read_text())
    _mods = {(n.module or "").split(".")[0] for n in _ast.walk(_tree) if isinstance(n, _ast.ImportFrom)}
    _mods |= {a.name.split(".")[0] for n in _ast.walk(_tree) if isinstance(n, _ast.Import) for a in n.names}
    _rel = [n for n in _ast.walk(_tree) if isinstance(n, _ast.ImportFrom) and n.level]
    check(f"{_name} imports only stdlib, numpy and this repo's bands and store", _mods <= _ALLOWED and not _rel,
          str(sorted(_mods - _ALLOWED)) + (" + relative imports" if _rel else ""))
# The app was cut back to a pure recorder on 2026-08-23: there is no on-phone export screen any
# more, so there is no second CSV encoder to keep in step. The spool IS the export.
check("the app has no export screen (the spool is the export)",
      not (HERE / "BiomimeticRadar/Services/ExportManager.swift").exists())
check("the spool lives in Documents so it is reachable from the Files app",
      "documentDirectory" in (HERE / "BiomimeticRadar/Services/StreamUploader.swift").read_text())
check("post_chunks.py exists as the manual escape hatch for an unsent spool",
      (HERE / "analysis/post_chunks.py").exists())

# The recorder app must not compile the analysis engines — that is the whole point of the trim.
project_yml = (HERE / "project.yml").read_text()
for excluded in ("Processing/SignalProcessor.swift", "Processing/SignalCensus.swift",
                 "Processing/CrossBandCoupling.swift", "Models/ExperimentModels.swift"):
    check(f"the app target excludes {excluded}", excluded in project_yml)
for gone in ("Views/ResultsView.swift", "Views/ExperimentView.swift", "Views/CensusView.swift",
             "Services/AppModel.swift"):
    check(f"the analysis surface {gone} is gone from the app", not (HERE / "BiomimeticRadar" / gone).exists())
check("the app still builds the recorder half",
      all((HERE / "BiomimeticRadar" / f).exists() for f in
          ("Views/StreamView.swift", "Services/RecorderModel.swift", "Services/StreamController.swift",
           "Services/EnvironmentProbe.swift", "Models/SensorModels.swift")))
check("serve.py has a plain DEFAULT_PORT line a launcher can read",
      re.search(r"^DEFAULT_PORT = \d{4}$", (HERE / "serve.py").read_text(), re.M) is not None)
check("streams/ is gitignored", "streams/" in (HERE / ".gitignore").read_text())
check("fieldlab.env is gitignored", "fieldlab.env" in (HERE / ".gitignore").read_text())
check("no folder here is named recordings/ (proxies that guard private data refuse it)",
      not (HERE / "recordings").exists())

# ------------------------------------------------------------------ standalone properties
import tools_path as _tp  # noqa: E402
check("optional siblings are reached through ONE module",
      _tp.__doc__ is not None and "OPTIONAL" in _tp.__doc__.upper())
check("the consuming analysis comes from FIELDLAB_ANALYSIS, never a built-in study path",
      'os.environ.get("FIELDLAB_ANALYSIS")' in (HERE / "serve.py").read_text()
      and "falsify" not in (HERE / "serve.py").read_text())
check("no findings document is stored in this repo",
      not list(HERE.glob("**/sessions/*.md")) and not (HERE / "claims").exists())

# ---------------------------------------------------------------- the Swift-written fixture decodes
fixture = HERE / "analysis/fixtures/sample.chunk"
check("fixture sample.chunk exists (written by swift test)", fixture.exists())
file = zlib.decompressobj(-15).decompress(fixture.read_bytes())
header_line, csv_text = file.split(b"\n", 1)
header = json.loads(header_line)
check("fixture header is one JSON line with the format tag", header.get("format") == serve.FORMAT)
check("fixture CSV header is the raw.csv column set", csv_text.split(b"\n", 1)[0].decode() == serve.CSV_HEADER)
rows = csv_text.count(b"\n") - 1
check("fixture has the sample count its header claims", rows == header["sampleCount"], f"{rows} vs {header['sampleCount']}")
import hashlib  # noqa: E402
check("fixture sha256 matches its CSV", hashlib.sha256(csv_text).hexdigest() == header["sha256"])

# ---------------------------------------------------------------- bands parsed out of Swift
bands = serve.bands_from_swift()
swift_bands = len(re.findall(r'Band\(id:\s*"', (HERE / "BiomimeticRadar/Processing/BandRegistry.swift").read_text()))
check("api/bands parses every Band(...) in BandRegistry.swift", len(bands) == swift_bands and swift_bands >= 10,
      f"{len(bands)} vs {swift_bands}")
check("bands include schumann-1 and mains-60 with sane edges",
      any(b["id"] == "schumann-1" and b["lowHz"] < 7.83 < b["highHz"] for b in bands)
      and any(b["id"] == "mains-60" and b["lowHz"] < 60 < b["highHz"] for b in bands))
import bands as _alias  # noqa: E402
_m60 = next(b for b in _alias.BANDS if b.id == "mains-60")
check("alias arithmetic: 97 Hz at 100 Hz lands on 3, 60 Hz at 64 Hz on 4, 150 Hz at 100 Hz on 50",
      [_alias.alias_of(97, 100), _alias.alias_of(60, 64), _alias.alias_of(150, 100)] == [3, 4, 50])
check("mains-60 folds to 4 Hz at a 64 Hz rate and is direct at 200 Hz",
      (_alias.visibility(_m60, 64.0, 0.0).kind, _alias.visibility(_m60, 64.0, 0.0).apparent_centre_hz,
       _alias.visibility(_m60, 200.0, 0.0).kind) == ("folded", 4.0, "direct"))


# ---------------------------------------------------------------- interference registry parity
inf = serve.interference_from_swift()
swift_inf = (HERE / "BiomimeticRadar/Processing/InterferenceRegistry.swift").read_text()
n_sources = swift_inf.count("Source(id:")
check("api/interference parses every Source(...) in InterferenceRegistry.swift",
      len(inf) == n_sources and n_sources >= 10, f"{len(inf)} vs {n_sources}")
check("the MagSafe accessory source is present and hard-iron DC with a high-pass suggestion",
      any(e["id"] == "magsafe-accessory" and e["character"] == "hardIronDC"
          and (e.get("suggestedFilter") or {}).get("kind") == "highPass" for e in inf))
check("the Taptic Engine source is present and current-modulated",
      any(e["id"] == "taptic-engine" and e["character"] == "currentModulated" for e in inf))
check("every source carries effect/tell/mitigation (no blank documentation)",
      all(e["effect"] and e["tell"] and e["mitigation"] for e in inf))
check("INTERFERENCE.md exists and names the clean-baseline protocol",
      (HERE / "INTERFERENCE.md").exists() and "clean-baseline protocol" in (HERE / "INTERFERENCE.md").read_text())
# the viewer keeps raw untouched: filtered() must copy and never assign into S.ring
appjs = (HERE / "web/app.js").read_text()
check("the viewer's filter copies (never mutates the raw ring)",
      "Float64Array.from(y)" in appjs and "function filtered" in appjs)
check("the viewer draws the signal waveform with its cycle spread",
      "export function waveform" in (HERE / "web/draw.js").read_text()
      and "cycle_spread_nt" in (HERE / "web/draw.js").read_text())
check("the register UI offers a confirm button per manual-test outcome",
      "api/register/confirm" in appjs and "data-outcome" in appjs)
check("serve.py refuses to emit NaN (a browser rejects the whole document)",
      "allow_nan=False" in (HERE / "serve.py").read_text())
check("dsp.js high-pass and notch return NEW arrays", "export function highPass" in (HERE / "web/dsp.js").read_text()
      and "export function notch" in (HERE / "web/dsp.js").read_text())

# ---------------------------------------------------------------- a live server in a scratch store
tmp = tempfile.mkdtemp(prefix="fieldlab-streams-")
port = free_port()
env = dict(os.environ, FIELDLAB_STREAMS=tmp)
proc = subprocess.Popen([sys.executable, str(HERE / "serve.py"), str(port)], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
base = f"http://127.0.0.1:{port}"
for _ in range(50):
    try:
        urllib.request.urlopen(base + "/api/status", timeout=1)
        break
    except Exception:
        time.sleep(0.1)
try:
    import simulate_phone as sim  # noqa: E402
    import random  # noqa: E402
    rng = random.Random(3)

    # SSE listener
    events = []
    def listen():
        try:
            with urllib.request.urlopen(base + "/api/events", timeout=30) as r:
                for line in r:
                    if line.startswith(b"event: chunk"):
                        events.append(line)
                    if len(events) >= 3:
                        break
        except Exception:
            pass
    th = threading.Thread(target=listen, daemon=True)
    th.start()
    time.sleep(0.3)

    hdr = {"Content-Type": "application/x-fieldlab-chunk", "X-FieldLab-Compression": "deflate-raw"}
    status, body = http("POST", base + "/api/stream/chunk", fixture.read_bytes(), hdr)
    ack = json.loads(body)
    check("fixture chunk is accepted (200, ok)", status == 200 and ack.get("ok") is True, body[:120].decode())
    check("ack reports the seqs it has NOT seen (0..6 before seq 7)", ack.get("missing") == list(range(7)))
    status, body = http("POST", base + "/api/stream/chunk", fixture.read_bytes(), hdr)
    check("re-sending the same chunk is a duplicate, not a second chunk", json.loads(body).get("duplicate") is True)
    manifest = Path(tmp, "abcd1234", "s1", "manifest.jsonl")
    check("manifest has exactly one line after a duplicate", manifest.exists() and len(manifest.read_text().splitlines()) == 1)
    check("chunk is stored decompressed as CSV with the header row",
          Path(tmp, "abcd1234", "s1", "chunks", "000007.csv").read_text().startswith(serve.CSV_HEADER))

    # refusals
    bad = bytearray(file)
    bad[-5] ^= 0x01
    comp = zlib.compressobj(6, zlib.DEFLATED, -15)
    corrupted = comp.compress(bytes(bad)) + comp.flush()
    status, body = http("POST", base + "/api/stream/chunk", corrupted, hdr)
    check("a chunk whose sha256 does not match its header is refused (422)", status == 422 and b"sha256" in body)
    wrong = dict(header, format="fieldlab-stream/99")
    comp = zlib.compressobj(6, zlib.DEFLATED, -15)
    wf = comp.compress(json.dumps(wrong).encode() + b"\n" + csv_text) + comp.flush()
    status, body = http("POST", base + "/api/stream/chunk", wf, hdr)
    check("an unknown format tag is refused (422)", status == 422)
    evil = dict(header, deviceID="../../etc", sha256=header["sha256"])
    comp = zlib.compressobj(6, zlib.DEFLATED, -15)
    ef = comp.compress(json.dumps(evil).encode() + b"\n" + csv_text) + comp.flush()
    status, body = http("POST", base + "/api/stream/chunk", ef, hdr)
    check("a deviceID with path characters is refused (422)", status == 422)
    status, body = http("POST", base + "/api/stream/chunk", b"", hdr)
    check("an empty body is refused", status == 400)
    status, body = http("POST", base + "/api/stream/chunk", b"not deflate at all", hdr)
    check("garbage is refused (422), not a 500", status == 422)

    def deflated(head, csv):
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        return comp.compress(json.dumps(head).encode() + b"\n" + csv) + comp.flush()

    stored = Path(tmp, "abcd1234", "s1", "chunks", "000007.csv")
    before = stored.read_bytes()
    other_csv = csv_text.replace(b"\n1000,", b"\n1000.5,", 1)
    other = dict(header, sha256=hashlib.sha256(other_csv).hexdigest())
    status, body = http("POST", base + "/api/stream/chunk", deflated(other, other_csv), hdr)
    check("different bytes for a stored seq are refused (409) and the stored chunk is kept",
          other_csv != csv_text and status == 409 and stored.read_bytes() == before, f"{status} {body[:80]!r}")
    for field, value in (("sampleCount", None), ("startedAt", "yesterday")):
        status, _ = http("POST", base + "/api/stream/chunk", deflated(dict(header, seq=8, **{field: value}), csv_text), hdr)
        check(f"a header with a bad {field} is refused (422) rather than stored", status == 422, str(status))
    status, _ = http("POST", base + "/api/stream/chunk", fixture.read_bytes(),
                     {"Content-Type": "text/plain", "X-FieldLab-Compression": "deflate-raw"})
    check("a POST a browser could send cross-site (text/plain) is refused (415)", status == 415, str(status))
    status, _ = http("POST", base + "/api/stream/hello", b"{}")   # urllib sends it form-encoded
    check("a form-encoded POST is refused (415)", status == 415, str(status))
    rows = manifest.read_text()
    manifest.write_text("")                      # as if the server died after writing the chunk file
    status, body = http("POST", base + "/api/stream/chunk", fixture.read_bytes(), hdr)
    check("a retry restores a manifest row that a crash lost", status == 200
          and len(manifest.read_text().splitlines()) == 1 and json.loads(body).get("duplicate") is True)
    manifest.write_text(rows)
    blank_csv = csv_text.replace(b"\n1000,", b"\n1000,x,,", 1)          # a row with empty fields
    status, _ = http("POST", base + "/api/stream/chunk",
                     deflated(dict(header, seq=9, sha256=hashlib.sha256(blank_csv).hexdigest()), blank_csv), hdr)
    fix_t0 = serve._iso_to_epoch(header["startedAt"])
    status, body = http("GET", base + f"/api/samples?device=abcd1234&from={fix_t0 - 5}&to={fix_t0 + 5}")
    check("a stored row with empty fields is skipped by /api/samples, not a 500", status == 200, str(status))
    status, _ = http("GET", base + "/api/samples?device=abcd1234&from=nan&to=nan")
    check("a NaN window is refused (400) rather than read in full", status == 400, str(status))

    # simulated stream with a dropped chunk, jitter-free
    t0 = time.time() - 120
    for seq in range(12):
        if seq == 5:
            continue
        body, h = sim.make_chunk(device="sim00001", stream="sAAA", seq=seq, start_epoch=t0 + seq * 10,
                                 first_mono=1000 + seq * 10, n=1000, rate=100, rng=rng)
        status, resp = http("POST", base + "/api/stream/chunk", body, hdr)
    ack = json.loads(resp)
    check("server reports the dropped seq as missing", ack.get("missing") == [5], str(ack.get("missing")))
    status, body = http("GET", base + f"/api/samples?device=sim00001&from={t0 - 1}&to={t0 + 130}")
    smp = json.loads(body)
    check("samples endpoint returns the 11 stored chunks' rows", smp["n"] == 11000 and smp["chunks"] == 11, f"n={smp['n']}")
    check("samples endpoint measures the rate from the timestamps", abs(smp["rateHz"] - 100) < 0.5)
    check("the dropped chunk appears as ONE clock gap of ~10 s",
          len(smp["gaps"]) == 1 and 9.5 < smp["gaps"][0][1] - smp["gaps"][0][0] < 10.5, str(smp["gaps"]))
    status, body = http("GET", base + f"/api/samples?device=sim00001&from={t0 - 1}&to={t0 + 130}&step=100")
    check("step= bins the samples (11000 -> 110)", json.loads(body)["n"] == 110)
    status, body = http("GET", base + f"/api/samples?device=sim00001&from=0&to={time.time()}")
    check("a >6 h window without bins is refused", status == 400)
    status, body = http("GET", base + "/api/status")
    st = json.loads(body)
    check("status lists both devices", {d["device"] for d in st["devices"]} == {"abcd1234", "sim00001"})
    th.join(timeout=3)
    check("SSE delivered chunk events as they landed", len(events) >= 3, f"{len(events)} events")

    # hello
    hello = {"deviceID": "sim00001", "streamID": "sAAA", "deviceName": "x", "settings": {"chunkSeconds": 10}}
    status, body = http("POST", base + "/api/stream/hello", json.dumps(hello).encode(), {"Content-Type": "application/json"})
    stored = json.loads(Path(tmp, "sim00001", "sAAA", "stream.json").read_text())
    check("hello is stored into stream.json", status == 200 and stored.get("settings", {}).get("chunkSeconds") == 10)

    # URL surface
    status, _ = http("GET", base + "/streams/sim00001/sAAA/manifest.jsonl")
    check("the data folder is not on the URL surface (404)", status == 404)
    status, _ = http("GET", base + "/serve.py")
    check("the server's own source is not served", status == 404)
    status, _ = http("GET", base + "/../CLAUDE.md")
    check("a path that climbs out of web/ is not served", status == 404, str(status))
    status, body = http("GET", base + "/")
    check("the page is served at /", status == 200 and b"FieldLab" in body)
    status, body = http("GET", base + f"/{HERE.name}/api/status")
    check("routes work with the gateway prefix too", status == 200)
    status, body = http("GET", base + "/design/design.css")
    check("tools/design stylesheet is reachable (optional sibling)", status in (200, 404))
    # nothing here may be named after the gateway's private markers
    text = (HERE / "serve.py").read_text()
    check("no route segment is named research/subjects/recordings",
          not re.search(r'"/api/[^"]*(research|subjects|recordings)', text))


    # -- the claim/device boundary -----------------------------------------------------------------
    # The viewer is the TOOL's and draws what the phone recorded. Four panels are one falsification
    # entry's questions (an ELF observatory, its register, its findings, its band alerts). A second
    # consumer asking a different question must not inherit them, so the consuming project DECLARES
    # what it adds and anything undeclared is hidden.
    status, body = http("GET", base + "/api/claim")
    claim = json.loads(body)
    # This suite runs with the real default consumer present, so `declared` is true here. Both
    # branches still have to be well-formed -- a declared claim needs panels to render, and an
    # ABSENT one needs a reason rather than a 500, because that is the state every future consumer
    # of this tool starts in.
    check("/api/claim answers, and a declared claim carries the panels it wants rendered",
          status == 200 and (claim.get("panels") if claim.get("declared") else claim.get("reason")),
          str(claim)[:90])
    check("the absent case is a declared:false payload, never an error",
          '"declared": False' in (HERE / "serve.py").read_text()
          or "'declared': False" in (HERE / "serve.py").read_text())
    app_js = (HERE / "web" / "app.js").read_text()
    check("the dashboard gates the claim panels on that declaration",
          "applyClaim" in app_js and "CLAIM_PANELS" in app_js)
    check("and it does not even POPULATE an undeclared panel (hidden-after-filling still leaks "
          "one project's framing into another's dashboard)",
          "if (wants.has('register'))" in app_js and "if (wants.has('station'))" in app_js)
    check("the generic device panels are never gated — they are what this tool IS",
          all(p_ not in str(re.findall(r"CLAIM_PANELS = \{[^}]*\}", app_js))
              for p_ in ("strip", "spectrum", "spectrogram", "chunkList")))
    # the client a consumer actually imports
    status, cbody = http("GET", base + "/fieldlab-client.js")
    check("fieldlab-client.js is served from the tool, so consumers share one copy",
          status == 200 and b"class FieldLab" in cbody)
    check("reads are CORS-open, so a project on another port can consume the stream",
          "Access-Control-Allow-Origin" in (HERE / "serve.py").read_text())
    check("but a WRITE sends no allow-origin — any project may read the record, only this tool's "
          "own pages may change it",
          'self.command in ("GET", "HEAD", "OPTIONS")' in (HERE / "serve.py").read_text())
    check("INTEGRATION.md exists — the one thing every other tool in tools/ has",
          (HERE / "INTEGRATION.md").is_file())
    check("and it warns the next consumer about relative asset paths",
          "root-relative" in (HERE / "INTEGRATION.md").read_text())


    # -- the consuming entry's claim page, mounted from OUTSIDE this folder ----------------------
    # This tool owns the device and the recording; a claim page belongs with the claim. So /watch
    # serves whatever `CLAIM_WEB` points at, and these checks pin the mount without this tool
    # knowing anything about the page's content.
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None            # urllib FOLLOWS redirects by default, hiding the 301 entirely
    try:
        urllib.request.build_opener(_NoRedirect).open(base + "/watch", timeout=10)
        redirect_status, location = 200, ""
    except urllib.error.HTTPError as e:
        redirect_status, location = e.code, e.headers.get("Location", "")
    check("/watch redirects to /watch/ so the page's relative assets resolve",
          redirect_status in (301, 308) and location.endswith("/watch/"),
          f"{redirect_status} -> {location}")
    if serve.CLAIM_WEB.is_dir():
        status, body = http("GET", base + "/watch/")
        check("the consuming entry's claim page is served at /watch/",
              status == 200)
        status, _ = http("GET", base + "/watch/watch.js")
        check("its assets are served beside it", status == 200)
        status, _ = http("GET", base + "/watch/CLAIM.md")
        check("but only page file types — the entry's docs and data stay off the URL surface",
              status == 404)
        status, _ = http("GET", base + "/watch/../serve.py")
        check("and there is no traversal out of the claim page directory", status in (403, 404))
        page = (serve.CLAIM_WEB / "index.html").read_text()
        check("the claim page links back to the recorder rather than duplicating it",
              'href="../"' in page)

    # -- the watch + runbook routes ---------------------------------------------------------------
    # `runbook.py` is stdlib on purpose so this server can import it; `watch.py` needs numpy and
    # scipy, so it is shelled out to the analysis venv. Two routes, two mechanisms, one seam.
    status, body = http("GET", base + "/api/runbook?device=sim00001")
    if status == 200:
        plan = json.loads(body)
        check("the runbook route orders the manual tests by cost, power-down first",
              [t["id"] for t in plan["tests"]][0] == "power-down")
        check("every test carries its steps and what it settles",
              all(t["steps"] and t["settles"] for t in plan["tests"]))
        status, _ = http("POST", base + "/api/runbook/step",
                         json.dumps({"device": "sim00001", "test": "power-down",
                                     "step": "place", "done": True}).encode(),
                         {"Content-Type": "application/json"})
        check("a step can be ticked and lands in the device's own folder",
              status == 200 and Path(tmp, "sim00001", "runbook.json").is_file())
        status, _ = http("POST", base + "/api/runbook/step",
                         json.dumps({"device": "sim00001", "test": "power-down",
                                     "step": "not-a-step"}).encode(),
                         {"Content-Type": "application/json"})
        check("an unknown step is refused rather than silently recorded", status == 400)
        status, _ = http("POST", base + "/api/runbook/reset",
                         json.dumps({"device": "sim00001", "test": "power-down"}).encode(),
                         {"Content-Type": "application/json"})
        state = json.loads(Path(tmp, "sim00001", "runbook.json").read_text())
        check("a reset archives the attempt rather than deleting it",
              status == 200 and len(state["tests"]["power-down"]["history"]) == 1)
    else:
        check("runbook route degrades to 503 when the analysis sidecar is absent", status == 503,
              f"status {status}")
    status, body = http("GET", base + "/api/watch?device=nodevice0&seconds=60")
    watch_res = json.loads(body)
    check("a device with no recording at all answers cleanly rather than erroring",
          status == 200 and watch_res.get("available") is not True)
    check("and reports NO-READING, never OFF — 'nothing was recorded' and 'nothing was there' "
          "are different claims and only one of them is a measurement",
          watch_res.get("readiness", {}).get("state") == "no-reading",
          str(watch_res.get("readiness", {}).get("state")))
    check("a failure never puts a python traceback in the response body",
          "Traceback" not in str(watch_res.get("reason", "")))

    # the stream loader and the census, run on the scratch store the simulated phone just filled
    try:
        import numpy  # noqa: F401
        _have_np = True
    except ModuleNotFoundError as _e:
        _have_np = False
        _missing = _e.name
    if not _have_np:
        print(f"  SKIP  session/census on the scratch store — {_missing} is not installed for this interpreter")
    else:
        import session as _sess
        import census as _cen
        import bands as _bands
        _x = _sess.load_stream(f"{tmp}/sim00001")
        _j = _x.jitter_report()
        check("session.load_stream reads the store (11000 samples, 100 Hz, 1 dropped gap, 11 chunks)",
              [_x.n, round(_x.rate_hz, 2), _j["dropped_gaps"], _x.metadata["chunks"]] == [11000, 100.0, 1, 11],
              str([_x.n, round(_x.rate_hz, 2), _j["dropped_gaps"], _x.metadata["chunks"]]))
        _c = _cen.census(_x)
        _share = sum(c.fraction for c in _c.components)
        check("census partitions the stream's AC variance (shares sum to 1)", abs(_share - 1.0) < 1e-6, f"{_share:.6f}")
        check("census reads THIS repo's band registry, not a copy", _cen.band_registry is _bands)

    venv = HERE / "analysis/.venv/bin/python"
    if venv.exists() and (HERE / "analysis/run.py").exists():
        out = subprocess.run([str(venv), str(HERE / "analysis/run.py"), "jitter", "--stream", f"{tmp}/sim00001",
                              "--from", "2020-01-01T00:00:00Z", "--to", "2030-01-01T00:00:00Z"],
                             capture_output=True, text=True, cwd=str(HERE))
        ok = out.returncode == 0 and '"source": "stream"' in out.stdout
        check("run.py jitter --stream works end to end", ok, out.stderr[-300:] if not ok else "")
        # and the analyze job route drives it
        job = {"command": "jitter", "device": "sim00001", "from": t0, "to": t0 + 130}
        status, body = http("POST", base + "/api/analyze", json.dumps(job).encode(), {"Content-Type": "application/json"})
        job = json.loads(body)
        check("api/analyze starts a job", status == 200 and job.get("ok"), body[:200].decode())
        for _ in range(100):
            jobs = json.loads(http("GET", base + "/api/jobs")[1])["jobs"]
            if jobs and jobs[0]["state"] != "running":
                break
            time.sleep(0.2)
        check("the job finishes and carries run.py's output",
              jobs and jobs[0]["state"] == "done" and '"dropped_gaps": 1' in jobs[0]["output"],
              (jobs[0]["output"][-200:] if jobs else "no job"))
    else:
        print("  SKIP  run.py / api/analyze job path — no analysis venv with run.py in this repo "
              "(the job runs a consumer's analysis; see serve.py _analysis_dir)")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()

# ------------------------------------------------------- one on-disk format, one reader (parity)
# `serve.py`'s Store WRITES the store and reads it back for /api/samples; `store.py` is the stdlib
# reader a consuming project imports. Two readers of one format is how a format drifts, so they are
# checked against each other on a real window rather than trusted to stay in step. Merging them is
# the recorded next step; this test is what makes deferring it safe.
sys.path.insert(0, str(HERE))
import store as fl_store  # noqa: E402

check("store.py is stdlib-only, so any project can import it without a venv",
      not re.search(r"^\s*import (numpy|scipy|pandas)", (HERE / "store.py").read_text(), re.M))
check("store.py does not import serve.py (a reader must not need the server)",
      "import serve" not in (HERE / "store.py").read_text())

with tempfile.TemporaryDirectory() as _tmp:
    _dev, _st = "parity01", "sPARITY"
    _chunks = Path(_tmp, _dev, _st, "chunks")
    _chunks.mkdir(parents=True)
    _rows = []
    for seq in range(3):
        t0 = 1_700_000_000 + seq * 10
        lines = [serve.CSV_HEADER]
        for i in range(50):
            mono = 1000.0 + seq * 10 + i * 0.2
            lines.append(",".join([f"{mono:f}"] + ["1.0"] * serve.CSV_HEADER.count(",")))
        (_chunks / f"{seq:06d}.csv").write_text("\n".join(lines) + "\n")
        _rows.append(json.dumps({"seq": seq, "startedAt": _iso_z(t0), "endedAt": _iso_z(t0 + 10),
                                 "firstMonotonic": 1000.0 + seq * 10, "sampleCount": 50}))
    Path(_tmp, _dev, _st, "manifest.jsonl").write_text("\n".join(_rows) + "\n")

    _mf = fl_store.manifest(_dev, root=_tmp)
    check("store.manifest reads every chunk of a synthetic store in time order",
          [r["seq"] for r in _mf] == [0, 1, 2], str([r["seq"] for r in _mf]))
    _runs = fl_store.runs(_dev, root=_tmp)
    check("three back-to-back chunks are ONE run, not three",
          len(_runs) == 1 and _runs[0]["chunks"] == 3, str(_runs))
    check("a window shorter than the minimum yields no latest_window (no-reading, not empty)",
          fl_store.latest_window(_dev, 300, root=_tmp, minimum_s=1000) is None)
    _n = sum(1 for _ in fl_store.read_rows(_dev, root=_tmp))
    check("read_rows returns every sample it was given", _n == 150, str(_n))
    check("and each row carries wall_epoch, since the CSV clock is MONOTONIC",
          all("wall_epoch" in r for r in list(fl_store.read_rows(_dev, root=_tmp))[:5]))
    # torn append: a crash mid-line must not lose the whole manifest
    with Path(_tmp, _dev, _st, "manifest.jsonl").open("a") as _h:
        _h.write('{"seq": 3, "startedAt": "not-json')
    check("a torn manifest line is skipped, not fatal",
          [r["seq"] for r in fl_store.manifest(_dev, root=_tmp)] == [0, 1, 2])

check("a device that does not exist reads as empty, never as an exception",
      fl_store.manifest("no-such-device") == [] and fl_store.runs("no-such-device") == [])
check("summary() applies the SAME minimum as latest_window (it once reported a 0.7 s straggler "
      "as a device's newest recording)",
      "minimum_s" in fl_store.summary.__code__.co_varnames)


# ---------------------------------------------------------------- the store's size, as a tripwire
# `streams/` is deliberately inside this tool rather than in a ~/.cache directory: it is a SYSTEM OF
# RECORD, not a cache. The phone deletes its own copy on ack, no API can re-serve it, and there is
# no second copy anywhere. See CLAUDE.md. That decision was made knowing it does not scale, so the
# scaling limit is a FAILING TEST rather than a note -- a checkout that has quietly grown to 20 GB
# is one nobody can clone, and by then moving it is a migration instead of a decision.
STORE_FLAG_GB = 2.0
_store = Path(os.environ.get("FIELDLAB_STREAMS", HERE / "streams"))
if _store.is_dir():
    _bytes = sum(f.stat().st_size for f in _store.rglob("*") if f.is_file())
    _gb = _bytes / 1e9
    check(f"the stream store is under {STORE_FLAG_GB} GB "
          f"(past that, move the system of record to object storage and keep this as a cache "
          f"-- see CLAUDE.md)", _gb < STORE_FLAG_GB, f"{_gb:.2f} GB")
else:
    check("the stream store path resolves (absent is fine -- nothing has streamed yet)", True,
          str(_store))


print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
for f in FAIL:
    print("  FAIL:", f)
if "-v" in sys.argv:
    for p in PASS:
        print("  ok:", p)
sys.exit(1 if FAIL else 0)
