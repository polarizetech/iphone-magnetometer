"""The signal census, in Python — what is actually in this recording, broken out by source.

A port of `SignalCensus.swift`, which ran on the phone until the app was cut back to a recorder on
2026-08-23. It runs here now, over a window of the always-on stream, which is where it is far more
useful: the phone could only ever census the run in front of it, and this can census an hour, or
compare the same hour on two days.

**The rule the file exists to enforce is unchanged: every unit of measured power is accounted for.**
Every spectral bin is assigned to exactly one component, the shares sum to 1, and whatever cannot be
attributed lands in numbered `U-nn` entries and a broadband floor that is displayed as prominently
as anything else. Naming is earned: a component is `attributed` only when something in *this* record
supports it, `suspected` when it is plausible with a discriminator printed beside it, and
`unattributed` otherwise — which is a finding, not a failure.

**Two budgets, never merged.** The spectral budget partitions variance by frequency and sums to 1.
Motion coupling is cross-cutting — turning a phone in the Earth's 50 µT field writes across the
whole band — so it is returned separately and may not be stacked on the slices.

Everything numeric here is a faithful port, including the four things the Swift got wrong first and
now pins with tests: folded bands claim their bins before the resident band, a band that crosses a
Nyquist boundary is refused a location entirely, the prominence bar is computed from how many bins
were searched, and motion is regressed on **attitude** rather than rotation rate.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

import bands as band_registry          # this repo; was `from . import bands`

MAINS_HZ = 60.0
ALTERNATE_MAINS_HZ = 50.0


# ----------------------------------------------------------------------------- spectrum

def usable_length(count: int) -> int:
    """Largest power of two not exceeding `count` — the Swift FFT's own rule, kept so the two
    implementations bin the spectrum identically."""
    if count < 8:
        return 0
    n = 1
    while n * 2 <= count:
        n *= 2
    return n


def spectrum(signal: np.ndarray, rate_hz: float) -> tuple[np.ndarray, np.ndarray]:
    """Hann-windowed magnitude-squared spectrum in LINEAR power, matching `FFT.spectrum`.

    Linear, not dB: a budget has to be summable, and dB is not. The Nyquist bin is dropped, as in
    the Swift (`bins = n / 2`).
    """
    n = usable_length(len(signal))
    if n < 8:
        return np.zeros(0), np.zeros(0)
    x = np.asarray(signal[:n], dtype=float) * np.hanning(n)
    spec = np.fft.rfft(x)
    bins = n // 2
    power = (np.abs(spec[:bins]) ** 2) / (n * n)
    freqs = np.arange(bins) * rate_hz / n
    return freqs, power


def local_floor(power: np.ndarray, index: int, exclude: int, span: int) -> float:
    lo, hi = max(0, index - span), min(len(power) - 1, index + span)
    idx = np.arange(lo, hi + 1)
    idx = idx[np.abs(idx - index) > exclude]
    return float(np.median(power[idx])) if idx.size else 0.0


def prominence_threshold_db(bin_count: int, alpha: float = 0.01) -> float:
    """The prominence a peak needs to be worth naming, given how many bins were searched.

    Computed, not chosen. One bin of a Gaussian-noise spectrum is exponentially distributed, so the
    largest of `N` sits about `ln N` above the mean by chance alone, and the local floor here is a
    MEDIAN, which is `ln 2` of the mean. For a family-wise false-alarm rate `alpha` the bar is
    `ln(N/alpha) / ln 2`, reported in dB. At 1024 bins that is **12.2 dB**; a flat 4 dB once let
    pure noise produce eight "unidentified lines".
    """
    if bin_count <= 1 or not (0 < alpha < 1):
        return 12.0
    return float(10 * np.log10(np.log(bin_count / alpha) / np.log(2.0)))


def prominence(power: np.ndarray, freqs: np.ndarray, centre: float, resolution: float) -> float | None:
    if freqs.size == 0:
        return None
    index = int(np.argmin(np.abs(freqs - centre)))
    if abs(freqs[index] - centre) >= max(resolution, 0.5):
        return None
    floor = local_floor(power, index, exclude=3, span=40)
    if floor <= 0 or power[index] <= 0:
        return None
    return float(10 * np.log10(power[index] / floor))


def band_power(signal: np.ndarray, rate_hz: float, centre: float, half_width: float) -> float:
    freqs, power = spectrum(signal, rate_hz)
    if freqs.size == 0:
        return 0.0
    width = max(half_width, rate_hz / max(1, len(signal)))
    return float(power[np.abs(freqs - centre) <= width].sum())


def half_split_db(signal: np.ndarray, rate_hz: float, centre: float, half_width: float) -> float | None:
    """Power in the second half of the record versus the first, in dB. Positive means it grew.

    A component genuinely absent from one half is the most interesting case there is, so both halves
    are floored at a small fraction of the record's power rather than returning `None` — the arrival
    still reads as a large positive dB.
    """
    if len(signal) < 256:
        return None
    half = len(signal) // 2
    first = band_power(signal[:half], rate_hz, centre, half_width)
    second = band_power(signal[half:], rate_hz, centre, half_width)
    eps = 1e-12 * max(1.0, first + second)
    return float(10 * np.log10(max(second, eps) / max(first, eps)))


@dataclass
class Peak:
    frequency: float
    prominence_db: float
    bins: np.ndarray


def anonymous_peaks(power: np.ndarray, freqs: np.ndarray, claimed: np.ndarray, resolution: float,
                    limit: int = 8, threshold_db: float | None = None,
                    separation_bins: int = 6) -> list[Peak]:
    """Lines that are at no named frequency. Named by index, never by guess.

    Three guards, the first two added because a noiseless test record reported **eight** anonymous
    lines for one pure tone — a windowed sinusoid has a leakage skirt and every bin in it clears a
    threshold when the floor it is measured against is also skirt:

    1. a candidate must be a **local maximum**, so skirt bins cannot nominate themselves;
    2. a candidate within `separation_bins` of an accepted peak *is* that peak;
    3. an accepted peak **claims its skirt**, so the leakage energy is booked to the line that made
       it rather than left in the broadband floor.

    The alpha is stricter than the band test's on purpose: naming a `U-nn` asserts something is
    there and invites someone to chase it, while leaving a weak line in the floor costs nothing.
    """
    bar = threshold_db if threshold_db is not None else prominence_threshold_db(len(power), alpha=0.001)
    found: list[Peak] = []
    candidates = [i for i in range(len(power)) if not claimed[i] and freqs[i] > 0.1]
    candidates.sort(key=lambda i: power[i], reverse=True)
    for index in candidates:
        if len(found) >= limit or claimed[index]:
            continue
        lo, hi = max(0, index - 2), min(len(power) - 1, index + 2)
        if power[index] < power[lo:hi + 1].max():
            continue
        if any(abs(p.frequency - freqs[index]) < separation_bins * resolution for p in found):
            continue
        floor = local_floor(power, index, exclude=separation_bins, span=60)
        if floor <= 0 or power[index] <= 0:
            continue
        prom = float(10 * np.log10(power[index] / floor))
        if prom < bar:
            continue
        skirt = np.arange(max(0, index - separation_bins), min(len(power), index + separation_bins + 1))
        skirt = skirt[~claimed[skirt]]
        claimed[skirt] = True
        found.append(Peak(float(freqs[index]), prom, skirt))
    return sorted(found, key=lambda p: p.frequency)


# ----------------------------------------------------------------------------- motion

def variance_explained(y: np.ndarray, predictors: list[np.ndarray], ridge: float = 1e-6) -> float:
    """Adjusted R² of `y` on `predictors`, ridge-regularised, constant columns dropped.

    Dropping constants rather than failing on them matters: a phone rotating about one axis leaves
    two quaternion components dead flat, and letting a zero-variance column veto the solve returned
    R² = 0 for a record that was entirely orientation-driven.
    """
    n = min([len(y)] + [len(p) for p in predictors]) if predictors else 0
    if n <= len(predictors) + 8 or not predictors:
        return 0.0

    def standardise(v: np.ndarray) -> np.ndarray:
        v = np.asarray(v[:n], dtype=float)
        sd = v.std()
        return (v - v.mean()) / sd if sd > 0 else np.zeros(n)

    target = standardise(y)
    columns = [c for c in (standardise(p) for p in predictors) if np.any(c != 0)]
    if not columns:
        return 0.0
    k = len(columns)
    X = np.column_stack(columns)
    gram = X.T @ X / n + ridge * np.eye(k)
    rhs = X.T @ target / n
    try:
        beta = np.linalg.solve(gram, rhs)
    except np.linalg.LinAlgError:
        return 0.0
    residual = float(np.mean((target - X @ beta) ** 2))
    r2 = 1 - residual                                   # target variance is 1
    adjusted = 1 - (1 - r2) * (n - 1) / (n - k - 1)
    return float(min(1.0, max(0.0, adjusted)))


@dataclass
class MotionCoupling:
    variance_explained: float | None
    rotation_range_rad_s: float
    acceleration_range_g: float
    verdict: str


def motion_coupling(session, ac: np.ndarray) -> MotionCoupling:
    """How much of the AC variance the phone's own ORIENTATION explains.

    **The predictor is attitude, not rotation rate**, and that was measured rather than assumed:
    regressing |B| on |ω| returned R² = 1.5e-9 for a record that was entirely rotation-driven,
    because |ω| is unsigned (it peaks twice per cycle) and the field on an axis follows where the
    phone is *pointing* — the integral of signed ω — not how fast it turns.

    **It refuses to answer when the phone did not move.** With no rotation there is nothing to
    regress against and a fit through a constant returns ~0, which would read as "motion is not a
    problem here" when the truth is "this record cannot say".
    """
    rot = getattr(session, "rotation_magnitude", None)
    acc = getattr(session, "acceleration_magnitude", None)
    att = getattr(session, "attitude", None)
    if rot is None or acc is None or att is None or rot.size != ac.size:
        return MotionCoupling(None, 0.0, 0.0,
                              "Cannot answer: this record carries no IMU channels, so there is "
                              "nothing to regress the field against. Stream with attitude on.")
    rotation_range = float(rot.max() - rot.min()) if rot.size else 0.0
    acceleration_range = float(acc.max() - acc.min()) if acc.size else 0.0

    # The gate is peak rotation SPEED and the spread of attitude — not the range of the rotation
    # rate, because a phone turning at a constant speed has a rotation-rate range of exactly zero
    # while its orientation sweeps a full circle. Caught by a test that did precisely that.
    peak_rotation = float(rot.max()) if rot.size else 0.0
    attitude_spread = float(max((att[i].max() - att[i].min()) for i in range(att.shape[0]))) if att.size else 0.0
    moved = peak_rotation > 0.02 or attitude_spread > 0.01 or acceleration_range > 0.02
    if not moved:
        return MotionCoupling(
            None, rotation_range, acceleration_range,
            f"Cannot answer: the phone barely moved (peak rotation {peak_rotation:.3f} rad/s, "
            f"attitude spread {attitude_spread:.3f}). With no motion there is nothing to regress "
            "against, so this record cannot show whether motion couples — it is untested, not "
            "absent. That is the right outcome for a stationary run.")

    predictors = [att[0], att[1], att[2], att[3], acc]
    explained = variance_explained(ac, predictors)
    if explained < 0.05:
        verdict = (f"{explained * 100:.1f}% of the AC variance is predictable from attitude. "
                   "Motion is not driving this record.")
    elif explained < 0.30:
        verdict = (f"{explained * 100:.1f}% of the AC variance tracks attitude. Enough to "
                   "contaminate a weak signal; re-run stationary before reading anything else.")
    else:
        verdict = (f"{explained * 100:.1f}% of the AC variance tracks attitude. This is a recording "
                   "of the phone moving through the Earth's field, and the rest of the census is "
                   "about that.")
    return MotionCoupling(explained, rotation_range, acceleration_range, verdict)


# ----------------------------------------------------------------------------- the census

@dataclass
class Component:
    id: str
    label: str
    status: str                      # attributed | suspected | unattributed
    fraction: float
    amplitude_ut: float
    centre_hz: float | None
    bandwidth_hz: float | None
    prominence_db: float | None
    drift_db: float | None
    evidence: str
    discriminator: str
    #: The strongest bin INSIDE this component, and its prominence there.
    #:
    #: The Swift measured prominence at the band's nominal centre, which is right for asking "is
    #: this band elevated" and wrong for asking "is there a line in it". A 17 Hz tone injected into
    #: the 12–25 Hz traction band took 99.5% of the record's variance and scored 4.4 dB, because the
    #: probe sat at the band centre of 18.5 Hz and read the skirt. A deliberate divergence: the
    #: partition is unchanged, this is an extra reading, and the alert layer uses it.
    peak_hz: float | None = None
    peak_prominence_db: float | None = None


@dataclass
class CensusResult:
    sample_rate_hz: float
    resolution_hz: float
    duration_s: float
    standing_field_ut: float
    ac_rms_ut: float
    components: list[Component]
    motion: MotionCoupling
    unattributed_fraction: float
    excluded_fraction: float
    policies: dict[str, str]
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "sample_rate_hz": self.sample_rate_hz,
            "resolution_hz": self.resolution_hz,
            "duration_s": self.duration_s,
            "standing_field_ut": self.standing_field_ut,
            "ac_rms_ut": self.ac_rms_ut,
            "unattributed_fraction": self.unattributed_fraction,
            "excluded_fraction": self.excluded_fraction,
            "components": [vars(c) for c in self.components],
            "motion": vars(self.motion),
            "notes": self.notes,
        }


def census(session, target_hz: float = 8.3, target_bandwidth_hz: float = 1.0,
           policies: dict[str, str] | None = None) -> CensusResult:
    """Partition every unit of AC variance in this recording."""
    policies = dict(policies or band_registry.default_policies())
    rate = float(session.rate_hz)
    magnitude = np.asarray(session.magnitude, dtype=float)
    if magnitude.size < 64 or rate <= 0:
        return CensusResult(rate, 0, 0, float(magnitude[0]) if magnitude.size else 0.0, 0.0, [],
                            MotionCoupling(None, 0, 0, "Too few samples to census."), 1.0, 0.0,
                            policies, ["Record too short to decompose."])

    standing = float(magnitude.mean())
    # Detrend the same way the Swift does — remove mean AND linear trend.
    idx = np.arange(magnitude.size)
    ac = magnitude - np.polyval(np.polyfit(idx, magnitude, 1), idx)
    ac_rms = float(np.sqrt(np.mean(ac ** 2)))
    freqs, power = spectrum(ac, rate)
    if freqs.size == 0:
        return CensusResult(rate, 0, 0, standing, ac_rms, [],
                            motion_coupling(session, ac), 1.0, 0.0, policies,
                            ["Spectrum unavailable for this record length."])
    n = len(power) * 2
    resolution = rate / n
    gross = float(power.sum())

    claimed = np.zeros(len(power), dtype=bool)
    components: list[Component] = []
    notes: list[str] = []

    # 0. Exclusions leave the denominator FIRST, and are reported. Nothing is excluded by default.
    excluded_power = 0.0
    for b in band_registry.BANDS:
        if policies.get(b.id) != "excluded":
            continue
        apparent = band_registry.alias_of(b.centre_hz, rate)
        half = min(b.width_hz / 2, rate / 4)
        sel = (~claimed) & (np.abs(freqs - apparent) <= half)
        if not sel.any():
            continue
        excluded_power += float(power[sel].sum())
        claimed |= sel
        notes.append(f"Excluded by policy: {b.label}. Its power is out of the budget below, and the "
                     "budget therefore describes a filtered record.")
    total = max(1e-30, gross - excluded_power)

    def share(sel) -> float:
        return float(power[sel].sum() / total)

    def amplitude(fraction: float) -> float:
        return float(ac_rms * np.sqrt(max(0.0, fraction)))

    # 1. The target band claims first — it is the one band the experiment chose.
    target_sel = (~claimed) & (np.abs(freqs - target_hz) <= target_bandwidth_hz / 2)
    if target_sel.any():
        fraction = share(target_sel)
        claimed |= target_sel
        host = next((b for b in band_registry.BANDS if b.contains(target_hz)), None)
        target_prominence = prominence(power, freqs, target_hz, resolution)
        components.append(Component(
            "target", f"Target band · {target_hz:.2f} Hz", "attributed", fraction, amplitude(fraction),
            target_hz, target_bandwidth_hz,
            target_prominence,
            half_split_db(ac, rate, target_hz, target_bandwidth_hz / 2),
            "This is where the protocol asked us to look. Power being here is NOT evidence of a "
            "coded signal — a matched filter and its permutation null answer that, not this census."
            + (f" It sits inside {host.label}, which is claimed around it." if host else ""),
            "The coded matched filter. A band with power and no code correlation is something else "
            "in the same band.",
            peak_hz=target_hz,
            peak_prominence_db=target_prominence))

    # 2. Every known band. FOLDED BANDS CLAIM FIRST, then ELF priority.
    #
    #    The order matters and was got wrong once: at 50 Hz sampling 60 Hz mains lands at 10 Hz,
    #    inside the 8–13 Hz human alpha band, and with ELF priority alone the census reported grid
    #    power as ALPHA. Whatever else this instrument does, it must not do that.
    def sort_key(b):
        folded = band_registry.visibility(b, rate, target_hz).kind != "direct"
        return (0 if folded else 1, b.rank)

    bar = prominence_threshold_db(len(power))
    for b in sorted(band_registry.BANDS, key=sort_key):
        policy = policies.get(b.id, b.default_policy)
        if policy == "excluded":
            continue
        seen = band_registry.visibility(b, rate, target_hz)

        if seen.kind == "smeared":
            components.append(Component(
                b.id, b.label + " · unlocatable at this rate", "unattributed", 0.0, 0.0,
                None, b.width_hz, None, None,
                f"{b.origin} Expected: {b.expected_amplitude} {seen.note}",
                "Raise the sample rate until the band sits inside one Nyquist zone, or accept that "
                "this record cannot separate it from anything else."))
            notes.append(f"⚠️ {b.label} cannot be located at {rate:.1f} Hz sampling — it folds onto "
                         "several parts of the spectrum at once, so any component below could "
                         "contain some of it.")
            continue

        half = min(b.width_hz / 2, rate / 4)
        sel = (~claimed) & (np.abs(freqs - seen.apparent_centre_hz) <= half)
        if not sel.any():
            continue
        fraction = share(sel)
        peak = prominence(power, freqs, seen.apparent_centre_hz, resolution)
        # ...and the strongest LINE inside the band, wherever it actually sits.
        idx = np.where(sel)[0]
        best = int(idx[int(np.argmax(power[idx]))])
        peak_hz = float(freqs[best])
        peak_prom = prominence(power, freqs, peak_hz, resolution)

        if policy == "context" and max(peak or 0, peak_prom or 0) < bar and fraction < 0.01:
            continue
        full = np.abs(freqs - seen.apparent_centre_hz) <= half
        lost = 0.0 if not full.any() else 1 - sel.sum() / full.sum()
        claimed |= sel

        overlapping = []
        for other in band_registry.BANDS:
            if other.id == b.id:
                continue
            other_seen = band_registry.visibility(other, rate, target_hz)
            if other_seen.kind == "smeared":
                continue
            if abs(other_seen.apparent_centre_hz - seen.apparent_centre_hz) < half + min(other.width_hz / 2, rate / 4):
                overlapping.append(other)

        status = "suspected" if max(peak or 0, peak_prom or 0) > bar else "unattributed"
        evidence = f"{b.origin} Expected: {b.expected_amplitude} {seen.note}"
        if lost > 0.05 and overlapping:
            evidence += (f" {lost * 100:.0f}% of this band's bins were claimed by an overlapping band "
                         f"({', '.join(o.label for o in overlapping)}) — folded bands claim first, "
                         "then ELF priority. What is measured here is the remainder, not the whole band.")
        if policy == "carrier":
            evidence += " Policy CARRIER: its envelope is checked for modulation by the watched bands."

        components.append(Component(
            b.id, b.label + ("" if seen.kind == "direct" else f" · folded to {seen.apparent_centre_hz:.2f} Hz"),
            status, fraction, amplitude(fraction), seen.apparent_centre_hz, 2 * half, peak,
            half_split_db(ac, rate, seen.apparent_centre_hz, half), evidence,
            "Rotate the phone 90°: a device-fixed source turns with it, an external one does not."
            if seen.kind == "direct" else
            "CHANGE THE SAMPLE RATE and re-census. An alias moves; a real line stays put. This is "
            "the cheapest discriminator there is and it settles the question in one run.",
            peak_hz=peak_hz, peak_prominence_db=peak_prom))

        if seen.kind == "folded" and b.family == "anthropogenic":
            invaded = [o for o in band_registry.BANDS
                       if o.family not in ("anthropogenic", "instrument") and o.contains(seen.apparent_centre_hz)]
            if invaded:
                notes.append(f"⚠️ {b.label} folds to {seen.apparent_centre_hz:.2f} Hz at {rate:.1f} Hz "
                             f"sampling — INSIDE {' and '.join(o.label for o in invaded)}. Those bands "
                             "cannot be measured at this sample rate: whatever is there is at least "
                             "partly grid power wearing a different frequency.")
        if seen.kind != "direct" and seen.hz_from_target < 2 and target_hz > 0:
            notes.append(f"⚠️ {b.label} folds to {seen.apparent_centre_hz:.2f} Hz — "
                         f"{seen.hz_from_target:.2f} Hz from the {target_hz:.2f} Hz target. Re-run at "
                         "a different sample rate before believing anything in the target band.")

    # 3. Anonymous lines. Named by index, never by guess.
    anon = anonymous_peaks(power, freqs, claimed, resolution, limit=8)
    for i, peak in enumerate(anon):
        identifier = f"U-{i + 1:02d}"
        sel = np.zeros(len(power), dtype=bool)
        sel[peak.bins] = True
        fraction = share(sel)
        relation = ""
        for earlier in anon[:i]:
            for harmonic in (2, 3, 4):
                if abs(peak.frequency - harmonic * earlier.frequency) < 2 * resolution:
                    relation = (f" Sits at {harmonic}× the frequency of an earlier anonymous line, "
                                "so the two are probably one source.")
        components.append(Component(
            identifier, f"{identifier} · unidentified line at {peak.frequency:.3f} Hz", "unattributed",
            fraction, amplitude(fraction), peak.frequency, 2 * resolution, peak.prominence_db,
            half_split_db(ac, rate, peak.frequency, 2 * resolution),
            f"{peak.prominence_db:.1f} dB above the local spectral floor, and inside no band this "
            "instrument knows about." + relation,
            "Three cheap tests, in order: change the sample rate (an alias moves), rotate the phone "
            "90° (a device-fixed source rotates with it), and walk 10 m from any wiring or motor.",
            peak_hz=peak.frequency, peak_prominence_db=peak.prominence_db))

    # 4. Everything left is the broadband floor. Unattributed too, and it says so.
    floor_sel = ~claimed
    floor_fraction = share(floor_sel)
    components.append(Component(
        "floor", "Broadband floor", "unattributed", floor_fraction, amplitude(floor_fraction),
        None, rate / 2, None, None,
        "All remaining power, spread across the band with no line structure. Sensor noise, "
        "quantisation and whatever else has no peak. This is a floor, not an identification.",
        "Measure it properly with a clean baseline run — see INTERFERENCE.md. Until one exists, no "
        "detection threshold on this rig is a number."))

    motion = motion_coupling(session, ac)
    unattributed = sum(c.fraction for c in components if c.status == "unattributed")
    notes.append("The shares partition the AC variance and sum to 1. Motion coupling is reported "
                 "separately because it writes across the whole band — adding it to a slice would "
                 "count the same power twice.")
    notes.append("Nothing is filtered out unless a band is set to EXCLUDE. Mains, drift and the "
                 "sensor floor are all still in the budget, because a signal nested on a loud "
                 "carrier is only findable while the carrier is still there.")

    return CensusResult(
        rate, resolution, float(magnitude.size / rate), standing, ac_rms,
        sorted(components, key=lambda c: c.fraction, reverse=True), motion,
        unattributed, excluded_power / max(1e-30, gross), policies, notes)
