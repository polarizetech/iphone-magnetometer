#!/usr/bin/env python3
"""Which spot in the building is actually good for a heartbeat search?

**Not the quietest one.** Measured 2026-08-26: moving the phone to a location 3x quieter in the
1-10 Hz band made the search WORSE, because the new spot carried a persistent line at 1.8902 Hz —
113 per minute, inside the heart-rate band. A line inside the band you are searching costs an
entire prior level (the band-search detector then fires on 100% of blanks), where broadband noise
only costs a factor in amplitude. **The figure of merit for site selection is the largest line
INSIDE the search band, not the noise outside it.**

You do the walking; this does the scoring. One continuous recording:

    put the phone down somewhere, leave it 3 minutes, pick it up,
    move to the next spot, put it down, 3 minutes, ... repeat.

Then run this. It finds the stationary stretches on its own (the gyro says when you were holding
it) and separates the positions on its own (the DC field shifts when the phone moves, measured at
90 uT for one relocation), so you never have to write anything down.

    python3 site_survey.py [--device X] [--min-seconds 120]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from scipy import signal as sg


def _repo_root() -> Path:
    for c in Path(__file__).resolve().parents:
        if (c / "tools").is_dir() and (c / "falsify").is_dir():
            return c
    raise RuntimeError("monorepo root not found. This script reads the recorder's stream store and the fieldlab analysis package (session, census), which still live in the audio-projects monorepo; run it from a checkout where this repo is tools/iphone-magnetometer.")


ROOT = _repo_root()
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))   # this repo: store.py, bands.py
sys.path.insert(0, str(ROOT / "falsify" / "round-the-world-elf" / "analysis"))

import store                                        # noqa: E402
from fieldlab import census, session as sm          # noqa: E402

SEARCH_LO, SEARCH_HI = 0.8, 2.0        # the heart-rate band a Level-1 detector would search
STILL_RADS = 0.01                      # gyro below this and the phone is sitting there
DC_JUMP_UT = 15.0                      # a DC shift this large means the phone was relocated
ALPHA = 0.01


def still_segments(rot, fs, min_seconds):
    """Contiguous stretches where the phone was not being handled."""
    still = np.asarray(rot, float) < STILL_RADS
    out, start = [], None
    for i, s in enumerate(still):
        if s and start is None:
            start = i
        elif not s and start is not None:
            if (i - start) / fs >= min_seconds:
                out.append((start, i))
            start = None
    if start is not None and (len(still) - start) / fs >= min_seconds:
        out.append((start, len(still)))
    return out


def score(x, fs):
    """Everything that decides whether a spot is usable, for one axis."""
    x = np.asarray(x, float)
    x = x - np.mean(x)
    b, a = sg.butter(3, 0.5 / (fs / 2), btype="high")
    x = sg.filtfilt(b, a, x)

    f, P = sg.welch(x, fs, nperseg=int(min(len(x), fs * 20)))
    m = (f >= 1) & (f <= 10)
    asd = float(np.sqrt(np.median(P[m]))) if m.any() else float("nan")

    # the line that actually matters: the strongest one INSIDE the search band
    ff, PP = census.spectrum(x, fs)
    res = float(ff[1] - ff[0]) if ff.size > 1 else 0.0
    sel = np.where((ff >= SEARCH_LO) & (ff <= SEARCH_HI))[0]
    bar = census.prominence_threshold_db(int(sel.size), ALPHA) if sel.size else float("nan")
    worst_hz, worst_db = None, -np.inf
    for i in sel:
        pr = census.prominence(PP, ff, float(ff[i]), res)
        if pr is not None and pr > worst_db:
            worst_db, worst_hz = pr, float(ff[i])
    return {"asd_1_10_nt": asd, "line_hz": worst_hz,
            "line_db": None if worst_db == -np.inf else float(worst_db),
            "bar_db": float(bar),
            "clean": bool(worst_db != -np.inf and worst_db < bar)}


def survey(device, min_seconds=120.0, window_s=None):
    runs = store.runs(device)
    if not runs:
        return []
    run = runs[-1] if window_s is None else runs[-1]
    ses = sm.load_stream(store.store_root() / device,
                         run["end"] - min(window_s or run["covered_s"], run["covered_s"]),
                         run["end"])
    fs = float(ses.rate_hz)
    xyz = np.asarray(ses.xyz, float) * 1000.0
    rot = np.asarray(ses.rotation_magnitude, float)

    positions = []
    for i0, i1 in still_segments(rot, fs, min_seconds):
        sl = slice(i0, i1)
        dc = np.array([np.mean(row[sl]) for row in xyz]) / 1000.0     # uT
        # merge into the previous position if the phone did not actually move
        if positions and np.linalg.norm(dc - positions[-1]["dc_ut"]) < DC_JUMP_UT:
            positions[-1]["slices"].append(sl)
            positions[-1]["seconds"] += (i1 - i0) / fs
        else:
            positions.append({"dc_ut": dc, "slices": [sl], "seconds": (i1 - i0) / fs,
                              "start_min": i0 / fs / 60})
    out = []
    for n, pos in enumerate(positions, 1):
        best = None
        for ax, row in zip("xyz", xyz):
            x = np.concatenate([row[s] for s in pos["slices"]])
            sc = score(x, fs)
            if best is None or (sc["asd_1_10_nt"] < best["asd_1_10_nt"]):
                best = dict(sc, axis=ax)
        out.append({"position": n, "start_min": pos["start_min"], "seconds": pos["seconds"],
                    "dc_ut": pos["dc_ut"], **best})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default=None)
    ap.add_argument("--min-seconds", type=float, default=120.0)
    args = ap.parse_args()

    devices = [args.device] if args.device else store.devices()
    for dev in devices:
        rows = survey(dev, args.min_seconds)
        if not rows:
            print(f"{dev}: no stationary stretch of >= {args.min_seconds:.0f} s in the latest run")
            continue
        print(f"\n=== {dev} — latest run, stationary positions ===\n")
        print(f"{'pos':>4s} {'at':>7s} {'mins':>6s} {'axis':>5s} {'ASD 1-10Hz':>11s} "
              f"{'worst in-band line':>26s} {'verdict':>9s}")
        for r in rows:
            ln = (f"{r['line_hz']:.4f} Hz  {r['line_db']:5.1f}/{r['bar_db']:.1f} dB"
                  if r["line_hz"] else "none resolved")
            print(f"{r['position']:>4d} {r['start_min']:6.1f}m {r['seconds']/60:6.1f} {r['axis']:>5s} "
                  f"{r['asd_1_10_nt']:11.2f} {ln:>26s} {'USABLE' if r['clean'] else 'has a line':>9s}")
        clean = [r for r in rows if r["clean"]]
        print()
        if clean:
            best = min(clean, key=lambda r: r["asd_1_10_nt"])
            print(f"  BEST: position {best['position']} (at {best['start_min']:.0f} min) — "
                  f"no line above the bar, and the quietest of those that qualify "
                  f"({best['asd_1_10_nt']:.1f} nT/sqrt(Hz)).")
        else:
            print("  NO position is clean in the heart-rate band. Every spot recorded carries a "
                  "line above the bar,\n  so a Level-1 band search is unusable everywhere here — "
                  "try more spots, further from wiring and appliances.")
        print("\n  Ranked by the LINE, not by the noise. A quieter spot with a line in the band is "
              "worse than a\n  noisier spot without one: the line costs a whole prior level, the "
              "noise costs a factor in amplitude.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
