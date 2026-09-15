#!/usr/bin/env python3
"""The prior-knowledge ladder, rebuilt to the methods document's standard.

Implements what `iphone_magnetometer_weak_biomagnetic_signal_extraction_methods.md` v1.0 specifies
and the first ladder did not:

  §6.6  WHITENED matched filter,  score = sTC^-1x / sqrt(sTC^-1s), C from training data only.
        A plain correlation is optimal only in WHITE noise; this host is not white.
  §6.8  MULTIAXIS combination with weights learned on the training half and applied to the
        held-out half. |B| is refused -- it discards sign and biases nonlinearly.
  §7.1  MAX-STATISTIC nulls. The surrogate must run the COMPLETE pipeline including every search
        the real analysis performs (lag, axis), and the observed value is compared against the
        distribution of surrogate MAXIMA. Comparing against a per-cell percentile ignores the
        researcher degrees of freedom and reports an optimistic threshold.
  §7.1  Four null families, not one: circular shift, interval permutation, ANTI-TRIGGERS
        (halfway between beats), and time-reversal within the block.

Anchor corrected 2026-08-26 to Roth (2024), *Biophysics Reviews* 5(2):021305: the magnetocardiogram
is **10-100 pT peak at about 3 cm above the chest**. The repo's `MCG_TESLA_AT_5CM = 50 pT at 5 cm`
had the distance wrong; the honest figure is a RANGE, and the low end of it matters.

**Still an injection test.** It measures the analysis, never the world.
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
sys.path.insert(0, str(ROOT / "tools" / "injection-recovery"))
sys.path.insert(0, str(ROOT / "falsify" / "round-the-world-elf" / "analysis"))

import store                                        # noqa: E402
from injrec.inject import cardiac_source            # noqa: E402
from fieldlab import session as sm                  # noqa: E402

#: Roth (2024): 10-100 pT peak at ~3 cm above the chest. A range, reported as one.
MCG_NT_AT_3CM = (0.010, 0.100)
MCG_DISTANCE_M = 0.03

BAND = (0.5, 40.0)          # §6.4, the PMI MCG precedent
PRE, POST = 0.30, 0.50      # epoch around each beat
CARDIAC_F0 = 1.1
#: §3.3 -- PPG lags the R wave and the offset is not fixed. The detector SEARCHES this window,
#: so the null must search it too or the threshold is meaningless.
LAG_WINDOW_S = (-0.20, 0.20)
LAG_STEPS = 9


def bandpass(x, fs):
    lo, hi = BAND[0], min(BAND[1], fs / 2 * 0.98)
    b, a = sg.butter(3, [lo / (fs / 2), hi / (fs / 2)], btype="band")
    return sg.filtfilt(b, a, x)


def epochs(x, beats, fs, shift=0.0):
    a, b = int(PRE * fs), int(POST * fs)
    s = int(round(shift * fs))
    keep = [p + s for p in beats if 0 <= p + s - a and p + s + b < len(x)]
    if len(keep) < 8:
        return np.zeros((0, a + b))
    ep = np.stack([x[p - a:p + b] for p in keep])
    return ep - ep[:, :a].mean(axis=1, keepdims=True)


def whitener(train_ep):
    """C^-1/2 from the TRAINING epochs only (§6.6). Diagonal-loaded so it inverts."""
    n = train_ep.shape[1]
    if train_ep.shape[0] < n // 2:                 # not enough epochs for a full covariance
        v = train_ep.var(axis=0) + 1e-18
        return np.diag(1.0 / np.sqrt(v))
    C = np.cov(train_ep, rowvar=False) + np.eye(n) * 1e-12 * np.trace(np.cov(train_ep, rowvar=False)) / n
    w, V = np.linalg.eigh(C)
    w = np.maximum(w, w.max() * 1e-8)
    return V @ np.diag(w ** -0.5) @ V.T


def statistic(xs, beats, fs, train_frac=0.5):
    """The full detector: whitened matched filter, held-out, multiaxis, searched over lag.

    Returns the MAXIMUM score over the searched lags — which is what the real analysis would
    report, and therefore what a surrogate must also be allowed to find.
    """
    half = int(len(beats) * train_frac)
    if half < 12 or len(beats) - half < 12:
        return -np.inf
    train, test = beats[:half], beats[half:]
    best = -np.inf
    for lag in np.linspace(*LAG_WINDOW_S, LAG_STEPS):
        per_axis_tmpl, per_axis_W, ok = [], [], True
        for x in xs:
            tr = epochs(x, train, fs, lag)
            if len(tr) < 8:
                ok = False
                break
            W = whitener(tr)
            t = (tr @ W.T).mean(axis=0)
            nrm = np.linalg.norm(t)
            if nrm == 0:
                ok = False
                break
            per_axis_tmpl.append(t / nrm)
            per_axis_W.append(W)
        if not ok:
            continue
        # §6.8 axis weights learned on TRAIN, applied to TEST
        wts = []
        for x, W, t in zip(xs, per_axis_W, per_axis_tmpl):
            tr = epochs(x, train, fs, lag)
            wts.append(float(np.mean((tr @ W.T) @ t)))
        wts = np.array(wts)
        nw = np.linalg.norm(wts)
        if nw == 0:
            continue
        wts = wts / nw
        score = 0.0
        for wgt, x, W, t in zip(wts, xs, per_axis_W, per_axis_tmpl):
            te = epochs(x, test, fs, lag)
            if len(te) == 0:
                score = -np.inf
                break
            score += wgt * float(np.mean((te @ W.T) @ t))
        best = max(best, score)
    return best


def surrogate_beats(beats, n_samples, fs, kind, rng):
    """§7.1 — four null families. Each must be run through the COMPLETE pipeline."""
    b = np.asarray(beats)
    if kind == "circular":
        off = rng.integers(int(2 * fs), n_samples - int(2 * fs))
        return np.sort((b + off) % n_samples)
    if kind == "interval":
        d = np.diff(b)
        rng.shuffle(d)
        out = np.cumsum(np.concatenate([[b[0]], d]))
        return out[out < n_samples - int(POST * fs) - 1]
    if kind == "anti":                              # halfway between real beats
        return np.sort(((b[:-1] + b[1:]) // 2).astype(int))
    if kind == "shuffle":
        return np.sort(rng.integers(int(PRE * fs) + 1,
                                    n_samples - int(POST * fs) - 1, size=len(b)))
    raise ValueError(kind)


NULL_KINDS = ("circular", "interval", "anti", "shuffle")


def max_statistic_null(xs, beats, fs, n_sur, rng):
    """The distribution of the MAXIMUM statistic under the null (§7.1).

    Max over BOTH the searched lags (inside `statistic`) and the null families, because a real
    analyst who tried four nulls would report the most favourable comparison.
    """
    n = len(xs[0])
    out = []
    for i in range(n_sur):
        kind = NULL_KINDS[i % len(NULL_KINDS)]
        sb = surrogate_beats(beats, n, fs, kind, rng)
        if len(sb) < 24:
            continue
        out.append(statistic(xs, sb, fs))
    return np.array([v for v in out if np.isfinite(v)])


def load_host(device=None, seconds=400.0):
    """Three axes of the cleanest still stretch of a real recording. Bandpassed, not |B|."""
    best = None
    for dev in ([device] if device else store.devices()):
        for run in store.runs(dev):
            if run["covered_s"] < 120:
                continue
            ses = sm.load_stream(store.store_root() / dev,
                                 run["end"] - min(seconds, run["covered_s"]), run["end"])
            rot = np.asarray(ses.rotation_magnitude, float)
            still = float(np.mean(rot < 0.01))
            if still < 0.90:
                continue
            fs = float(ses.rate_hz)
            xs = [bandpass(r * 1000.0 - np.mean(r * 1000.0), fs)
                  for r in np.asarray(ses.xyz, float)]
            score = float(np.median([np.std(x) for x in xs]))
            if best is None or score < best["score"]:
                best = {"score": score, "xs": xs, "fs": fs, "device": dev,
                        "seconds": float(ses.duration_s), "still": still}
    if best is None:
        raise SystemExit("no still window of >=120 s in the store")
    return best


def sweep(host, k_grid, trials, n_sur, seed=0):
    xs, fs = host["xs"], host["fs"]
    rng = np.random.default_rng(seed)
    n = len(xs[0])
    ref = float(np.median([np.std(x) for x in xs]))     # in-band RMS, the honest scale
    rows = []
    # one null, reused: it depends on the host and the beat structure, not on k
    _, beats0 = _source(fs, n, np.random.default_rng(1))
    null = max_statistic_null(xs, beats0, fs, n_sur, rng)
    thr = float(np.percentile(null, 95)) if null.size else np.inf
    fa = float(np.mean(null > thr)) if null.size else float("nan")
    for k in k_grid:
        rec = 0
        for _ in range(trials):
            r2 = np.random.default_rng(int(rng.integers(1 << 31)))
            sig, beats = _source(fs, n, r2)
            amp = k * ref
            # inject on ALL THREE axes with a random orientation -- a real dipole is not axis-aligned
            u = r2.normal(size=3)
            u = u / np.linalg.norm(u)
            xs_inj = [x + amp * ui * sig for x, ui in zip(xs, u)]
            rec += bool(statistic(xs_inj, beats, fs) > thr)
        rows.append((float(k), rec / trials))
    return rows, thr, fa, ref, null


def _source(fs, n, rng):
    s = cardiac_source(fs, n / fs, f0_hz=CARDIAC_F0, rng=rng)[:n]
    if len(s) < n:
        s = np.pad(s, (0, n - len(s)))
    pk, _ = sg.find_peaks(s, height=np.max(s) * 0.4, distance=int(fs * 0.4))
    return s, pk


def _cross(curve, target):
    pts = sorted(curve)
    for (k0, p0), (k1, p1) in zip(pts, pts[1:]):
        if p0 < target <= p1 and p1 != p0:
            return float(np.exp(np.log(k0) + (target - p0) / (p1 - p0) * (np.log(k1) - np.log(k0))))
    return float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=None)
    ap.add_argument("--trials", type=int, default=8)
    ap.add_argument("--surrogates", type=int, default=48)
    ap.add_argument("--seconds", type=float, default=400.0)
    a = ap.parse_args()

    host = load_host(a.device, a.seconds)
    print(f"HOST {host['device']}  {host['seconds']/60:.1f} min @ {host['fs']:.1f} Hz  "
          f"still {host['still']*100:.1f}%  3 axes, band {BAND[0]}-{BAND[1]} Hz")
    grid = list(np.geomspace(0.002, 1.0, 8))
    rows, thr, fa, ref, null = sweep(host, grid, a.trials, a.surrogates)
    print(f"\nMAX-STATISTIC null: {null.size} surrogates over "
          f"{len(NULL_KINDS)} families x {LAG_STEPS} lags")
    print(f"   threshold (95th pct of surrogate MAXIMA) = {thr:.5f}")
    print(f"   in-band RMS of host = {ref:.1f} nT\n")
    print(f"{'k':>10s} {'P(detect)':>10s} {'amplitude nT':>13s}")
    for k, p in rows:
        print(f"{k:10.4f} {p:10.2f} {k*ref:13.2f}")
    k95, k50 = _cross(rows, 0.95), _cross(rows, 0.50)
    print()
    for lab, kk in (("k95", k95), ("k50", k50)):
        print(f"  {lab}: " + (f"{kk:.4f} = {kk*ref:.2f} nT" if np.isfinite(kk) else "not reached"))
    if np.isfinite(k95):
        lo, hi = MCG_NT_AT_3CM
        print(f"\n  Roth 2024 anchor: {lo*1000:.0f}-{hi*1000:.0f} pT at 3 cm above the chest")
        print(f"  gap: {k95*ref/hi:,.0f}x (against the 100 pT best case) "
              f"to {k95*ref/lo:,.0f}x (against 10 pT)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
