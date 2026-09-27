"""Reading the always-on stream store. **Stdlib only, and the one reader everything shares.**

`serve.py` WRITES this store; this module READS it, and it is deliberately importable without
importing the server — a consuming project should not have to start an HTTP daemon, or install
numpy, to ask what the phone recorded.

    from store import devices, runs, latest_window, read_rows

    for dev in devices():
        t0, t1 = latest_window(dev, seconds=300)
        for row in read_rows(dev, t0, t1):
            row["mz_uT"], row["monotonic_s"], ...

## The layout, which is the actual contract

    <store>/<device>/<stream>/manifest.jsonl     one JSON line per chunk, appended
    <store>/<device>/<stream>/chunks/<seq>.csv   the samples, raw.csv columns
    <store>/<device>/register.json               whatever a consuming analysis chose to log

`<store>` is `$FIELDLAB_STREAMS`, else `streams/` beside this file. **Point tests at a scratch
store with that variable** — the real one is a system of record with no second copy anywhere.

## Why this file exists

One reader of the store for everyone: `session.py` builds on it, and a project that consumes the
stream imports it rather than keeping its own copy of the format.
"""
from __future__ import annotations

import csv
import json
import os
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: A chunk whose declared span is far longer than any chunk SETTING (5 s .. 5 min) is a stretch the
#: app spent suspended, delivering a trickle. Included in a short window it puts a twenty-minute
#: hole in "the last five minutes" and every reading is then about the hole.
MAX_CHUNK_SPAN_S = 400.0

#: Chunks closer together than this are one continuous recording.
DEFAULT_GAP_S = 60.0


def store_root(root=None) -> Path:
    return Path(root or os.environ.get("FIELDLAB_STREAMS") or (HERE / "streams"))


def devices(root=None) -> list[str]:
    base = store_root(root)
    if not base.is_dir():
        return []
    return sorted(d.name for d in base.iterdir() if d.is_dir() and not d.name.startswith("."))


def _iso(text: str) -> float:
    """Epoch seconds. A time with no offset is UTC, as `serve.py` and `session.py` read it."""
    value = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    return (value if value.tzinfo else value.replace(tzinfo=timezone.utc)).timestamp()


def manifest(device: str, root=None) -> list[dict]:
    """Every chunk held for one device, across its streams, in time order.

    A torn manifest line (a crash mid-append) is skipped; its chunk file is still on disk. A
    device folder that does not exist is an empty list, never an exception — "nothing was
    recorded" is a normal state and callers must be able to render it as such.
    """
    device_dir = store_root(root) / device
    if not device_dir.is_dir():
        return []
    rows: list[dict] = []
    for stream_dir in sorted(p for p in device_dir.iterdir() if p.is_dir()):
        mf = stream_dir / "manifest.jsonl"
        if not mf.exists():
            continue
        by_seq: dict[int, dict] = {}
        try:
            lines = mf.read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue          # a torn append, not a corrupt store
            if "seq" in row:
                by_seq[row["seq"]] = row
        for seq in sorted(by_seq):
            row = dict(by_seq[seq])
            row["stream"] = stream_dir.name
            row["path"] = stream_dir / "chunks" / f"{seq:06d}.csv"
            try:
                row["startEpoch"] = _iso(row["startedAt"])
                row["endEpoch"] = _iso(row["endedAt"])
            except (KeyError, ValueError):
                continue
            rows.append(row)
    rows.sort(key=lambda r: r["startEpoch"])
    return rows


def runs(device: str, root=None, gap_s: float = DEFAULT_GAP_S) -> list[dict]:
    """Contiguous stretches of real recording, oldest first.

    A stream folder is not one recording. It holds every start the phone made, plus suspended
    stretches and single-chunk **stragglers** — a few hundred milliseconds uploaded as the app
    died. The straggler is the trap: it is the newest thing in the store and it is not a
    recording. A caller asking for "the newest data" and getting one of those measured **70
    samples spanning 0.7 s** and read it as a real, empty window.
    """
    rows = [r for r in manifest(device, root)
            if r["path"].exists() and 0 < (r["endEpoch"] - r["startEpoch"]) <= MAX_CHUNK_SPAN_S]
    out: list[dict] = []
    for r in rows:
        if out and r["startEpoch"] - out[-1]["end"] <= gap_s:
            out[-1]["end"] = max(out[-1]["end"], r["endEpoch"])
            out[-1]["chunks"] += 1
            out[-1]["covered_s"] += r["endEpoch"] - r["startEpoch"]
        else:
            out.append({"start": r["startEpoch"], "end": r["endEpoch"], "chunks": 1,
                        "covered_s": r["endEpoch"] - r["startEpoch"],
                        "stream": r.get("stream")})
    for run in out:
        run["span_s"] = run["end"] - run["start"]
    return out


def latest_window(device: str, seconds: float = 300.0, root=None, minimum_s: float = 30.0):
    """The most recent `seconds` of ACTUAL data, as `(t0, t1)` epoch seconds, or `None`.

    Not `now - seconds`: the phone may have stopped hours ago. Not the newest chunk either: see
    `runs()`. `None` means the store holds nothing usable, and a caller must render that as **no
    recording** — never as an empty or quiet measurement. Those are different claims.
    """
    usable = [r for r in runs(device, root) if r["covered_s"] >= minimum_s]
    if not usable:
        return None
    run = usable[-1]
    return (max(run["start"], run["end"] - float(seconds)), run["end"])


def read_rows(device: str, t0: float | None = None, t1: float | None = None, root=None):
    """Yield sample rows in a wall-clock window, in time order, as plain dicts.

    Values are strings — this is stdlib and does not decide anyone's dtype. Each row gains
    `wall_epoch`, because the CSV carries the sensor's MONOTONIC clock and joining against
    anything in the world needs wall time. That mapping is per chunk: `startEpoch - firstMonotonic`
    is the anchor, and across a stream boundary the monotonic clock may jump, which is left visible
    rather than papered over.
    """
    lo = -float("inf") if t0 is None else float(t0)
    hi = float("inf") if t1 is None else float(t1)
    for chunk in manifest(device, root):
        if chunk["endEpoch"] < lo or chunk["startEpoch"] > hi or not chunk["path"].exists():
            continue
        anchor = chunk["startEpoch"] - float(chunk.get("firstMonotonic") or 0.0)
        with chunk["path"].open() as handle:
            for row in csv.DictReader(handle):
                try:
                    wall = anchor + float(row["monotonic_s"])
                except (KeyError, TypeError, ValueError):
                    continue
                if lo <= wall <= hi:
                    row["wall_epoch"] = wall
                    row["_stream"] = chunk["stream"]
                    yield row


def summary(device: str, root=None, minimum_s: float = 30.0) -> dict:
    """What a consumer needs to decide whether to bother reading: is there data, and how fresh.

    `latest_*` describes the newest run with at least `minimum_s` of coverage — the SAME filter
    `latest_window()` applies, because the first version of this function did not and cheerfully
    reported a device's newest recording as **0.7 s long**: it had picked up a straggler chunk
    uploaded as the app died. Two functions one screen apart disagreeing about which run is the
    latest is how a caller ends up trusting whichever it happened to call.
    """
    rr = runs(device, root)
    usable = [r for r in rr if r["covered_s"] >= minimum_s]
    if not usable:
        return {"device": device, "available": False, "runs": len(rr),
                "reason": (f"no run holds at least {minimum_s:g} s of continuous data"
                           if rr else "no run in this store holds usable data")}
    last = usable[-1]
    trailing = [r for r in rr if r["start"] > last["end"]]
    return {"device": device, "available": True,
            "runs": len(rr), "usable_runs": len(usable),
            "latest_start": last["start"], "latest_end": last["end"],
            "latest_covered_s": round(last["covered_s"], 1),
            "latest_stream": last.get("stream"),
            "age_s": round(datetime.now(timezone.utc).timestamp() - last["end"], 1),
            "total_covered_s": round(sum(r["covered_s"] for r in rr), 1),
            # Named rather than hidden: a straggler AFTER the newest usable run is normal (the app
            # died mid-chunk) and is exactly what a naive "newest chunk" reader would have picked.
            "trailing_fragments": len(trailing)}
