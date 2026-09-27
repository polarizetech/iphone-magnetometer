"""The band registry — parsed out of `BandRegistry.swift`, never copied.

There is exactly one catalogue of named bands in this project and it is the Swift file. This module
reads it. That is deliberate and it is stronger than a parity test: a parity test tells you the two
copies have drifted *after* someone edits one, whereas there is no second copy here to drift.
`serve.py` imports this module too, so the phone, the server and the offline analysis are all
looking at the same table.

Stdlib only — no numpy — precisely so `serve.py` (which is stdlib by design) can use it.

The other half of the file is `visibility()`, the port of `BandRegistry.visibility(of:)`: where a
band actually lands after sampling. It is the function that catches the thing this instrument gets
wrong most easily — **a band above Nyquist has not gone away, it is wearing a different frequency**
— and the `smeared` case, where a band crosses a Nyquist boundary and therefore lands on several
stretches of spectrum at once, so it is refused a location rather than given a wrong one.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

def _find_swift() -> Path:
    """BandRegistry.swift, the single source of truth for the band catalogue.

    It is authored in this repo, beside this file. There is deliberately **no fallback copy**:
    a second copy of a catalogue is a catalogue that drifts.
    """
    return Path(__file__).resolve().parent / "BiomimeticRadar" / "Processing" / "BandRegistry.swift"


SWIFT = _find_swift()

_BAND_RE = re.compile(
    r'Band\(id:\s*"(?P<id>[^"]+)",\s*label:\s*"(?P<label>[^"]+)",\s*'
    r'lowHz:\s*(?P<low>[0-9.eE+-]+),\s*highHz:\s*(?P<high>[0-9.eE+-]+),\s*'
    r'family:\s*\.(?P<family>\w+),\s*'
    r'origin:\s*"(?P<origin>(?:[^"\\]|\\.)*)",\s*'
    r'expectedAmplitude:\s*"(?P<expected>(?:[^"\\]|\\.)*)",\s*'
    r'defaultPolicy:\s*\.(?P<policy>\w+),\s*rank:\s*(?P<rank>\d+)\)',
    re.S)

POLICIES = ("watch", "carrier", "context", "excluded")


@dataclass(frozen=True)
class Band:
    id: str
    label: str
    low_hz: float
    high_hz: float
    family: str
    origin: str
    expected_amplitude: str
    default_policy: str
    rank: int

    @property
    def centre_hz(self) -> float:
        return (self.low_hz + self.high_hz) / 2

    @property
    def width_hz(self) -> float:
        return self.high_hz - self.low_hz

    def contains(self, hz: float) -> bool:
        return self.low_hz <= hz <= self.high_hz


def _load(path: Path = SWIFT) -> list[Band]:
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. The band catalogue lives in the Swift source and this module reads "
            "it — there is no second copy to fall back on, on purpose.")
    text = path.read_text()
    bands = [
        Band(id=m.group("id"), label=m.group("label"),
             low_hz=float(m.group("low")), high_hz=float(m.group("high")),
             family=m.group("family"), origin=m.group("origin"),
             expected_amplitude=m.group("expected"), default_policy=m.group("policy"),
             rank=int(m.group("rank")))
        for m in _BAND_RE.finditer(text)
    ]
    if not bands:
        raise ValueError(f"{path} parsed to zero bands — the Swift `Band(...)` shape changed and "
                         "this parser did not. Fix the parser rather than reintroducing a copy.")
    # The Swift declares nothing as excluded by default and the census depends on that.
    bad = [b.id for b in bands if b.default_policy not in POLICIES]
    if bad:
        raise ValueError(f"unknown default policy on {bad}")
    return bands


BANDS: list[Band] = _load()
BY_ID: dict[str, Band] = {b.id: b for b in BANDS}


def band(band_id: str) -> Band | None:
    return BY_ID.get(band_id)


def elf() -> list[Band]:
    """The ELF/ULF subset — rank < 20 — which is what this project is pointed at."""
    return [b for b in BANDS if b.rank < 20]


def default_policies() -> dict[str, str]:
    """Nothing is excluded; the operator has to choose that."""
    return {b.id: b.default_policy for b in BANDS}


# This module must import with the standard library alone: `serve.py` loads it without numpy, and a
# failed import silently empties /api/bands.
def alias_of(hz: float, rate_hz: float) -> float:
    """Where a real frequency lands after sampling. A tone above Nyquist folds; it does not vanish."""
    if rate_hz <= 0:
        return hz
    folded = hz % rate_hz
    return rate_hz - folded if folded > rate_hz / 2 else folded


@dataclass(frozen=True)
class Visibility:
    band_id: str
    kind: str                 # direct | folded | straddling | smeared
    apparent_centre_hz: float
    hz_from_target: float
    note: str

    @property
    def locatable(self) -> bool:
        return self.kind != "smeared"


def visibility(b: Band, rate_hz: float, target_hz: float = 0.0) -> Visibility:
    """Where `b` lands at this sample rate, and how close that is to the target.

    A faithful port of `BandRegistry.visibility(of:sampleRateHz:targetHz:)`, including the
    `smeared` refusal: a band wider than the sampled spectrum, or one crossing a Nyquist boundary,
    folds onto several stretches at once and is given **no location and no bins**. Allowing it a
    centre once let the mains-harmonic band (99–181 Hz) claim 0–22.5 Hz and swallow everything.
    """
    nyquist = rate_hz / 2
    apparent = alias_of(b.centre_hz, rate_hz)
    distance = abs(apparent - target_hz)

    low_zone = int(b.low_hz / nyquist) if nyquist else 0
    high_zone = int(b.high_hz / nyquist) if nyquist else 0
    if b.width_hz >= nyquist or low_zone != high_zone:
        return Visibility(
            b.id, "smeared", apparent, distance,
            f"Cannot be located at this sample rate. The band spans {b.low_hz:.1f}–{b.high_hz:.1f} Hz, "
            f"which crosses a Nyquist boundary ({nyquist:.1f} Hz), so it folds onto several stretches "
            "of the sampled spectrum at once. It is not assigned any bins — and that means any part "
            "of this record could carry it.")

    if b.high_hz <= nyquist:
        kind, note = "direct", "Below Nyquist — this band appears where it actually is."
    elif b.low_hz >= nyquist:
        kind = "folded"
        note = (f"Folds to {apparent:.2f} Hz at this sample rate. It has not gone away; it is "
                "wearing a different frequency.")
    else:
        kind = "straddling"
        note = (f"Straddles Nyquist ({nyquist:.1f} Hz). Part of the band appears directly and part "
                "folds back on top of it — the two are unseparable in this record.")
    if kind != "direct" and distance < 2 and target_hz > 0:
        note += f" ⚠️ It lands {distance:.2f} Hz from the {target_hz:.2f} Hz target."
    return Visibility(b.id, kind, apparent, distance, note)


def recommended_rate(target_hz: float,
                     candidates: tuple[float, ...] = (25, 30, 40, 50, 64, 75, 100)) -> tuple[float, str]:
    """The rate that keeps every anthropogenic band furthest from the target. Advice, never applied."""
    best, best_score = candidates[0], -float("inf")
    for rate in candidates:
        if rate <= target_hz * 2.5:
            continue
        worst = min((abs(alias_of(b.centre_hz, rate) - target_hz)
                     for b in BANDS if b.family == "anthropogenic"), default=float("inf"))
        if worst > best_score:
            best_score, best = worst, rate
    return best, (f"At {best:.0f} Hz the nearest anthropogenic band lands {best_score:.1f} Hz from "
                  f"the {target_hz:.2f} Hz target. Higher rates also widen the bandwidth available "
                  "to short transients.")
