import Foundation

/// The phone emitting the experiment's own coded signal, so the detector has something it is
/// guaranteed to be able to find.
///
/// **This is a positive control and it is never evidence of anything external.** Every session
/// recorded with it running is stamped, the stamp travels into the export, and the results screen
/// says so in the same place it would otherwise report a detection. An instrument that can confuse
/// its own emission with the world is worse than no instrument.
///
/// **How a phone emits a magnetic signal at all.** It does not have a coil for this. What it has is
/// current, and current makes a field:
///
/// * **Haptics** — the Taptic Engine is a mass on a spring driven by a coil, next to a magnet. It is
///   by a wide margin the largest controllable magnetic source in the device.
/// * **CPU load** — modulating processor duty cycle modulates the current the power-management IC
///   draws, and that current has a field. Weaker, silent, and needs no permissions.
/// * **Screen brightness** — backlight current. Weakest of the three, and visible to the operator,
///   which makes it a poor blind.
///
/// The schedule is the same coded carrier the matched filter looks for (`SignalProcessor.codedReference`),
/// so a detection is a detection of exactly the thing being searched for.
struct EmitterSchedule: Codable, Sendable, Equatable {

    enum Transducer: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, haptics, cpuLoad, screenBrightness
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Off"
            case .haptics: "Haptic engine"
            case .cpuLoad: "CPU current draw"
            case .screenBrightness: "Screen backlight"
            }
        }
        var note: String {
            switch self {
            case .none: "No emission. Any detection is of something external — which is the experiment."
            case .haptics:
                "A coil driving a mass beside a magnet, centimetres from the magnetometer. The strongest control available, and audible and palpable while it runs."
            case .cpuLoad:
                "Duty-cycled processor load modulates PMIC current, which has a field. Silent, weakest but least intrusive, and it warms the device — which drifts the sensor."
            case .screenBrightness: "Backlight current. Weak, and visible to the operator, so it cannot be used blind."
            }
        }
    }

    /// The single fact this whole file exists to protect. Stamped into metadata and rendered in the UI.
    static let stamp = "EMITTER-ON"
    static let firewall =
        "A session recorded with the emitter running measures this phone, not the world. It can validate the detector and it can never support a claim about an external signal."

    /// Where the emission comes from. A phone transducer is millimetres from the sensor with an
    /// unknown field in tesla — good for proving the detector works, useless for calibrating
    /// absolute sensitivity. An external coil driven to a KNOWN field in nanotesla at a stated
    /// distance is what turns "the detector fired" into "the detector can see N nT".
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case phoneTransducer, externalCoil
        var id: String { rawValue }
        var label: String { self == .phoneTransducer ? "Phone transducer (control only)" : "External coil (calibrated, nT)" }
    }

    var source: Source = .phoneTransducer
    var transducer: Transducer = .none
    var carrierHz: Double = 8.3
    var code: [Double] = [1, 1, 1, -1, -1, 1, -1]
    var chipSeconds: Double = 0.25
    /// 0...1. Scales whatever the transducer's own full drive means. Dimensionless — a phone
    /// transducer has no known field in tesla, which is the whole reason `externalCoil` exists.
    var amplitude: Double = 0.6

    // -- external-coil calibration (nil / 0 unless source == .externalCoil) --
    /// The coil's magnetic dipole moment in A·m², if known. With `coilDistanceMeters` this gives the
    /// on-axis near field at the sensor by first principles.
    var coilMomentAm2: Double = 0
    /// Distance from the coil to the phone's magnetometer, metres.
    var coilDistanceMeters: Double = 0
    /// The field the operator states is present at the sensor, nanotesla — used when the coil is
    /// characterised directly rather than by moment and distance.
    var statedFieldAtSensorNanotesla: Double = 0

    var isRunning: Bool { source == .externalCoil ? true : transducer != .none }
    /// True only for a phone transducer, which caps the tier — an external coil is the world (a known
    /// part of it), so a coil session is NOT emitter-capped. The `EMITTER-ON` stamp is for the phone.
    var isPhoneEmitting: Bool { source == .phoneTransducer && transducer != .none }

    /// On-axis near field at the sensor implied by the coil, in nanotesla. `B = (µ0/4π)(2m/r³)`.
    /// Falls back to the stated field when moment/distance are not given. Nil when nothing is stated.
    var impliedFieldAtSensorNanotesla: Double? {
        if source != .externalCoil { return nil }
        if coilMomentAm2 > 0, coilDistanceMeters > 0 {
            let mu0over4pi = 1e-7
            return mu0over4pi * 2 * coilMomentAm2 / pow(coilDistanceMeters, 3) * 1e9
        }
        return statedFieldAtSensorNanotesla > 0 ? statedFieldAtSensorNanotesla : nil
    }

    /// Drive level at time `t`, in −1...1, before the transducer's own unipolar mapping.
    /// Identical construction to `SignalProcessor.codedReference`, so what is emitted is exactly
    /// what is searched for.
    func drive(at t: Double) -> Double {
        guard !code.isEmpty, chipSeconds > 0 else { return 0 }
        let chip = Int(t / chipSeconds) % code.count
        return amplitude * code[chip] * sin(2 * Double.pi * carrierHz * t)
    }

    /// Transducers that cannot go negative (a haptic pulse has no polarity, a backlight no negative
    /// brightness) take a unipolar drive: the code rides as amplitude around a mid-level, which is
    /// bipolar again after the analysis detrends it.
    func unipolarDrive(at t: Double) -> Double {
        min(1, max(0, 0.5 + 0.5 * drive(at: t)))
    }

    /// Pulse times for a transducer that can only fire discrete events, one per carrier cycle at the
    /// positive peak, with the code carried as intensity.
    func pulses(duration: Double) -> [(time: Double, intensity: Double)] {
        guard carrierHz > 0, duration > 0 else { return [] }
        let period = 1 / carrierHz
        let count = Int(duration / period)
        return (0..<count).map { index in
            let time = (Double(index) + 0.25) * period  // the carrier's positive peak
            return (time, unipolarDrive(at: time))
        }
    }

    /// What the emitter would have to produce to clear a MEASURED noise floor by `margin`.
    /// Returns nil without a floor, on the same rule as everything else here.
    static func requiredAmplitudeMicrotesla(noiseFloorMicrotesla: Double?, margin: Double = 3) -> Double? {
        guard let floor = noiseFloorMicrotesla, floor > 0 else { return nil }
        return floor * margin
    }
}
