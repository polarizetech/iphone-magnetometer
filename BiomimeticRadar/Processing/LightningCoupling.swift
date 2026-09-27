import Foundation

/// What a lightning stroke could actually put on THIS sensor, computed rather than assumed.
///
/// The project's lightning mode exists because a stroke excites the Earth-ionosphere cavity and
/// rings it at the Schumann frequencies — which is close to this app's default target. That is the
/// interesting claim, and it is also the one most likely to be believed without a number. So the
/// arithmetic lives here, in code, and every verdict names the term that dominates it.
///
/// Three separate physical arrivals, never summed into one "lightning signal":
///
/// 1. **Return-stroke induction field** — the local magnetic field of the current channel,
///    `B = μ₀·I / (2π·r)`. Large near the strike, falls as 1/r, and lasts ~100 µs.
/// 2. **Continuing current** — a ~100 A tail lasting milliseconds to ~0.5 s after some strokes.
///    Smaller, but *slow enough that a 50 Hz sampler can see it*.
/// 3. **Cavity ringing (the Q-burst / Schumann transient)** — global, arrives from any distance,
///    and is of order **1 pT**. That is the number `research/`'s SCH-0001 was retracted around.
///
/// The load-bearing point is that these have completely different sizes AND completely different
/// timescales, and this hardware is a low-pass filter with a hard ceiling at ~100 Hz. A field can
/// be enormous and still be invisible here.
struct LightningCoupling: Sendable {

    static let mu0 = 4 * Double.pi * 1e-7  // T·m/A
    /// Typical negative first return stroke. Klaus Berger's classic distribution: median ~30 kA.
    static let typicalPeakCurrentA = 30_000.0
    /// Return-stroke current rise/fall, order of magnitude.
    static let returnStrokeDurationS = 100e-6
    /// Continuing current after some strokes: ~100 A for milliseconds to ~0.5 s.
    static let continuingCurrentA = 100.0
    static let continuingCurrentDurationS = 0.1
    /// Schumann-band transient amplitude at the ground, order of magnitude.
    /// Tier C, and it is the SAME number SCH-0001 turns on — see that claim before quoting it.
    static let cavityRingingTesla = 1e-12

    enum Reach: String, Codable, Sendable {
        /// The arrival exceeds the measured noise floor of this rig by a stated margin.
        case withinReach
        /// Same order as the noise floor: a run might see it, coherently, with enough dwell.
        case marginal
        /// Below the floor, or below the sampler's time resolution. No dwell fixes it.
        case outOfReach
        /// No measured noise floor was supplied. This is not "probably fine".
        case undetermined
    }

    struct Arrival: Codable, Sendable, Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// Peak field at the sensor, in microtesla, before any bandwidth loss.
        let peakMicrotesla: Double
        /// Duration of the arrival in seconds.
        let durationSeconds: Double
        /// Fraction of the arrival that survives a sampler running at this rate. See `survival`.
        let survivingFraction: Double
        /// `peakMicrotesla · survivingFraction` — what could actually reach a sample.
        let deliveredMicrotesla: Double
        let reach: Reach
        /// Ratio of delivered field to the measured noise floor. `nil` when no floor was supplied.
        let marginVersusNoise: Double?
        /// Always populated. The term that decided the verdict.
        let reason: String
    }

    /// Induction field of a straight current channel at distance `r`. Ampère's law; valid while
    /// `r` is small compared with the wavelength, which at ELF it always is (λ at 10 Hz ≈ 30,000 km).
    static func returnStrokeMicrotesla(peakCurrentA: Double, distanceMeters: Double) -> Double {
        guard distanceMeters > 0 else { return .infinity }
        let tesla: Double = mu0 * peakCurrentA / (2 * Double.pi * distanceMeters)
        return tesla * 1e6
    }

    /// What fraction of an arrival of duration `τ` survives a sampler of period `T`.
    ///
    /// This is the whole reason a 6 µT field can be invisible. Treated as an *integrating* sampler,
    /// the most generous assumption available: an event shorter than one sample period is smeared
    /// across that period and its peak is scaled by `τ/T`. A non-integrating sampler would simply
    /// miss it with probability `1 − τ/T`, which is worse. Nothing above 1 is ever returned.
    static func survival(durationSeconds: Double, sampleRateHz: Double) -> Double {
        guard sampleRateHz > 0, durationSeconds > 0 else { return 0 }
        let period: Double = 1 / sampleRateHz
        return min(1, durationSeconds / period)
    }

    /// The three arrivals for one strike geometry.
    ///
    /// `noiseFloorMicrotesla` is the **measured** in-band noise of this rig — `BaselineReport.rmsNoise`
    /// from a real baseline run. It is deliberately optional and deliberately has no default: a
    /// verdict computed against an assumed noise floor is the exact failure mode this repo's
    /// `noise_budget` work was written to prevent, so with no floor every arrival returns
    /// `.undetermined` rather than something reassuring.
    static func arrivals(
        distanceMeters: Double,
        sampleRateHz: Double,
        peakCurrentA: Double = typicalPeakCurrentA,
        noiseFloorMicrotesla: Double? = nil
    ) -> [Arrival] {
        func build(
            _ name: String, _ peakMicrotesla: Double, _ duration: Double,
            _ note: String
        ) -> Arrival {
            let surviving = survival(durationSeconds: duration, sampleRateHz: sampleRateHz)
            let delivered = peakMicrotesla * surviving
            var margin: Double?
            var reach: Reach = .undetermined
            var reason = note
            if let floor = noiseFloorMicrotesla, floor > 0 {
                let ratio = delivered / floor
                margin = ratio
                if surviving < 0.01 {
                    reach = .outOfReach
                    reason =
                        "\(note) Unresolvable: the arrival is \(fmt(duration * 1e3)) ms against a \(fmt(1000 / sampleRateHz)) ms sample period, so \(fmt(surviving * 100))% of it survives the sampler. Integration does not recover it — the bandwidth is gone before the ADC."
                } else if ratio >= 3 {
                    reach = .withinReach
                    reason = "\(note) Delivered \(fmt(delivered)) µT against a measured \(fmt(floor)) µT floor: \(fmt(ratio))×."
                } else if ratio >= 0.1 {
                    reach = .marginal
                    reason =
                        "\(note) Delivered \(fmt(delivered)) µT against a measured \(fmt(floor)) µT floor: \(fmt(ratio))×. Same order as the noise — a single sample will not show it; coherent dwell might."
                } else {
                    reach = .outOfReach
                    reason =
                        "\(note) Delivered \(fmt(delivered)) µT is \(fmt(1 / max(ratio, 1e-18)))× BELOW the measured \(fmt(floor)) µT floor."
                }
            } else {
                reason =
                    "\(note) No measured noise floor supplied, so no verdict is offered — run a baseline first. This is not an estimate that it is fine."
            }
            return Arrival(
                name: name, peakMicrotesla: peakMicrotesla, durationSeconds: duration,
                survivingFraction: surviving, deliveredMicrotesla: delivered,
                reach: reach, marginVersusNoise: margin, reason: reason)
        }

        let stroke = returnStrokeMicrotesla(peakCurrentA: peakCurrentA, distanceMeters: distanceMeters)
        let continuing = returnStrokeMicrotesla(peakCurrentA: continuingCurrentA, distanceMeters: distanceMeters)
        return [
            build(
                "Return-stroke induction field", stroke, returnStrokeDurationS,
                "μ₀·I/(2π·r) for \(fmt(peakCurrentA / 1000)) kA at \(fmt(distanceMeters / 1000)) km."),
            build(
                "Continuing current", continuing, continuingCurrentDurationS,
                "\(fmt(continuingCurrentA)) A tail at the same distance."),
            build(
                "Cavity ringing (Schumann transient)", cavityRingingTesla * 1e6, 0.5,
                "Global, distance-independent, order 1 pT. This is the arrival the 8.3 Hz target would be listening for."),
        ]
    }

    /// The distance at which a return stroke's *delivered* field equals the measured noise floor.
    /// Returns `nil` without a floor — same rule as `arrivals`.
    static func equalNoiseDistanceMeters(
        sampleRateHz: Double,
        peakCurrentA: Double = typicalPeakCurrentA,
        noiseFloorMicrotesla: Double?
    ) -> Double? {
        guard let floor = noiseFloorMicrotesla, floor > 0, sampleRateHz > 0 else { return nil }
        let surviving = survival(durationSeconds: returnStrokeDurationS, sampleRateHz: sampleRateHz)
        guard surviving > 0 else { return nil }
        let teslaFloor: Double = floor * 1e-6 / surviving
        return mu0 * peakCurrentA / (2 * Double.pi * teslaFloor)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: abs(value) >= 0.01 && abs(value) < 1e5 ? "%.3g" : "%.2e", value)
    }
}
