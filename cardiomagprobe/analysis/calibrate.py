#!/usr/bin/env python3
"""A calibrated channel derived in software, and a CrowdMag-style absolute check.

Two ideas borrowed from other implementations, both buildable **without an app build**:

* **phyphox** ships raw and calibrated side by side and lets you switch. FieldLab logs only raw —
  a recorded defect. `hard_iron()` recovers the missing channel *after the fact*, from data already
  on disk, using the attitude quaternion.
* **NOAA CrowdMag** validates every contribution against a field model. This project has never
  checked whether its readings are *correct*. `earth_frame()` produces the quantity such a check
  needs.

## How the software calibration works

A device-fixed magnet (every iPhone since the 12 carries a MagSafe array) rotates **with** the
sensor, so its contribution is a **constant vector in the device frame**. The Earth's field is
constant in the **world** frame, so in the device frame it rotates. Given attitude q(t):

    b_device(t) = h + R(q(t))^T · e

with `h` the hard-iron offset (3 unknowns) and `e` the Earth field in world coordinates (3 more).
Six unknowns, three equations per sample — **solvable by least squares as soon as the phone has
turned enough**, which every run in this archive has (attitude spread 0.28–1.85).

**This is not a replacement for logging the calibrated channel.** It is a diagnostic that can be
run on the existing archive, and it cannot separate hard iron from any *other* device-fixed source.
What it removes is "everything that turns with the phone", which is the same thing iOS's calibration
removes and is why the two should still be logged side by side.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


sys.path.insert(0, str(Path(__file__).resolve().parents[2]))   # this repo: store, bands, session, census

import store                                    # noqa: E402
import session as sm                            # noqa: E402

#: Below this mean per-component attitude spread the system is too ill-conditioned to solve.
#: A phone that never turns cannot tell a device-fixed offset from the Earth.
MIN_ATTITUDE_SPREAD = 0.15

#: Derived, not chosen — see the comment in `hard_iron()`. Both are required.
MAX_CONDITION = 20.0
MAX_RESIDUAL_UT = 7.0


def _rot(q):
    """Rotation matrices from (x, y, z, w) quaternions, shape (n, 3, 3)."""
    x, y, z, w = q
    n = len(w)
    R = np.empty((n, 3, 3))
    R[:, 0, 0] = 1 - 2 * (y * y + z * z); R[:, 0, 1] = 2 * (x * y - z * w); R[:, 0, 2] = 2 * (x * z + y * w)
    R[:, 1, 0] = 2 * (x * y + z * w);     R[:, 1, 1] = 1 - 2 * (x * x + z * z); R[:, 1, 2] = 2 * (y * z - x * w)
    R[:, 2, 0] = 2 * (x * z - y * w);     R[:, 2, 1] = 2 * (y * z + x * w);     R[:, 2, 2] = 1 - 2 * (x * x + y * y)
    return R


def hard_iron(session, decimate: int = 20) -> dict:
    """Least-squares split of the field into a device-fixed offset and a world-fixed Earth vector.

    Returns the offset in µT, the recovered Earth field, the residual, and a **conditioning**
    figure. A poorly-conditioned solve is reported and refused rather than returned — a phone that
    barely moved gives an offset that is really just the mean field.
    """
    q = session.attitude
    if q is None or np.asarray(q).size == 0:
        return {"available": False, "reason": "no attitude in this record"}
    q = np.asarray(q, float)
    spread = float(np.mean([np.ptp(r) for r in q]))
    if spread < MIN_ATTITUDE_SPREAD:
        return {"available": False, "reason": f"attitude spread {spread:.3f} below "
                                              f"{MIN_ATTITUDE_SPREAD} — the phone barely turned, "
                                              "so hard iron and the Earth field are degenerate",
                "attitude_spread": round(spread, 4)}

    b = np.asarray(session.xyz, float)[:, ::decimate]
    R = _rot(q[:, ::decimate])
    n = b.shape[1]
    # per sample:  b_i = h + R_i^T e   ->  [I | R_i^T] [h; e] = b_i
    A = np.zeros((3 * n, 6))
    y = np.zeros(3 * n)
    for i in range(n):
        A[3 * i:3 * i + 3, 0:3] = np.eye(3)
        A[3 * i:3 * i + 3, 3:6] = R[i].T
        y[3 * i:3 * i + 3] = b[:, i]
    sol, *_ = np.linalg.lstsq(A, y, rcond=None)
    cond = float(np.linalg.cond(A))
    resid = float(np.sqrt(np.mean((A @ sol - y) ** 2)))
    h, e = sol[:3], sol[3:]
    return {"available": True,
            "hard_iron_uT": [round(v, 2) for v in h],
            "hard_iron_magnitude_uT": round(float(np.linalg.norm(h)), 1),
            "earth_field_uT": [round(v, 2) for v in e],
            "earth_magnitude_uT": round(float(np.linalg.norm(e)), 2),
            "residual_uT": round(resid, 3),
            "condition_number": round(cond, 1),
            "attitude_spread": round(spread, 4),
            # BOTH gates, because they catch different failures and neither alone is enough.
            # A high condition number means the phone barely turned, so hard iron and the Earth
            # field are degenerate. A high residual means the six-parameter model does not
            # describe the record at all -- something non-static is present. Different faults.
            "well_conditioned": bool(cond < MAX_CONDITION and resid < MAX_RESIDUAL_UT),
            "gates": {"conditioning": bool(cond < MAX_CONDITION),
                      "model_fit": bool(resid < MAX_RESIDUAL_UT)},
            "note": "Removes everything device-FIXED, which is what iOS calibration removes too. "
                    "It cannot separate the MagSafe array from any other co-rotating source."}


def earth_frame(session, offset_uT=None) -> dict:
    """The field rotated into the world frame, optionally after removing the hard-iron offset.

    This is the quantity a CrowdMag-style check needs: once in world coordinates and de-offset,
    the magnitude should sit near the local geomagnetic total field and its VARIATION should track
    a nearby observatory.
    """
    q = session.attitude
    if q is None or np.asarray(q).size == 0:
        return {"available": False, "reason": "no attitude in this record"}
    b = np.asarray(session.xyz, float)
    if offset_uT is not None:
        b = b - np.asarray(offset_uT, float)[:, None]
    R = _rot(np.asarray(q, float))
    world = np.einsum("nij,jn->in", R, b)
    mag = np.linalg.norm(world, axis=0)
    return {"available": True,
            "world_mean_uT": [round(float(v), 2) for v in world.mean(axis=1)],
            "total_field_uT": round(float(np.mean(mag)), 2),
            "total_field_sd_uT": round(float(np.std(mag)), 3),
            "note": "World-frame total field. Compare against IGRF/WMM at the record's lat/lon, "
                    "and its variation against the nearest INTERMAGNET/USGS observatory."}


def report(device=None, minimum_s=120.0) -> list[dict]:
    out = []
    for dev in ([device] if device else store.devices()):
        for run in store.runs(dev):
            if run["covered_s"] < minimum_s:
                continue
            ses = sm.load_stream(store.store_root() / dev, run["start"], run["end"])
            hi = hard_iron(ses)
            row = {"device": dev, "minutes": round(run["covered_s"] / 60, 1),
                   "raw_mean_uT": round(float(np.mean(ses.magnitude)), 1), **hi}
            if hi.get("available") and hi.get("well_conditioned"):
                row["earth_frame"] = earth_frame(ses, hi["hard_iron_uT"])
            out.append(row)
    return out


if __name__ == "__main__":
    print(f"{'device':>10s} {'min':>6s} {'raw |B|':>9s} {'hard iron':>10s} {'Earth |B|':>10s} "
          f"{'resid':>7s} {'cond':>8s} {'ok':>4s}")
    for r in report():
        if not r.get("available"):
            print(f"{r['device'][:8]:>10s} {r['minutes']:6.1f} {r['raw_mean_uT']:8.1f}u "
                  f"{'-':>10s} {'-':>10s} {'-':>7s} {'-':>8s}  no   ({r['reason'][:40]})")
            continue
        print(f"{r['device'][:8]:>10s} {r['minutes']:6.1f} {r['raw_mean_uT']:8.1f}u "
              f"{r['hard_iron_magnitude_uT']:9.1f}u {r['earth_magnitude_uT']:9.2f}u "
              f"{r['residual_uT']:7.2f} {r['condition_number']:8.1f} "
              f"{'yes' if r['well_conditioned'] else 'NO':>4s}")
    print("\n  Earth's total field is ~48-56 uT at mid-latitudes. A recovered value in that range")
    print("  from a raw channel reading 560-1184 uT is the check this project has never had.")
