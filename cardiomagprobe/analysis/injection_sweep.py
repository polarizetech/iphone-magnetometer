#!/usr/bin/env python3
"""How big must a heartbeat-locked field be before `analyze_axis` finds it — in REAL phone noise.

Replaces `synthetic_validation.py` (removed 2026-09-15), which planted a waveform into a noise
MODEL (white + drift + a 10 Hz line) and swept its own amplitudes with its own loop. Two things
were wrong with that for this instrument: a noise model is not this phone's noise, and the sweep
duplicated `tools/injection-recovery`, whose rules exist for exactly this job — inject into real
host samples, randomise everything but the amplitude, score blank trials, and refuse a bound the
curve never reached.

The host is the stillest >=120 s stretch of a real FieldLab recording (the same selection
`ladder2.py` uses). The source is `injrec`'s cardiac train, whose beat times are handed to the
detector exactly as a PPG or ECG trigger would hand them. Blank trials are the same kind of
schedule with nothing planted, so the false-alarm rate is measured against the right null.

**An injection test validates the ANALYSIS.** It says nothing about whether a heart's field is
in any recording.

    python injection_sweep.py [--device ID] [--seconds 180] [--quick] [--out example_outputs]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _monorepo import use_injrec                          # noqa: E402

use_injrec()

import session as sm                                      # noqa: E402
import store                                              # noqa: E402
from cardiomag_analysis import Settings, analyze_axis     # noqa: E402
from injrec import bound_from_curve, sweep                # noqa: E402

AXIS = "mag_x_uT"
#: Detection criterion carried over from the removed script: p < 0.0125 needs >= 80 surrogates to
#: be attainable at all, since an empirical p cannot go below 1/(n+1).
ALPHA = 0.0125


def still_host(device: str | None, seconds: float) -> dict:
    best = None
    for dev in ([device] if device else store.devices()):
        for run in store.runs(dev):
            if run["covered_s"] < 120:
                continue
            try:
                ses = sm.load_stream(store.store_root() / dev,
                                     run["end"] - min(seconds, run["covered_s"]), run["end"])
            except FileNotFoundError:       # the trailing window falls in a gap inside the run
                continue
            still = float(np.mean(np.asarray(ses.rotation_magnitude, float) < 0.01))
            if still < 0.90:
                continue
            x = np.asarray(ses.xyz[0], float)
            score = float(np.std(np.diff(x)))
            if best is None or score < best["score"]:
                best = {"score": score, "t": np.asarray(ses.t, float) - float(ses.t[0]), "x": x,
                        "fs": float(ses.rate_hz), "device": dev, "still": still,
                        "seconds": float(ses.duration_s)}
    if best is None:
        raise SystemExit("no still window of >=120 s in the stream store")
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--device")
    ap.add_argument("--seconds", type=float, default=180.0)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default="example_outputs")
    a = ap.parse_args()

    host = still_host(a.device, a.seconds)
    t, fs = host["t"], host["fs"]
    surrogates = 80 if a.quick else 200
    settings = Settings(surrogates=surrogates, bootstraps=10)

    def detector(data, _fs, injection):
        # Through the phone's OWN timestamps, never index / fs: this phone's delivered rate differs
        # from its nominal one, and on this host index / fs drifts 377 ms from real time over
        # 180 s. Using the seconds directly smeared every epoch and read as "nothing detected at
        # ten times the host RMS" -- a bug in this script that looked like a finding about the null.
        beats = t[np.clip(np.asarray(injection.params["event_samples"], int), 0, len(t) - 1)]
        beats = beats[(beats > settings.pre) & (beats < t[-1] - settings.post)]
        if len(beats) < 20:
            return False
        df = pd.DataFrame({"monotonic_timestamp": t, AXIS: data})
        return analyze_axis(df, beats, AXIS, settings)["empirical_p"] < ALPHA

    curve = sweep(host["x"], fs, "cardiac", detector, pass_injection=True,
                  n_trials=4 if a.quick else 12, n_blank=8 if a.quick else 24,
                  k_grid=np.geomspace(0.003, 1.0, 5 if a.quick else 7),
                  refine=0 if a.quick else 1, rng=np.random.default_rng(20260915))
    host_rms_nt = float(np.std(host["x"])) * 1000.0
    summary = {
        "host": {"device": host["device"], "seconds": round(host["seconds"], 1),
                 "rate_hz": round(fs, 2), "still_fraction": round(host["still"], 3),
                 "axis": AXIS, "rms_nT": round(host_rms_nt, 2)},
        "detector": {"statistic": "analyze_axis empirical p (response-window RMS vs circular "
                                  "beat shifts)", "alpha": ALPHA, "surrogates": surrogates},
        "points": [{"k": round(p.k, 5), "amplitude_rms_nT": round(p.k * host_rms_nt, 3),
                    "trials": p.n_trials, "recovered": p.n_recovered,
                    "ci95": [round(c, 3) for c in p.ci95]} for p in sorted(curve.points, key=lambda p: p.k)],
        "k_50": curve.k_at.get(0.5), "k_95": curve.k_at.get(0.95),
        "false_alarm_rate": curve.false_alarm_rate, "blank_trials": curve.n_blank,
        "bound": bound_from_curve(curve, unit="x host RMS"),
        "note": curve.note or "An injection test validates the analysis, never the world.",
        "quick": bool(a.quick),
    }
    out = HERE / a.out
    out.mkdir(parents=True, exist_ok=True)
    (out / "injection_sweep.json").write_text(json.dumps(summary, indent=2))
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        pts = summary["points"]
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.errorbar([p["amplitude_rms_nT"] for p in pts], [p["recovered"] / p["trials"] for p in pts],
                    yerr=np.array([[p["recovered"] / p["trials"] - p["ci95"][0],
                                    p["ci95"][1] - p["recovered"] / p["trials"]] for p in pts]).T,
                    marker="o", capsize=3)
        ax.axhline(summary["false_alarm_rate"], ls="--", lw=1, label="false-alarm rate (blank trials)")
        ax.set(xscale="log", xlabel="Injected cardiac RMS (nT)", ylabel="Recovered",
               ylim=(-0.03, 1.03), title=f"Injection recovery in real FieldLab noise ({host['device']})")
        ax.grid(alpha=0.25); ax.legend(); fig.tight_layout()
        fig.savefig(out / "injection_sweep.png", dpi=160); plt.close(fig)
    except ImportError:
        pass
    print(json.dumps({k: v for k, v in summary.items() if k != "points"}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
