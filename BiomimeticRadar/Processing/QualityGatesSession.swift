import Foundation

/// The session-level gate report — the half that needs a preregistered protocol to judge against.
///
/// Split from `QualityGates.swift` on 2026-08-23: the recorder app compiles only the sample-window
/// gates (DC field, motion), because those are the ones an operator can act on *before* pressing
/// record. Everything that compares a finished recording against what was preregistered — clock
/// spans, sample counts, the positive-control requirement — is analysis-side and is not built into
/// the phone.
extension QualityGates {

    /// The full report over a completed recording. Adds the clock and sample-count gates, which
    /// only mean anything once the run is over, and the field-vs-rotation diagnostic.
    static func postRecord(
        samples: [SensorSample], plan: ExperimentProtocol,
        startedAt: Date, endedAt: Date?, achievedRate: Double,
        hasPassingPositiveControl: Bool?
    ) -> GateReport {
        var report = preflight(samples: samples)
        guard samples.count > 2 else { return report }

        let mono = samples.map(\.monotonicTime)
        let monoSpan = mono.last! - mono.first!
        let wallSpan = (endedAt ?? samples.last!.wallTime).timeIntervalSince(startedAt)
        report.monotonicSpanS = monoSpan
        report.wallSpanS = wallSpan
        report.preregisteredDurationS = plan.durationSeconds
        report.results.append(clockResult(monoSpan: monoSpan, wallSpan: wallSpan, duration: plan.durationSeconds))

        let expected = Int(plan.durationSeconds * achievedRate)
        report.achievedSamples = samples.count
        report.expectedSamples = expected
        report.results.append(sampleCountResult(got: samples.count, expected: expected))

        report.fieldVsRotationCorrelation = fieldVsRotation(samples)

        if let hasControl = hasPassingPositiveControl {
            report.results.append(
                GateResult(
                    gate: .positiveControl, passed: hasControl,
                    reason: hasControl
                        ? "A passing emitter-on control exists for this device and protocol; a null here is interpretable."
                        : "No passing emitter-on control for this device and protocol. An emitter-off null cannot be called meaningful — it may only mean the detector was never shown it could detect.",
                    informational: false))
        } else {
            report.results.append(
                GateResult(
                    gate: .positiveControl, passed: true,
                    reason:
                        "Positive-control status unknown (not checked). A null result should not be reported as meaningful until an emitter-on control has passed for this device and protocol.",
                    informational: true))
        }
        return report
    }
}
