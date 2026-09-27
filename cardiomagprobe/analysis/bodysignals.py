#!/usr/bin/env python3
"""Loud body signals already inside FieldLab's wire format.

**Three rows of the readout matrix need no new app code and no new hardware.** Every chunk this
project has ever recorded carries `ax_g, ay_g, az_g` and `gx_rads, gy_rads, gz_rads` alongside the
magnetometer. What is missing for SCG, tremor and sway is not a sensor — it is a **placement**.

    scan(device)            is there a cardiac-band line in the ACCELEROMETER of any run?
    scg(session)            seismocardiogram: rate, harmonics, and the motion discriminator
    tremor(session)         8-12 Hz physiological tremor band power vs the 1-4 Hz reference
    sway(session)           postural sway path length and ellipse area

## Why the accelerometer, when this project is about the magnetometer

The same heartbeat, two channels, on the same phone in the same chunk:

    SCG   1-20 mg  against a ~300 ug/sqrt(Hz) MEMS floor   ->  SNR/beat  0.6 to 11.3
    MCG   50 pT    against a 15.6 nT/sqrt(Hz) floor        ->  SNR/beat  5.4e-4

**~1,000x easier at the weak end, ~20,000x at the strong end** — single-beat detection with no
averaging at all, so the two walls that dominate the magnetic problem (sensitivity, averaging
depth) simply do not arise. It is a different measurement: **mechanical, not magnetic.** It reads
what the heart MOVES, not the field it makes. Nothing here is magnetocardiography and this module
must never be cited as though it were.

## The discriminator that does the work

A heartbeat displaces the case and barely rotates it. Walking, handling and being carried drive
**both** channels. So `accel_gyro_ratio` is the first test, and it is not sufficient on its own —
a marginal candidate at 1.2772 Hz in this project's own archive passed the ratio test at 10.4x and
was rejected on **persistence** (16.2 -> 3.4 dB across quarters) and **absent harmonics** (0.8 dB
at 2f). An SCG is impulsive and quasi-periodic, so it must show both.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from scipy import signal as sg


sys.path.insert(0, str(Path(__file__).resolve().parents[2]))   # this repo: store, bands, session, census

import store                                    # noqa: E402
import census                                   # noqa: E402
import session as sm                            # noqa: E402

CARDIAC_BAND = (0.8, 2.0)          # 48-120 bpm
TREMOR_BAND = (8.0, 12.0)          # beta-adrenergic physiological tremor
TREMOR_REF = (1.0, 4.0)            # voluntary-motion reference
ALPHA = 0.01

#: A candidate must beat this ratio of accelerometer to gyro prominence, AND be persistent, AND
#: show a harmonic. Any one alone has already produced a false positive in this archive.
MIN_ACCEL_GYRO_RATIO = 3.0
MIN_QUARTERS_PRESENT = 3
MIN_HARMONIC_DB = 3.0


def _band(x, fs, lo, hi):
    hi = min(hi, fs / 2 * 0.95)
    b, a = sg.butter(3, [lo / (fs / 2), hi / (fs / 2)], btype="band")
    return sg.filtfilt(b, a, np.asarray(x, float) - np.mean(x))


def _peak(x, fs, lo, hi):
    """Strongest line in a band, its prominence, and the bar for the number of bins searched."""
    f, P = census.spectrum(np.asarray(x, float) - np.mean(x), fs)
    if f.size == 0:
        return None, None, float("nan")
    sel = np.where((f >= lo) & (f <= hi))[0]
    if not sel.size:
        return None, None, float("nan")
    pk = int(sel[np.argmax(P[sel])])
    res = float(f[1] - f[0])
    return float(f[pk]), census.prominence(P, f, float(f[pk]), res), \
        census.prominence_threshold_db(int(sel.size), ALPHA)


def scg(session, band=CARDIAC_BAND) -> dict:
    """Seismocardiogram reading of one session, with every discriminator reported.

    Returns a verdict of `cardiac-like`, `motion`, or `absent`. **Never `cardiac`** — this reads
    chest-wall motion, and calling it a heartbeat is the consumer's claim to make, not this
    function's.
    """
    fs = float(session.rate_hz)
    acc = np.asarray(session.acceleration_magnitude, float)
    gyr = np.asarray(session.rotation_magnitude, float)
    if acc is None or acc.size < int(fs * 30):
        return {"available": False, "reason": "under 30 s of accelerometer data"}

    xb = _band(acc, fs, 0.5, min(20.0, fs / 2 * 0.9))
    hz, prom, bar = _peak(xb, fs, *band)
    if hz is None or prom is None:
        return {"available": True, "verdict": "absent", "reason": "no line in the cardiac band"}

    f, P = census.spectrum(xb, fs)
    res = float(f[1] - f[0])
    _, gp, _ = _peak(gyr, fs, hz - 0.05, hz + 0.05) if gyr is not None and gyr.size else (None, None, None)
    ratio = (prom / gp) if (gp and gp > 0) else float("inf")

    n = len(xb) // 4
    quarters = []
    for i in range(4):
        ff, PP = census.spectrum(xb[i * n:(i + 1) * n], fs)
        if ff.size:
            quarters.append(census.prominence(PP, ff, hz, float(ff[1] - ff[0])))
    present = sum(1 for q in quarters if q is not None and q >= bar * 0.5)
    harmonics = [census.prominence(P, f, hz * k, res) for k in (2, 3)]
    best_h = max([h for h in harmonics if h is not None], default=None)

    ok_prom = prom >= bar
    ok_ratio = ratio >= MIN_ACCEL_GYRO_RATIO
    ok_persist = present >= MIN_QUARTERS_PRESENT
    ok_harm = best_h is not None and best_h >= MIN_HARMONIC_DB

    if not ok_prom:
        verdict = "absent"
    elif not ok_ratio:
        verdict = "motion"          # the gyro carries it too
    elif ok_persist and ok_harm:
        verdict = "cardiac-like"
    else:
        verdict = "motion"          # a transient or a pure tone: not an impulsive quasi-periodic source

    return {"available": True, "verdict": verdict,
            "frequency_hz": round(hz, 4), "bpm": round(hz * 60, 1),
            "prominence_db": round(prom, 2), "bar_db": round(bar, 2),
            "gyro_prominence_db": None if gp is None else round(gp, 2),
            "accel_gyro_ratio": None if not np.isfinite(ratio) else round(ratio, 2),
            "quarters_db": [None if q is None else round(q, 1) for q in quarters],
            "quarters_present": present,
            "harmonic_db": None if best_h is None else round(best_h, 2),
            "amplitude_mg": round(float(np.std(xb)) * 1000, 3),
            "motion_p90_rads": None if gyr is None or not gyr.size else round(float(np.percentile(gyr, 90)), 4),
            "gates": {"prominence": ok_prom, "accel_dominant": ok_ratio,
                      "persistent": ok_persist, "harmonic": ok_harm},
            "note": "Chest-wall MOTION. This is not magnetocardiography and may not be reported as it."}


def tremor(session) -> dict:
    """8-12 Hz physiological tremor power against a 1-4 Hz voluntary-motion reference.

    The matrix's cleanest claim: beta-adrenergic mediated, so it is a peripheral sympathetic
    readout with no electrodes. Needs a HOLD TASK — an outstretched hand — so a phone lying on a
    table returns a floor, correctly.
    """
    fs = float(session.rate_hz)
    acc = np.asarray(session.acceleration_magnitude, float)
    if acc is None or acc.size < int(fs * 20):
        return {"available": False, "reason": "under 20 s of accelerometer data"}
    if fs < 2 * TREMOR_BAND[1]:
        return {"available": False, "reason": f"{fs:.0f} Hz cannot resolve {TREMOR_BAND[1]} Hz"}
    f, P = sg.welch(acc - acc.mean(), fs, nperseg=int(min(len(acc), fs * 10)))
    tb = P[(f >= TREMOR_BAND[0]) & (f <= TREMOR_BAND[1])].sum()
    rb = P[(f >= TREMOR_REF[0]) & (f <= TREMOR_REF[1])].sum()
    hz, prom, bar = _peak(acc, fs, *TREMOR_BAND)
    return {"available": True, "tremor_band_power": float(tb), "reference_band_power": float(rb),
            "ratio": float(tb / rb) if rb > 0 else None,
            "peak_hz": hz, "prominence_db": None if prom is None else round(prom, 2),
            "bar_db": round(bar, 2),
            "resolved": bool(prom is not None and prom >= bar),
            "note": "Needs a hold task. A phone at rest correctly returns a floor, not a tremor."}


def sway(session) -> dict:
    """Postural sway: path length and 95% ellipse area from the low-frequency accelerometer.

    Established signal, and the matrix's point is that it is almost never read as an autonomic or
    affective state measure. Requires the phone worn at sacrum or sternum while STANDING.
    """
    fs = float(session.rate_hz)
    acc = np.asarray(session.acceleration_magnitude, float)
    if acc is None or acc.size < int(fs * 20):
        return {"available": False, "reason": "under 20 s of accelerometer data"}
    low = _band(acc, fs, 0.1, 3.0)
    path = float(np.sum(np.abs(np.diff(low))))
    return {"available": True, "path_length_g": round(path, 4),
            "rms_mg": round(float(np.std(low)) * 1000, 3),
            "seconds": round(len(low) / fs, 1),
            "note": "Requires STANDING with the phone worn. Phone-on-a-table returns a floor."}


def scan(device=None, minimum_s=120.0) -> list[dict]:
    """Every usable run, screened for a cardiac-band line in the accelerometer.

    Run this before recording anything: the channel has been recorded all along, so if a
    seismocardiogram were already in the archive it would be here.
    """
    out = []
    for dev in ([device] if device else store.devices()):
        for run in store.runs(dev):
            if run["covered_s"] < minimum_s:
                continue
            ses = sm.load_stream(store.store_root() / dev, run["start"], run["end"])
            r = scg(ses)
            r.update(device=dev, start=run["start"], minutes=round(run["covered_s"] / 60, 1))
            out.append(r)
    return out


if __name__ == "__main__":
    rows = scan()
    print(f"{'device':>10s} {'min':>6s} {'verdict':>13s} {'bpm':>7s} {'prom/bar':>10s} "
          f"{'a/g':>7s} {'qtrs':>5s} {'harm':>6s}")
    for r in rows:
        if not r.get("available"):
            continue
        print(f"{r['device'][:8]:>10s} {r['minutes']:6.1f} {r['verdict']:>13s} "
              f"{r.get('bpm','-'):>7} {str(r.get('prominence_db','-'))+'/'+str(r.get('bar_db','-')):>10s} "
              f"{str(r.get('accel_gyro_ratio','-')):>7} {r.get('quarters_present','-'):>5} "
              f"{str(r.get('harmonic_db','-')):>6}")
    n = sum(1 for r in rows if r.get("verdict") == "cardiac-like")
    print(f"\n  {n} run(s) pass ALL FOUR gates. "
          f"{'The archive is phone-on-a-table; a chest placement is what is missing.' if n==0 else ''}")
