"""Reading what the app exported.

The app writes four files per run (`raw.csv`, `processed.csv`, `metadata.json`,
`results.json`). This module reads the two that matter and refuses to guess at anything the
export did not state -- notably the sample rate, which is *measured* from the timestamps
rather than taken from the protocol's request.
"""
from __future__ import annotations

import csv
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

import store                          # this repo; stdlib only


@dataclass
class Session:
    """One exported acquisition."""

    #: Monotonic device time in seconds, as delivered by Core Motion. NOT uniformly spaced.
    t: np.ndarray
    #: Magnetic field in microtesla, shape (3, n) -- x, y, z.
    xyz: np.ndarray
    #: |B| in microtesla, shape (n,). The app analyses this channel.
    magnitude: np.ndarray
    #: Wall-clock time of the first sample, timezone-aware UTC.
    started_at: datetime
    #: Median-interval sample rate, measured from `t`.
    rate_hz: float
    latitude: float | None = None
    longitude: float | None = None
    metadata: dict = field(default_factory=dict)
    #: |rotation rate| in rad/s, shape (n,) — the gate for whether a motion question is answerable.
    rotation_magnitude: np.ndarray | None = None
    #: |user acceleration| in g, shape (n,).
    acceleration_magnitude: np.ndarray | None = None
    #: Attitude quaternion, shape (4, n) as x, y, z, w. The PREDICTOR for motion coupling — the
    #: field on an axis follows where the phone is POINTING, not how fast it is turning.
    attitude: np.ndarray | None = None

    @property
    def n(self) -> int:
        return int(self.magnitude.size)

    @property
    def duration_s(self) -> float:
        return float(self.t[-1] - self.t[0]) if self.n > 1 else 0.0

    @property
    def target_hz(self) -> float:
        return float(self._plan().get("targetFrequencyHz", 8.3))

    @property
    def code(self) -> list[float]:
        return list(self._plan().get("code", []))

    @property
    def chip_s(self) -> float:
        return float(self._plan().get("chipDurationSeconds", 0.25))

    def _plan(self) -> dict:
        return self.metadata.get("protocolSnapshot", {})

    def wall_times(self) -> np.ndarray:
        """Sample times as UTC epoch seconds. This is what joins against lightning and Kp."""
        return self.started_at.timestamp() + (self.t - self.t[0])

    def jitter_report(self) -> dict:
        """How non-uniform the sampling actually is.

        The app's lock-in indexes samples as `index / rate`, i.e. it assumes a uniform clock.
        Anything reported here as a large relative spread is phase noise that no amount of
        integration removes, so it is measured rather than assumed away.
        """
        if self.n < 3:
            return {"samples": self.n, "usable": False}
        dt = np.diff(self.t)
        dt = dt[dt > 0]
        median = float(np.median(dt))
        gaps = dt > 3 * median
        # The CV is computed on the NON-GAP intervals. A window spanning two streams contains the
        # monotonic clock's jump between them, and letting that one interval into the CV reported
        # 33.5 for a record whose sampling is otherwise steady to 0.0005 — a jitter statistic
        # describing a stream boundary, not the clock. The gaps are still counted, separately.
        steady = dt[~gaps]
        return {
            "samples": self.n,
            "usable": True,
            "median_interval_s": median,
            "rate_hz": 1 / median,
            "interval_cv": float(np.std(steady) / median) if median and steady.size else float("nan"),
            "p95_over_median": float(np.percentile(dt, 95) / median) if median else float("nan"),
            "dropped_gaps": int(gaps.sum()),
            "gap_seconds_total": float(dt[gaps].sum()) if gaps.any() else 0.0,
        }


def _parse_iso(text: str) -> datetime:
    text = text.strip().replace("Z", "+00:00")
    value = datetime.fromisoformat(text)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def load(directory: str | Path) -> Session:
    """Load an exported experiment folder."""
    directory = Path(directory)
    raw = directory / "raw.csv"
    if not raw.exists():
        raise FileNotFoundError(f"{raw} not found -- point this at an exported experiment folder")

    t: list[float] = []
    mx: list[float] = []
    my: list[float] = []
    mz: list[float] = []
    mag: list[float] = []
    lat: list[float] = []
    lon: list[float] = []
    rot: list[float] = []
    acc: list[float] = []
    quat: list[list[float]] = [[], [], [], []]
    first_wall: str | None = None
    with raw.open() as handle:
        for row in csv.DictReader(handle):
            rot.append((float(row.get("gx_rads") or 0) ** 2 + float(row.get("gy_rads") or 0) ** 2
                        + float(row.get("gz_rads") or 0) ** 2) ** 0.5)
            acc.append((float(row.get("ax_g") or 0) ** 2 + float(row.get("ay_g") or 0) ** 2
                        + float(row.get("az_g") or 0) ** 2) ** 0.5)
            for i, key in enumerate(("qx", "qy", "qz", "qw")):
                quat[i].append(float(row.get(key) or 0))
            t.append(float(row["monotonic_s"]))
            mx.append(float(row["mx_uT"]))
            my.append(float(row["my_uT"]))
            mz.append(float(row["mz_uT"]))
            mag.append(float(row["magnitude_uT"]))
            if row.get("latitude"):
                lat.append(float(row["latitude"]))
                lon.append(float(row["longitude"]))
            if first_wall is None:
                first_wall = row["wall_clock"]

    metadata = {}
    meta_path = directory / "metadata.json"
    if meta_path.exists():
        metadata = json.loads(meta_path.read_text())

    started = _parse_iso(metadata["startedAt"]) if "startedAt" in metadata else _parse_iso(first_wall or "")
    times = np.asarray(t, dtype=float)
    dt = np.diff(times)
    dt = dt[dt > 0]
    rate = 1 / float(np.median(dt)) if dt.size else float(
        metadata.get("achievedMagnetometerRateHz", 0) or 50.0
    )

    return Session(
        t=times,
        xyz=np.vstack([mx, my, mz]).astype(float),
        magnitude=np.asarray(mag, dtype=float),
        started_at=started,
        rate_hz=rate,
        latitude=float(np.median(lat)) if lat else None,
        longitude=float(np.median(lon)) if lon else None,
        metadata=metadata,
        rotation_magnitude=np.asarray(rot, dtype=float),
        acceleration_magnitude=np.asarray(acc, dtype=float),
        attitude=np.asarray(quat, dtype=float),
    )


def synthetic(duration_s: float = 60.0, rate_hz: float = 50.0, carrier_hz: float = 8.3,
              amplitude_ut: float = 0.025, noise_ut: float = 0.25,
              code: list[float] | None = None, chip_s: float = 0.25,
              seed: int = 42, jitter_cv: float = 0.0,
              started_at: datetime | None = None) -> Session:
    """The Swift `SyntheticDataSimulator`'s scenario, in Python.

    Two copies of one generator is a drift risk and is recorded as such: this one exists so the
    offline half can be tested without a phone, and `dev_check.py` asserts the two agree about
    the one thing that matters -- the amplitude and code that go in.
    """
    rng = np.random.default_rng(seed)
    n = int(duration_s * rate_hz)
    t = np.arange(n) / rate_hz
    if jitter_cv:
        t = np.cumsum(np.abs(rng.normal(1 / rate_hz, jitter_cv / rate_hz, n)))
    code = list(code or [1, 1, 1, -1, -1, 1, -1])
    chips = (t / chip_s).astype(int) % len(code)
    coded = np.take(code, chips) * amplitude_ut * np.sin(2 * np.pi * carrier_hz * t)
    noise = rng.normal(0, noise_ut, n)
    x = 21 + coded + noise + 0.002 * t
    y = -4 + 0.7 * noise
    z = 42 + 0.35 * coded + 0.5 * noise
    xyz = np.vstack([x, y, z])
    return Session(
        t=t, xyz=xyz, magnitude=np.sqrt((xyz ** 2).sum(axis=0)),
        started_at=started_at or datetime(2026, 8, 22, 20, 0, tzinfo=timezone.utc),
        rate_hz=rate_hz, latitude=None, longitude=None,
        metadata={"protocolSnapshot": {"targetFrequencyHz": carrier_hz, "code": code,
                                       "chipDurationSeconds": chip_s},
                  "analysisVersion": "synthetic"},
    )


# ----------------------------------------------------------------------------- the stream store

def stream_manifest(device_dir: str | Path) -> list[dict]:
    """Every chunk the Mac holds for one device, across its streams, in time order.

    `store.manifest` is the one reader of `streams/<device>/<stream>/manifest.jsonl`; this keeps the
    name callers already use. Torn or unparseable rows are skipped there, not raised.
    """
    device_dir = Path(device_dir)
    return store.manifest(device_dir.name, root=device_dir.parent)


def load_stream(device_dir: str | Path, start: datetime | float | None = None,
                end: datetime | float | None = None) -> Session:
    """A window of the always-on stream as ONE `Session`, read from the chunk files.

    Chunks are concatenated in time order. `t` is the sensor's monotonic clock, which is continuous
    across chunks of one stream; across a stream boundary (the phone was stopped and started) the
    monotonic clock may jump, and that jump is left in `t` rather than papered over — it shows up
    in `jitter_report()` as a dropped gap, which is what it is. `started_at` is the first chunk's
    wall clock. Every chunk's `emitter` stamp is collected into `metadata["emitter"]` so nothing
    downstream can mistake a self-emitter run for the world.
    """
    t0 = start.timestamp() if isinstance(start, datetime) else (float(start) if start is not None else -float("inf"))
    t1 = end.timestamp() if isinstance(end, datetime) else (float(end) if end is not None else float("inf"))
    rows = [r for r in stream_manifest(device_dir) if r["endEpoch"] >= t0 and r["startEpoch"] <= t1 and r["path"].exists()]
    if not rows:
        raise FileNotFoundError(f"no chunks in {device_dir} between {start} and {end}")

    t: list[float] = []
    mx: list[float] = []
    my: list[float] = []
    mz: list[float] = []
    mag: list[float] = []
    lat: list[float] = []
    lon: list[float] = []
    rot: list[float] = []
    acc: list[float] = []
    quat: list[list[float]] = [[], [], [], []]
    emitter: set[str] = set()
    streams: list[str] = []
    first_wall: datetime | None = None
    for row in rows:
        anchor = row["startEpoch"] - float(row.get("firstMonotonic") or 0.0)
        if row.get("emitter"):
            emitter.add(str(row["emitter"]))
        if row["stream"] not in streams:
            streams.append(row["stream"])
        with row["path"].open() as handle:
            for rec in csv.DictReader(handle):
                mono = float(rec["monotonic_s"])
                wall = anchor + mono
                if wall < t0 or wall > t1:
                    continue
                if first_wall is None:
                    first_wall = datetime.fromtimestamp(wall, tz=timezone.utc)
                t.append(mono)
                mx.append(float(rec["mx_uT"]))
                my.append(float(rec["my_uT"]))
                mz.append(float(rec["mz_uT"]))
                mag.append(float(rec["magnitude_uT"]))
                rot.append((float(rec.get("gx_rads") or 0) ** 2 + float(rec.get("gy_rads") or 0) ** 2
                            + float(rec.get("gz_rads") or 0) ** 2) ** 0.5)
                acc.append((float(rec.get("ax_g") or 0) ** 2 + float(rec.get("ay_g") or 0) ** 2
                            + float(rec.get("az_g") or 0) ** 2) ** 0.5)
                for i, key in enumerate(("qx", "qy", "qz", "qw")):
                    quat[i].append(float(rec.get(key) or 0))
                if rec.get("latitude"):
                    lat.append(float(rec["latitude"]))
                    lon.append(float(rec["longitude"]))
    if not t:
        raise FileNotFoundError(f"chunks exist but no samples fall between {start} and {end}")
    times = np.asarray(t, dtype=float)
    dt = np.diff(times)
    dt = dt[dt > 0]
    rate = 1 / float(np.median(dt)) if dt.size else float(rows[-1].get("achievedRateHz") or 0.0)
    info = {}
    info_path = rows[-1]["path"].parent.parent / "stream.json"
    if info_path.exists():
        try:
            info = json.loads(info_path.read_text())
        except json.JSONDecodeError:
            info = {}
    metadata = {
        "source": "stream",
        "device": Path(device_dir).name,
        "streams": streams,
        "chunks": len(rows),
        "emitter": sorted(emitter),
        "achievedMagnetometerRateHz": rows[-1].get("achievedRateHz"),
        "deviceModel": rows[-1].get("deviceModel"),
        "systemVersion": rows[-1].get("systemVersion"),
        "appVersion": rows[-1].get("appVersion"),
        "streamInfo": info,
        # The stream carries no experiment protocol; the target here is the page's default and a
        # caller who wants another passes it. It is stated, not inferred from anything.
        "protocolSnapshot": {"targetFrequencyHz": 8.3, "code": [1, 1, 1, -1, -1, 1, -1], "chipDurationSeconds": 0.25},
        "analysisVersion": "FieldLab-stream-1.2",
    }
    return Session(
        t=times, xyz=np.vstack([mx, my, mz]).astype(float), magnitude=np.asarray(mag, dtype=float),
        started_at=first_wall, rate_hz=rate,
        latitude=float(np.median(lat)) if lat else None, longitude=float(np.median(lon)) if lon else None,
        metadata=metadata,
        rotation_magnitude=np.asarray(rot, dtype=float),
        acceleration_magnitude=np.asarray(acc, dtype=float),
        attitude=np.asarray(quat, dtype=float),
    )
