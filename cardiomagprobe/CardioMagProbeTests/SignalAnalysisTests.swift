import XCTest
@testable import CardioMagProbe

final class SignalAnalysisTests: XCTestCase {
    private func makeSamples(
        duration: Double = 30, hz: Double = 50, beats: [Double] = stride(from: 2.0, through: 28.0, by: 1.0).map { $0 },
        amplitude: Double = 0.08
    ) -> [SensorSample] {
        let dt = 1 / hz
        return stride(from: 0.0, through: duration, by: dt).enumerated().map { i, t in
            let signal = beats.reduce(0.0) { sum, beat in sum + amplitude * exp(-pow((t - beat - 0.12) / 0.045, 2)) }
            return SensorSample(
                id: i, sessionID: "test", monotonicTime: t, wallClockISO8601: "2026-01-01T00:00:00Z", magX: signal + 0.002 * sin(t * 17),
                magY: 0, magZ: 0, calibratedMagX: nil, calibratedMagY: nil, calibratedMagZ: nil, accelX: 0, accelY: 0, accelZ: 1, gyroX: 0,
                gyroY: 0, gyroZ: 0, attitudeX: nil, attitudeY: nil, attitudeZ: nil, attitudeW: nil, ppg: nil, beatMarker: false,
                motionQuality: true, condition: "test", distanceCM: 5, placementNote: "")
        }
    }

    func testEpochExtractionAlignsKnownPeak() {
        let beats = stride(from: 2.0, through: 28.0, by: 1.0).map { $0 }
        let samples = makeSamples(beats: beats)
        let grid = stride(from: -0.5, through: 0.5, by: 0.02).map { $0 }
        let epochs = SignalAnalysis.extractEpochs(
            samples: samples, beatTimes: beats, grid: grid, channel: { $0.magX }, settings: AnalysisSettings())
        let mean = SignalAnalysis.columnMean(epochs)
        let peakTime = grid[mean.indices.max(by: { mean[$0] < mean[$1] })!]
        XCTAssertEqual(peakTime, 0.12, accuracy: 0.03)
    }

    func testCircularShiftPreservesBeatCountAndBounds() {
        let shifted = SignalAnalysis.circularShift(times: [1, 2, 3, 4], start: 0, end: 5, offset: 2.2)
        XCTAssertEqual(shifted.count, 4)
        XCTAssertTrue(shifted.allSatisfy { $0 >= 0 && $0 < 5 })
    }

    func testJitterIsDeterministicAndBounded() {
        let beats = [1.0, 2.0, 3.0]
        let a = SignalAnalysis.jittered(times: beats, milliseconds: 50, seed: 7)
        XCTAssertEqual(a, SignalAnalysis.jittered(times: beats, milliseconds: 50, seed: 7))
        XCTAssertTrue(zip(a, beats).allSatisfy { abs($0 - $1) <= 0.05 })
    }

    func testHeldOutTemplateRecoversInjectedMorphology() {
        let beats = stride(from: 2.0, through: 28.0, by: 1.0).map { $0 }
        let r = SignalAnalysis.heldOutTemplateCorrelation(
            samples: makeSamples(beats: beats), beatTimes: beats, settings: AnalysisSettings())
        XCTAssertGreaterThan(r, 0.9)
    }

    /// Beats vary from one to the next, as a heart's do. With every interval exactly 1 s, shuffling the
    /// intervals rebuilds the real beat train, so the shuffled-interval null equals the real statistic
    /// every time and p is 1 however strong the signal: this test failed that way from the start.
    private let variedBeats = SignalAnalysis.jittered(
        times: stride(from: 2.0, through: 28.0, by: 1.0).map { $0 }, milliseconds: 80, seed: 3)

    private func xAxisP(amplitude: Double) -> Double {
        var settings = AnalysisSettings()
        settings.surrogateCount = 100
        settings.bootstrapCount = 100
        let report = SignalAnalysis.analyze(
            samples: makeSamples(beats: variedBeats, amplitude: amplitude), beatTimes: variedBeats, settings: settings)
        XCTAssertNotNil(report)
        return report?.axisResults.first(where: { $0.axis == "X" })?.empiricalP ?? 1
    }

    func testCompleteAnalysisBeatsSurrogateNull() {
        XCTAssertLessThan(xAxisP(amplitude: 0.08), 0.05)
    }

    func testNoInjectedSignalIsNotDetected() {
        XCTAssertGreaterThan(xAxisP(amplitude: 0), 0.05)
    }
}
