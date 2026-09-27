#!/usr/bin/env python3
"""How much prior knowledge does it take to pull a cardiac signal out of REAL iPhone noise?

The spec's stated core goal, run as a measurement instead of a hope:

    Level 0  no prior          the largest line anywhere in the band
    Level 1  heart-rate band   the largest line in 0.8-2.0 Hz
    Level 2  exact beat times  beat-triggered average vs a shuffled-beat null   <- what PPG buys
    Level 3  + morphology      frozen template, trained on half, scored on the held-out half

For each level: inject a cardiac source at known amplitude into a real stationary iPhone
magnetometer record, sweep the amplitude, and report the smallest signal recovered 95% of the
time (`k95`) **in nanotesla**. Then compare that against 50 pT, the measured magnetocardiogram at
5 cm.

**This measures the ANALYSIS, not the world.** Recovering a planted signal shows the pipeline
*would have found one*, which is what makes a null mean something and is precisely not evidence
that anything is there. That standing caveat is `tools/injection-recovery`'s and it applies here
in full.

Levels 4 (preferred XYZ projection) and 5 (spatial behaviour across distances) are NOT run: the
first needs a three-axis injection with a known orientation, the second needs recordings at
several distances. Both are listed rather than silently dropped.

    python3 prior_ladder.py [--seconds 300] [--trials 12]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from scipy import signal as sg


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for c in here.parents:
        if (c / "tools").is_dir() and (c / "falsify").is_dir():
            return c
    raise RuntimeError("monorepo root not found. This script plants synthetic cardiac sources with injrec (tools/injection-recovery), which lives in the audio-projects monorepo; run it from a checkout where this repo is tools/iphone-magnetometer. session and census are in this repo.")


ROOT = _repo_root()
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))   # this repo: store, bands, session, census
sys.path.insert(0, str(ROOT / "tools" / "injection-recovery"))

import store                                            # noqa: E402
from injrec.inject import cardiac_source                # noqa: E402
import census                                   # noqa: E402
import session as sm                            # noqa: E402

#: The measured magnetocardiogram anchor: ~50 pT at 5 cm (research/, coupling_budget.py).
MCG_5CM_NT = 0.050

CARDIAC_F0 = 1.1
SEARCH_LO, SEARCH_HI = 0.8, 2.0
BAND_LO, BAND_HI = 0.5, 45.0


# ------------------------------------------------------------------ the host: real phone noise
def load_host(seconds: float = 300.0, only_device: str | None = None):
    """The quietest axis of the cleanest real stationary window in the stream store.

    A synthetic host would make every number below a statement about numpy. The whole point is
    that this is the noise the actual instrument produces, including whatever is wrong with it.
    """
    best = None
    for dev in store.devices():
        if only_device and dev != only_device:
            continue
        runs = [r for r in store.runs(dev) if r["covered_s"] >= 120]
        if not runs:
            continue
        run = max(runs, key=lambda r: r["covered_s"])
        dev_dir = store.store_root() / dev
        ses = sm.load_stream(dev_dir, run["end"] - min(seconds, run["covered_s"]), run["end"])
        fs_row = float(ses.rate_hz)
        for name, row in zip("xyz", np.asarray(ses.xyz, dtype=float)):
            x = (row - np.mean(row)) * 1000.0                    # uT -> nT
            # HIGH-PASS THE HOST before anything else. `k` is scaled to host RMS, and if that RMS
            # is dominated by sub-1 Hz drift the detectors bandpass away, then k95-expressed-in-nT
            # is inflated by exactly that ratio and two records are not comparable. Measured: one
            # segment carried 9.1x more drift than in-band noise and read as 7x WORSE than a
            # noisier record, with L2 scoring below L0 — the tell that the metric, not the phone,
            # was wrong. The detectors already band-limit; this makes the SCALE agree with them.
            _b, _a = sg.butter(3, BAND_LO / (fs_row / 2), btype="high")
            x = sg.filtfilt(_b, _a, x)
            # judge on the CARDIAC band, not broadband: an axis can be quiet overall and noisy
            # exactly where the signal would live. eeg-bridge measured a broadband RMS
            # overstating in-band noise by 20-90x, and the error points the dangerous way.
            f, P = sg.welch(x, ses.rate_hz, nperseg=int(min(len(x), ses.rate_hz * 20)))
            m = (f >= 1) & (f <= 10)
            score = float(np.median(P[m]))
            if best is None or score < best["score"]:
                best = {"score": score, "x": x, "fs": float(ses.rate_hz), "device": dev,
                        "axis": name, "seconds": float(ses.duration_s),
                        "asd_cardiac_nt": float(np.sqrt(score) * 1.0),
                        "rms_nt": float(np.std(x))}
    if best is None:
        raise SystemExit("no usable stationary window in the stream store")
    return best


# ------------------------------------------------------------------------------ beat machinery
def make_source(fs: float, n: int, rng):
    """A cardiac impulse train with RSA and HRV, unit RMS, plus its TRUE beat sample indices."""
    sig = cardiac_source(fs, n / fs, f0_hz=CARDIAC_F0, rng=rng)[:n]
    if len(sig) < n:
        sig = np.pad(sig, (0, n - len(sig)))
    # the source is a train of hanning bumps; its own peaks are ground truth for beat times
    peaks, _ = sg.find_peaks(sig, height=np.max(sig) * 0.4, distance=int(fs * 0.4))
    return sig, peaks


def epochs_at(x, beats, fs, pre=0.30, post=0.50):
    a, b = int(pre * fs), int(post * fs)
    keep = [p for p in beats if p - a >= 0 and p + b < len(x)]
    if not keep:
        return np.zeros((0, a + b))
    ep = np.stack([x[p - a:p + b] for p in keep])
    return ep - ep[:, :a].mean(axis=1, keepdims=True)      # baseline on the pre-interval


def bandpass(x, fs, lo=BAND_LO, hi=BAND_HI):
    hi = min(hi, fs / 2 * 0.98)
    b, a = sg.butter(3, [lo / (fs / 2), hi / (fs / 2)], btype="band")
    return sg.filtfilt(b, a, x)


# ------------------------------------------------------------------------------ the four levels
def level0(x, fs, beats, rng):
    """No prior at all: is there ANY line above a bar computed for the whole searched band?"""
    f, P = census.spectrum(x - x.mean(), fs)
    if f.size == 0:
        return False
    sel = (f >= BAND_LO) & (f <= BAND_HI)
    idx = np.where(sel)[0]
    peak = int(idx[np.argmax(P[idx])])
    prom = census.prominence(P, f, float(f[peak]), float(f[1] - f[0]))
    bar = census.prominence_threshold_db(int(idx.size), 0.01)
    return bool(prom is not None and prom >= bar)


def level1(x, fs, beats, rng):
    """Heart-rate band only. A smaller search family, so a lower bar for the same alpha."""
    f, P = census.spectrum(x - x.mean(), fs)
    if f.size == 0:
        return False
    sel = (f >= SEARCH_LO) & (f <= SEARCH_HI)
    idx = np.where(sel)[0]
    if idx.size == 0:
        return False
    peak = int(idx[np.argmax(P[idx])])
    prom = census.prominence(P, f, float(f[peak]), float(f[1] - f[0]))
    bar = census.prominence_threshold_db(int(idx.size), 0.01)
    return bool(prom is not None and prom >= bar)


def level2(x, fs, beats, rng, n_sur=120):
    """Exact beat times: beat-triggered average against a SHUFFLED-BEAT null.

    This is what a PPG buys, and it is the biggest single step on the ladder.
    """
    xb = bandpass(x, fs)
    ep = epochs_at(xb, beats, fs)
    if len(ep) < 20:
        return False
    real = float(np.sqrt(np.mean(np.mean(ep, axis=0) ** 2)))
    n = len(xb)
    null = np.empty(n_sur)
    for i in range(n_sur):
        fake = rng.integers(int(0.35 * fs), n - int(0.55 * fs), size=len(beats))
        e = epochs_at(xb, np.sort(fake), fs)
        null[i] = float(np.sqrt(np.mean(np.mean(e, axis=0) ** 2))) if len(e) else 0.0
    return bool(real > np.percentile(null, 95))


def level3(x, fs, beats, rng, n_sur=120):
    """Beat times PLUS morphology: a template frozen on the first half, scored on the second.

    Never trained and scored on the same beats -- the spec is right to insist, and a matched
    filter scored on its own training beats will happily report a template it invented.
    """
    xb = bandpass(x, fs)
    half = len(beats) // 2
    if half < 15:
        return False
    train, test = beats[:half], beats[half:]
    ep_tr = epochs_at(xb, train, fs)
    if len(ep_tr) < 10:
        return False
    tmpl = np.mean(ep_tr, axis=0)
    nrm = np.linalg.norm(tmpl)
    if nrm == 0:
        return False
    tmpl = tmpl / nrm

    def score(bs):
        e = epochs_at(xb, bs, fs)
        if len(e) == 0:
            return 0.0
        return float(np.mean(e @ tmpl))

    real = score(test)
    n = len(xb)
    null = np.empty(n_sur)
    for i in range(n_sur):
        fake = rng.integers(int(0.35 * fs), n - int(0.55 * fs), size=len(test))
        null[i] = score(np.sort(fake))
    return bool(real > np.percentile(null, 95))


LEVELS = [("L0 no prior", level0), ("L1 rate band", level1),
          ("L2 beat times", level2), ("L3 + morphology", level3)]


# ------------------------------------------------------------------------------------ the sweep
def run(host, trials=12, k_grid=None, seed=0):
    x, fs = host["x"], host["fs"]
    rng = np.random.default_rng(seed)
    host_rms = float(np.std(x))
    grid = list(k_grid or np.geomspace(0.003, 3.0, 9))
    out = []
    for name, det in LEVELS:
        # BLANKS FIRST. A curve with no false-alarm rate cannot tell a sensitive detector from
        # one that fires on everything -- injection-recovery's own rule, and it refuses to quote
        # a bound past 5%.
        blanks = 0
        for _ in range(trials):
            _s, beats = make_source(fs, len(x), np.random.default_rng(int(rng.integers(1 << 31))))
            blanks += bool(det(x + rng.normal(0, 1e-9, len(x)), fs, beats, rng))
        curve = []
        for k in grid:
            rec = 0
            for _ in range(trials):
                r2 = np.random.default_rng(int(rng.integers(1 << 31)))
                sig, beats = make_source(fs, len(x), r2)
                rec += bool(det(x + k * host_rms * sig, fs, beats, rng))
            curve.append((float(k), rec / trials))
        k95 = _cross(curve, 0.95)
        k50 = _cross(curve, 0.50)
        fa = blanks / trials
        out.append({"level": name, "k95": k95, "k50": k50,
                    "k95_nt": None if not np.isfinite(k95) else k95 * host_rms,
                    "k50_nt": None if not np.isfinite(k50) else k50 * host_rms,
                    "false_alarm": fa, "curve": curve,
                    "quotable": bool(fa <= 0.05 and np.isfinite(k95))})
    return out


def _cross(curve, target):
    pts = sorted(curve)
    for (k0, p0), (k1, p1) in zip(pts, pts[1:]):
        if p0 < target <= p1:
            if p1 == p0:
                return k1
            return float(np.exp(np.log(k0) + (target - p0) / (p1 - p0) * (np.log(k1) - np.log(k0))))
    return float("nan")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=300.0)
    ap.add_argument("--trials", type=int, default=12)
    ap.add_argument("--json", default=None)
    ap.add_argument("--device", default=None, help="force a host device, to compare sites")
    args = ap.parse_args()

    host = load_host(args.seconds, args.device)
    print(f"HOST  device {host['device']} axis {host['axis']}  "
          f"{host['seconds']:.0f} s @ {host['fs']:.1f} Hz")
    print(f"      host RMS {host['rms_nt']:.2f} nT   "
          f"cardiac-band ASD {host['asd_cardiac_nt']:.2f} nT/sqrt(Hz)")
    print("      REAL iPhone magnetometer noise, not synthetic\n")

    rows = run(host, trials=args.trials)
    print(f"{'prior level':18s} {'k95':>8s} {'k95 in nT':>11s} {'k50 in nT':>11s} "
          f"{'false alarm':>12s} {'quotable':>9s}")
    for r in rows:
        k95 = f"{r['k95']:.4f}" if np.isfinite(r['k95']) else "not reached"
        n95 = f"{r['k95_nt']:.3f}" if r['k95_nt'] else "—"
        n50 = f"{r['k50_nt']:.3f}" if r['k50_nt'] else "—"
        print(f"{r['level']:18s} {k95:>8s} {n95:>11s} {n50:>11s} "
              f"{r['false_alarm']*100:>11.0f}% {'yes' if r['quotable'] else 'NO':>9s}")

    print(f"\nCardiac target at 5 cm: {MCG_5CM_NT:.3f} nT (measured MCG anchor).")
    best = min((r for r in rows if r["quotable"] and r["k95_nt"]),
               key=lambda r: r["k95_nt"], default=None)
    if best:
        gap = best["k95_nt"] / MCG_5CM_NT
        print(f"Best quotable level: {best['level']} at {best['k95_nt']:.3f} nT "
              f"-> the cardiac signal is {gap:,.0f}x BELOW what this analysis can recover")
        print(f"   closing it by averaging alone needs {gap**2:,.0f}x more beats than this window held.")
    if args.json:
        Path(args.json).write_text(json.dumps(
            {"host": {k: v for k, v in host.items() if k != "x"}, "levels": rows}, indent=1))
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
