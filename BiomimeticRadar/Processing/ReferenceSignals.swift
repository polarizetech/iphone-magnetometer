import Foundation

/// **Is there anything out there to look for at all?**
///
/// A detector with nothing to detect cannot be validated, and this project spent its first version
/// looking for a transmitter that does not exist. This catalogue is the honest answer: everything
/// known to be radiating in or near this instrument's band, what it is worth, and whether this rig
/// could see it. Three of the five are out of reach and say so — which is the point. An instrument
/// that cannot name a signal it could actually detect is not ready to be run.
struct ReferenceSignals: Sendable {

    enum Availability: String, Codable, Sendable {
        /// Present continuously, everywhere the physics reaches.
        case continuous
        /// Present, but only under stated conditions.
        case conditional
        /// We control it.
        case selfEmitted
    }

    enum Reach: String, Codable, Sendable {
        case withinReach, marginal, outOfReach, undetermined
    }

    struct Source: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let label: String
        /// Nominal frequency in Hz. For a band, its centre.
        let frequencyHz: Double
        /// Expected magnetic amplitude at the ground, in microtesla.
        let amplitudeMicrotesla: Double
        let availability: Availability
        let origin: String
        /// What locking onto it would establish.
        let worthFor: String
        /// The thing that would stop it working, stated up front.
        let caveat: String
        let tier: String
    }

    /// Ordered by how useful they are to this rig, most useful first.
    static let sources: [Source] = [
        Source(
            id: "mains", label: "Mains hum · 50 or 60 Hz",
            frequencyHz: 60, amplitudeMicrotesla: 0.1, availability: .continuous,
            origin: "The building's wiring. The strongest artificial magnetic signal in almost any indoor environment.",
            worthFor:
                "THE practical end-to-end reference. It is a known frequency, at a known amplitude, always on — so locking onto it proves the sensor, the sample clock, the lock-in and the matched filter all work, on a signal whose existence is not in question. Nothing else available to this rig does that.",
            caveat:
                "It must be sampled above 120 Hz to be seen directly, and this hardware tops out at 100 Hz — so it is always ALIASED. That is usable (the fold is deterministic) but it means the frequency you lock onto is not the frequency that is there, and the app has to say so every time.",
            tier: "[A] measured by everyone, everywhere, for a century"),
        Source(
            id: "self-emitter", label: "The phone's own emitter",
            frequencyHz: 8.3, amplitudeMicrotesla: 0.5, availability: .selfEmitted,
            origin: "This app modulating a controllable load — the haptic engine, or CPU current draw — with the experiment's own code.",
            worthFor:
                "The positive control this project did not have. It closes the loop end to end with a signal whose code, timing and amplitude are all known, so a failure to detect it is a fault in the instrument rather than an absence in the world.",
            caveat:
                "It is NOT an external signal and can never be evidence of one. A session recorded with it running is stamped EMITTER-ON and its results carry that stamp everywhere they go.",
            tier: "[A] we generate it"),
        Source(
            id: "pc1", label: "Pc1 geomagnetic pulsations · 0.2–5 Hz",
            frequencyHz: 1.0, amplitudeMicrotesla: 0.0005, availability: .conditional,
            origin: "EMIC waves in the magnetosphere reaching the ground. Occurrence rises during and after geomagnetic storms.",
            worthFor:
                "The closest NATURAL in-band signal that is not hopeless — roughly 0.1–1 nT, which is two to three orders under a phone floor rather than five. It is also the one reference whose occurrence the app can already predict, because it tracks Kp and the app fetches Kp.",
            caveat:
                "Two to three orders below this sensor is still out of reach for a single run, and the band overlaps respiration, cardiac and sensor drift — all of which are larger. A coil, not a phone, is the instrument for this.",
            tier: "[B] routinely measured by ground magnetometer networks"),
        Source(
            id: "schumann", label: "Schumann resonances · 7.83, 14.3, 20.8 Hz",
            frequencyHz: 7.83, amplitudeMicrotesla: 1e-6, availability: .continuous,
            origin: "The Earth-ionosphere cavity, rung continuously by global lightning.",
            worthFor:
                "It is the signal this project's target frequency is adjacent to, and the one everything else here is ultimately about. Being explicit that it is out of reach is what keeps the 8.3 Hz target honest.",
            caveat:
                "~1 pT: five orders of magnitude below a phone magnetometer's floor. No amount of integration crosses five orders on a sensor whose own quantisation is larger. See research/ SCH-0001.",
            tier: "[A] measured continuously at observatories worldwide"),
        Source(
            id: "vlf-transmitters", label: "VLF transmitters · NAA, NLK, NWC, DHO38",
            frequencyHz: 24_000, amplitudeMicrotesla: 0.0001, availability: .continuous,
            origin:
                "Military submarine-communication transmitters: NAA Cutler 24.0 kHz, NLK Jim Creek 24.8 kHz, NWC Australia 19.8 kHz, DHO38 Germany 23.4 kHz. Megawatt-class, on almost continuously.",
            worthFor:
                "They are the textbook known reference in the sub-audio EM world and are the first thing anyone suggests. Listed so the answer is on the record rather than rediscovered.",
            caveat:
                "STRUCTURALLY unreachable. 20–25 kHz is 200× above this sensor's maximum sample rate, and a magnetometer's own analogue bandwidth stops far below it — the energy is gone before the ADC, so it does not even alias into the band. A VLF loop antenna and a sound card is the right instrument, and it is a different project.",
            tier: "[A] published frequencies, continuously monitored by hobbyists"),
    ]

    /// Whether this rig could see a source, given a MEASURED noise floor.
    ///
    /// `noiseFloorMicrotesla` has no default, and without it every verdict is `.undetermined` —
    /// the same rule `LightningCoupling` and `eeg-bridge`'s `noise_budget` follow.
    struct Assessment: Codable, Sendable, Identifiable, Equatable {
        var id: String { sourceID }
        let sourceID: String
        let reach: Reach
        /// Where it lands in the sampled spectrum. Differs from the true frequency when folded.
        let apparentHz: Double
        let folded: Bool
        let marginVersusNoise: Double?
        let reason: String
    }

    static func assess(
        _ source: Source, sampleRateHz rate: Double,
        noiseFloorMicrotesla: Double?
    ) -> Assessment {
        let apparent = SignalCensus.aliasOf(source.frequencyHz, sampleRateHz: rate)
        let folded = SignalCensus.isAliased(source.frequencyHz, sampleRateHz: rate)

        // A magnetometer's own analogue bandwidth stops far below VLF: that energy never reaches the
        // ADC, so it does not alias in. Treating it as "folded to 4 kHz" would be a lie of arithmetic.
        if source.frequencyHz > 1_000 {
            return Assessment(
                sourceID: source.id, reach: .outOfReach, apparentHz: .nan, folded: false,
                marginVersusNoise: nil,
                reason:
                    "Above the sensor's own analogue bandwidth, not merely above Nyquist. The energy is removed before the ADC, so it does not alias into the band at all — there is nothing here to fold."
            )
        }
        guard let floor = noiseFloorMicrotesla, floor > 0 else {
            return Assessment(
                sourceID: source.id, reach: .undetermined, apparentHz: apparent,
                folded: folded, marginVersusNoise: nil,
                reason:
                    "No measured noise floor for this rig yet. Run a baseline and analyse it; until then this is undetermined, which is not the same as promising."
            )
        }
        let ratio = source.amplitudeMicrotesla / floor
        let where_ =
            folded
            ? String(
                format: " It would appear at %.2f Hz, not %.2f Hz, because it folds at this sample rate.", apparent, source.frequencyHz)
            : ""
        switch ratio {
        case 3...:
            return Assessment(
                sourceID: source.id, reach: .withinReach, apparentHz: apparent, folded: folded,
                marginVersusNoise: ratio,
                reason: String(format: "%.3g µT against a measured %.3g µT floor: %.3gx.", source.amplitudeMicrotesla, floor, ratio)
                    + where_)
        case 0.1..<3:
            return Assessment(
                sourceID: source.id, reach: .marginal, apparentHz: apparent, folded: folded,
                marginVersusNoise: ratio,
                reason: String(
                    format: "%.3g µT against a measured %.3g µT floor: %.3gx. Coherent dwell decides it.", source.amplitudeMicrotesla,
                    floor, ratio) + where_)
        default:
            return Assessment(
                sourceID: source.id, reach: .outOfReach, apparentHz: apparent, folded: folded,
                marginVersusNoise: ratio,
                reason: String(
                    format: "%.3g µT is %.3gx BELOW the measured %.3g µT floor.", source.amplitudeMicrotesla, 1 / max(ratio, 1e-18), floor)
                    + where_)
        }
    }

    /// The reference to try first, and why. Returns `nil` only if nothing is assessable.
    static func recommended(
        sampleRateHz rate: Double,
        noiseFloorMicrotesla: Double?
    ) -> (source: Source, assessment: Assessment)? {
        let assessed = sources.map { ($0, assess($0, sampleRateHz: rate, noiseFloorMicrotesla: noiseFloorMicrotesla)) }
        if let hit = assessed.first(where: { $0.1.reach == .withinReach }) { return hit }
        if let hit = assessed.first(where: { $0.1.reach == .marginal }) { return hit }
        // With no floor measured, the honest recommendation is the one we control.
        return assessed.first { $0.0.id == "self-emitter" }
    }
}
