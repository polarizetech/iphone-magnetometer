#!/usr/bin/env python3
"""A stand-in for the phone: encode chunks exactly as `StreamChunk.swift` does and POST them.

    python3 analysis/simulate_phone.py http://127.0.0.1:8212 --chunks 30 --chunk-seconds 10 --rate 100
    python3 analysis/simulate_phone.py http://127.0.0.1:8212 --drop 5        # never send seq 5 — a gap
    python3 analysis/simulate_phone.py http://127.0.0.1:8212 --live           # one chunk per chunk-length, forever

Stdlib only, so it runs without the analysis venv. It exists for two reasons: to exercise the server
and the web page before a phone has ever connected, and so `dev_check.py` can drive the whole
ingest path. It is NOT the phone — the bytes the phone actually produces are pinned by
`analysis/fixtures/sample.chunk`, which Swift wrote.

The synthetic signal is `session.synthetic`'s: a coded 8.3 Hz carrier at 25 nT under 250 nT of
noise on a ~47 µT standing field, plus a 60 Hz "mains" line that folds to 40 Hz at 100 Hz
sampling. Every chunk says so in its `deviceName`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
import time
import urllib.request
import zlib
from datetime import datetime, timezone

HEADER = ("monotonic_s,wall_clock,mx_uT,my_uT,mz_uT,magnitude_uT,ax_g,ay_g,az_g,"
          "gx_rads,gy_rads,gz_rads,qx,qy,qz,qw,orientation,latitude,longitude")
FORMAT = "fieldlab-stream/1"


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def make_chunk(*, device: str, stream: str, seq: int, start_epoch: float, first_mono: float, n: int,
               rate: float, rng: random.Random, device_name: str = "simulated-phone", emitter: str | None = None,
               jitter: float = 0.0) -> tuple[bytes, dict]:
    rows = []
    mono = first_mono
    code = [1, 1, 1, -1, -1, 1, -1]
    for i in range(n):
        dt = 1 / rate
        if jitter:
            dt *= max(0.2, rng.gauss(1, jitter))
        mono = first_mono + i / rate if not jitter else mono + dt
        t = mono
        chip = int(t / 0.25) % len(code)
        coded = code[chip] * 0.025 * math.sin(2 * math.pi * 8.3 * t)
        mains = 0.05 * math.sin(2 * math.pi * 60.0 * t)
        noise = rng.gauss(0, 0.25)
        x = 21 + coded + noise + mains
        y = -4 + 0.7 * rng.gauss(0, 0.25)
        z = 42 + 0.35 * coded + 0.5 * rng.gauss(0, 0.25)
        mag = math.sqrt(x * x + y * y + z * z)
        wall = start_epoch + (mono - first_mono)
        rows.append(",".join([f"{mono:.10g}", iso(wall), f"{x:.10g}", f"{y:.10g}", f"{z:.10g}", f"{mag:.10g}",
                              "0", "0", "0", "0", "0", "0", "0", "0", "0", "1", "faceUp", "", ""]))
    csv_text = HEADER + "\n" + "\n".join(rows) + "\n"
    csv_bytes = csv_text.encode()
    header = {
        "format": FORMAT, "deviceID": device, "deviceName": device_name, "streamID": stream, "seq": seq,
        "startedAt": iso(start_epoch), "endedAt": iso(start_epoch + (mono - first_mono)),
        "firstMonotonic": first_mono, "lastMonotonic": mono, "sampleCount": n,
        "requestedRateHz": rate, "achievedRateHz": rate, "emitter": emitter,
        # The per-chunk covariate block the real phone sends (battery, thermal, barometer, disk).
        # Plausible constants, so the viewer's aux path is exercised without pretending to measure.
        "aux": {"batteryLevel": 0.72, "batteryState": "unplugged", "lowPowerMode": False,
                "thermalState": "nominal", "pressureKPa": 101.1, "relativeAltitudeM": 0.0,
                "freeDiskBytes": 64_000_000_000},
        "deviceModel": "simulated", "systemVersion": "0", "appVersion": "sim",
        "sha256": hashlib.sha256(csv_bytes).hexdigest(),
    }
    file = json.dumps(header, separators=(",", ":")).encode() + b"\n" + csv_bytes
    comp = zlib.compressobj(6, zlib.DEFLATED, -15)
    body = comp.compress(file) + comp.flush()
    return body, header


def post_chunk(base: str, body: bytes) -> dict:
    req = urllib.request.Request(base.rstrip("/") + "/api/stream/chunk", data=body, method="POST",
                                 headers={"Content-Type": "application/x-fieldlab-chunk",
                                          "X-FieldLab-Format": FORMAT, "X-FieldLab-Compression": "deflate-raw"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def post_hello(base: str, device: str, stream: str, rate: float, chunk_seconds: float) -> dict:
    payload = {"deviceID": device, "deviceName": "simulated-phone", "streamID": stream, "startedAt": iso(time.time()),
               "settings": {"chunkSeconds": chunk_seconds, "sampleRateHz": rate, "attitude": False, "wifiOnly": True},
               "deviceModel": "simulated", "systemVersion": "0", "appVersion": "sim", "keepAlive": "n/a (simulator)"}
    req = urllib.request.Request(base.rstrip("/") + "/api/stream/hello", data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", nargs="?", default="http://127.0.0.1:8212")
    ap.add_argument("--device", default="sim00001")
    ap.add_argument("--stream", default=None)
    ap.add_argument("--chunks", type=int, default=12)
    ap.add_argument("--chunk-seconds", type=float, default=10.0)
    ap.add_argument("--rate", type=float, default=100.0)
    ap.add_argument("--drop", type=int, action="append", default=[], help="seq to never send")
    ap.add_argument("--live", action="store_true", help="send one chunk per chunk-length in real time, forever")
    ap.add_argument("--backfill-seconds", type=float, default=None,
                    help="start this many seconds in the past (default: chunks × chunk-seconds)")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    stream = args.stream or f"sim{int(time.time()) % 100000:05d}"
    n = int(args.chunk_seconds * args.rate)
    back = args.backfill_seconds if args.backfill_seconds is not None else args.chunks * args.chunk_seconds
    start = time.time() - back
    first_mono = 1000.0
    print(post_hello(args.base, args.device, stream, args.rate, args.chunk_seconds))
    seq = 0
    while True:
        if not args.live and seq >= args.chunks:
            break
        chunk_start = start + seq * args.chunk_seconds
        if args.live and chunk_start + args.chunk_seconds > time.time():
            time.sleep(max(0.1, chunk_start + args.chunk_seconds - time.time()))
        body, header = make_chunk(device=args.device, stream=stream, seq=seq, start_epoch=chunk_start,
                                  first_mono=first_mono + seq * args.chunk_seconds, n=n, rate=args.rate, rng=rng)
        if seq in args.drop:
            print(f"seq {seq}: DROPPED on purpose")
        else:
            ack = post_chunk(args.base, body)
            print(f"seq {seq}: {ack.get('message')} ({len(body)} bytes on the wire)")
        seq += 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
