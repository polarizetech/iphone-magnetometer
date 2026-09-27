import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// Golden-file replay of a REAL audited export (`golden/session-a-*`). This session was one of the
/// two the audit was written against: baseline |B| ≈ 690 µT (a magnet on the phone), the gyro
/// peaking near 9 rad/s while it was labelled "stationary", and an emitter-on `cpuLoad` run. The
/// test re-runs the current analysis over its raw samples and asserts the audit fixes are VISIBLE:
/// the achieved rate is measured (~101.4 Hz, not the requested 100), the DC and motion gates fail,
/// the tier is capped, and the averaging gain cannot exceed √N. It is a regression fence — if these
/// numbers move, the fixes changed, and that should be a deliberate diff.
final class GoldenSessionTests: XCTestCase {
    private func loadGolden() throws -> [SensorSample] {
        let url =
            Bundle.module.url(forResource: "session-a-raw", withExtension: "csv", subdirectory: "golden")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("golden/session-a-raw.csv")
        let text = try String(contentsOf: url)
        var out: [SensorSample] = []
        let iso = ISO8601DateFormatter()
        for (i, line) in text.split(separator: "\n").enumerated() where i > 0 {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 16 else { continue }
            out.append(
                SensorSample(
                    monotonicTime: Double(c[0]) ?? 0, wallTime: iso.date(from: c[1]) ?? Date(),
                    magnetic: Vector3(x: Double(c[2]) ?? 0, y: Double(c[3]) ?? 0, z: Double(c[4]) ?? 0),
                    acceleration: Vector3(x: Double(c[6]) ?? 0, y: Double(c[7]) ?? 0, z: Double(c[8]) ?? 0),
                    rotationRate: Vector3(x: Double(c[9]) ?? 0, y: Double(c[10]) ?? 0, z: Double(c[11]) ?? 0),
                    attitude: Quaternion(x: Double(c[12]) ?? 0, y: Double(c[13]) ?? 0, z: Double(c[14]) ?? 0, w: Double(c[15]) ?? 1),
                    orientation: c[16]))
        }
        return out
    }

    func testGoldenSessionReproducesAuditFindings() throws {
        let samples = try loadGolden()
        XCTAssertGreaterThan(samples.count, 6000)
        let processor = SignalProcessor()

        // The rate is MEASURED from the timestamps, not the requested 100 Hz.
        let rate = processor.estimatedSampleRate(times: samples.map(\.monotonicTime), fallback: 100)
        XCTAssertEqual(rate, 101.42, accuracy: 0.05)

        var plan = ExperimentProtocol()
        plan.sampleRateHz = 100  // as the export requested
        plan.targetFrequencyHz = 8.3
        plan.representation = .vector
        plan.durationSeconds = 60
        let r = processor.analyze(
            samples: samples, protocol: plan, shuffleCount: 60,
            startedAt: samples.first?.wallTime, endedAt: samples.last?.wallTime)

        // DC gate: 690 µT is a magnet, must fail.
        let dc = r.gates.results.first { $0.gate == .dcField }!
        XCTAssertFalse(dc.passed)
        XCTAssertEqual(r.gates.baselineFieldMicrotesla, 690.5, accuracy: 2.0)

        // Motion gate: gyro ~8.9 rad/s and an orientation change, must fail; label derived, not "stationary".
        let motion = r.gates.results.first { $0.gate == .motion }!
        XCTAssertFalse(motion.passed)
        XCTAssertGreaterThan(r.gates.gyroPeakRadPerSec, 5.0)
        XCTAssertGreaterThan(r.gates.orientationChanges, 0)
        XCTAssertNotEqual(r.gates.derivedMotion, "stationary")

        // Tier is capped by the failing gates whatever the detector did.
        XCTAssertTrue(r.gates.blocks)
        XCTAssertEqual(r.resultTier, .exploratory)

        // Averaging can never beat √N.
        if let avg = r.averaging { XCTAssertLessThanOrEqual(avg.achievedGainDB, avg.idealGainDB + 1e-9) }

        // A noise floor was measurable, so a null here would be a real bound.
        XCTAssertGreaterThan(r.calibration.noiseFloorNtPerRootHz, 0)
    }
}
