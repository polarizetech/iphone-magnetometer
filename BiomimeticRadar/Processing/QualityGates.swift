import CryptoKit
import Foundation

/// Preflight and post-record quality gates.
///
/// The first two real exports were the reason this file exists. Both said `motion="stationary"`
/// while the gyro peaked near 9 rad/s and the phone flipped orientation mid-record; both showed a
/// baseline |B| near 700–950 µT — an order of magnitude over the Earth's ~50 µT, i.e. a magnet
/// (MagSafe, a case, a stand) sitting on the sensor; and one had a 40× disagreement between its
/// monotonic clock span and its wall clock. None of that stopped the run being marked
/// `preregistered`. Each gate below turns one of those into a **reason string and a pass/fail**,
/// and a failing gate **refuses to promote a session past `exploratory`**.
///
/// The rule this repo keeps: nothing is deleted or silenced. A gate flags; the operator decides.
/// The one thing a gate is allowed to do on its own is withhold a *tier* — never data.
///
/// **This file is the half the RECORDER needs** — the gates that read a window of samples and
/// nothing else, so the streaming app can run a live preflight without compiling the analysis. The
/// session-level report (`postRecord`, which needs an `ExperimentProtocol`) lives in
/// `QualityGatesSession.swift` and is Mac-side only.
enum QualityGate: String, Codable, Sendable, CaseIterable {
    case dcField  // baseline |B| within a few × Earth's field
    case motion  // gyro/accel quiet, no orientation change
    case clockConsistency  // monotonic span ≈ wall span ≈ preregistered duration
    case sampleCount  // achieved samples ≈ expected
    case positiveControl  // a passing emitter-on control exists for a null to mean anything

    var title: String {
        switch self {
        case .dcField: "Ambient DC field"
        case .motion: "Motion"
        case .clockConsistency: "Clock consistency"
        case .sampleCount: "Sample count"
        case .positiveControl: "Positive control"
        }
    }
}

struct GateResult: Codable, Sendable, Equatable, Identifiable {
    var gate: QualityGate
    var passed: Bool
    var reason: String
    /// A gate that is not applicable yet (e.g. the positive-control gate before any control exists)
    /// is `informational` — it neither passes nor blocks, and says why.
    var informational: Bool = false
    var id: String { gate.rawValue }
}

struct GateReport: Codable, Sendable, Equatable {
    var results: [GateResult] = []
    /// Diagnostics that are numbers, not verdicts — surfaced in results.json for the offline half.
    var baselineFieldMicrotesla: Double = 0
    var gyroPeakRadPerSec: Double = 0
    var accelPeakG: Double = 0
    var orientationChanges: Int = 0
    var derivedMotion: String = "unknown"
    var fieldVsRotationCorrelation: Double = 0
    var monotonicSpanS: Double = 0
    var wallSpanS: Double = 0
    var preregisteredDurationS: Double = 0
    var achievedSamples: Int = 0
    var expectedSamples: Int = 0

    /// A gate failure (not merely informational) caps the tier at `exploratory`.
    var blocks: Bool { results.contains { !$0.passed && !$0.informational } }
    var failing: [GateResult] { results.filter { !$0.passed && !$0.informational } }

    static let earthFieldLowMicrotesla = 25.0
    static let earthFieldHighMicrotesla = 75.0
    static let gyroLimitRadPerSec = 0.35
    static let accelLimitG = 0.15
    static let clockToleranceFraction = 0.1
    static let minimumSampleFraction = 0.95
}

enum QualityGates {

    /// The gates that can be run BEFORE recording, off a short settling window of live samples.
    /// The DC-field and motion gates are the ones worth blocking a start on — a magnet on the
    /// sensor or a phone in the hand will not get better by recording 60 s of it.
    static func preflight(samples: [SensorSample]) -> GateReport {
        var report = GateReport()
        guard !samples.isEmpty else {
            report.results = [GateResult(gate: .dcField, passed: false, reason: "No samples yet.")]
            return report
        }
        let field = median(samples.map(\.magnetic.magnitude))
        report.baselineFieldMicrotesla = field
        report.results.append(dcFieldResult(field))

        let motion = motionMetrics(samples)
        report.gyroPeakRadPerSec = motion.gyroPeak
        report.accelPeakG = motion.accelPeak
        report.orientationChanges = motion.orientationChanges
        report.derivedMotion = motion.label
        report.results.append(motionResult(motion))
        return report
    }

    // MARK: - individual gates

    static func dcFieldResult(_ field: Double) -> GateResult {
        let ok = field >= GateReport.earthFieldLowMicrotesla && field <= GateReport.earthFieldHighMicrotesla
        return GateResult(
            gate: .dcField, passed: ok,
            reason: ok
                ? String(format: "Baseline |B| = %.0f µT, within a normal range for the Earth's field.", field)
                : String(
                    format:
                        "Baseline |B| = %.0f µT vs the Earth's ~50 µT. A magnetic accessory (MagSafe, magnetic case or stand) is on the phone; remove it before recording — it dominates the sensor and its own field wander will look like signal.",
                    field))
    }

    struct MotionMetrics {
        var gyroPeak: Double
        var accelPeak: Double
        var orientationChanges: Int
        var label: String
    }

    static func motionMetrics(_ samples: [SensorSample]) -> MotionMetrics {
        let gyro = samples.map {
            sqrt($0.rotationRate.x * $0.rotationRate.x + $0.rotationRate.y * $0.rotationRate.y + $0.rotationRate.z * $0.rotationRate.z)
        }
        let accel = samples.map { $0.acceleration.magnitude }
        let gyroPeak = gyro.max() ?? 0
        let accelPeak = accel.max() ?? 0
        var changes = 0
        var last = samples.first?.orientation
        for s in samples where s.orientation != "unknown" {
            if let l = last, l != "unknown", s.orientation != l { changes += 1 }
            last = s.orientation
        }
        // The label is DERIVED, never taken from a user field.
        let label: String
        if changes > 0 {
            label = "reoriented"
        } else if gyroPeak > 1.0 {
            label = "rotating"
        } else if accelPeak > 0.3 {
            label = "translating"
        } else if gyroPeak > GateReport.gyroLimitRadPerSec || accelPeak > GateReport.accelLimitG {
            label = "restless"
        } else {
            label = "stationary"
        }
        return MotionMetrics(gyroPeak: gyroPeak, accelPeak: accelPeak, orientationChanges: changes, label: label)
    }

    static func motionResult(_ m: MotionMetrics) -> GateResult {
        let ok = m.orientationChanges == 0 && m.gyroPeak <= GateReport.gyroLimitRadPerSec && m.accelPeak <= GateReport.accelLimitG
        var reasons: [String] = []
        if m.orientationChanges > 0 { reasons.append("orientation changed \(m.orientationChanges)× mid-record") }
        if m.gyroPeak > GateReport.gyroLimitRadPerSec {
            reasons.append(String(format: "gyro peaked at %.2f rad/s (limit %.2f)", m.gyroPeak, GateReport.gyroLimitRadPerSec))
        }
        if m.accelPeak > GateReport.accelLimitG {
            reasons.append(String(format: "user-acceleration peaked at %.2f g (limit %.2f)", m.accelPeak, GateReport.accelLimitG))
        }
        return GateResult(
            gate: .motion, passed: ok,
            reason: ok
                ? String(
                    format: "Derived motion: %@. Gyro peak %.3f rad/s, accel %.3f g, no orientation change.", m.label, m.gyroPeak,
                    m.accelPeak)
                : "Derived motion: \(m.label). " + reasons.joined(separator: "; ")
                    + ". Turning the phone in the Earth's 50 µT field writes a signal across the whole band, so this session cannot be preregistered."
        )
    }

    static func clockResult(monoSpan: Double, wallSpan: Double, duration: Double) -> GateResult {
        let tol = GateReport.clockToleranceFraction
        let a = max(monoSpan, wallSpan, duration)
        let b = min(monoSpan, wallSpan, duration)
        let ok = a > 0 && (a - b) / a <= tol
        return GateResult(
            gate: .clockConsistency, passed: ok,
            reason: ok
                ? String(
                    format: "Monotonic %.1f s, wall %.1f s, preregistered %.0f s all agree within %.0f%%.", monoSpan, wallSpan, duration,
                    tol * 100)
                : String(
                    format:
                        "Monotonic span %.2f s, wall span %.2f s, preregistered %.0f s disagree beyond %.0f%%. Two clocks that far apart mean samples were dropped or the run was interrupted; the timebase cannot be trusted.",
                    monoSpan, wallSpan, duration, tol * 100))
    }

    static func sampleCountResult(got: Int, expected: Int) -> GateResult {
        let ok = expected <= 0 || Double(got) >= Double(expected) * GateReport.minimumSampleFraction
        return GateResult(
            gate: .sampleCount, passed: ok,
            reason: ok
                ? "Collected \(got) samples of ~\(expected) expected."
                : String(
                    format:
                        "Collected %d samples of ~%d expected (%.0f%%). Below %.0f%% means the sensor was starved — a throttled app, a dropped stream — and the analysis window is not what was preregistered.",
                    got, expected, expected > 0 ? Double(got) / Double(expected) * 100 : 0, GateReport.minimumSampleFraction * 100))
    }

    /// |Δ|B|| vs rotation-rate magnitude. A real external vector does not correlate with how the
    /// phone is turning; a device-fixed artefact (the phone rotating in the ambient field) does.
    static func fieldVsRotation(_ samples: [SensorSample]) -> Double {
        guard samples.count > 3 else { return 0 }
        let mag = samples.map(\.magnetic.magnitude)
        let dMag = (1..<mag.count).map { abs(mag[$0] - mag[$0 - 1]) }
        let rot = (1..<samples.count).map {
            sqrt(
                samples[$0].rotationRate.x * samples[$0].rotationRate.x + samples[$0].rotationRate.y * samples[$0].rotationRate.y + samples[
                    $0
                ].rotationRate.z * samples[$0].rotationRate.z)
        }
        return correlation(dMag, rot)
    }

    // MARK: - small stats

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s[s.count / 2]
    }
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0
        var da = 0.0
        var db = 0.0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb)
            da += (x - ma) * (x - ma)
            db += (y - mb) * (y - mb)
        }
        return num / max(1e-15, (da * db).squareRoot())
    }
}
