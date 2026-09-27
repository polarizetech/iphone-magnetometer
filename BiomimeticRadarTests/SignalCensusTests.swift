import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// The census's job is to account for ALL the power and to refuse to name what it cannot identify.
/// These tests mostly check that it refuses correctly.
final class SignalCensusTests: XCTestCase {

    private func record(
        _ builder: (Double) -> Double, rate: Double = 50, seconds: Double = 60,
        rotation: (Double) -> Double = { _ in 0 }
    ) -> [SensorSample] {
        let n = Int(rate * seconds)
        return (0..<n).map { index in
            let t = Double(index) / rate
            let field = builder(t)
            return SensorSample(
                monotonicTime: t, wallTime: Date(timeIntervalSince1970: t),
                magnetic: Vector3(x: field, y: 0, z: 0),
                rotationRate: Vector3(x: rotation(t), y: 0, z: 0))
        }
    }

    /// The load-bearing arithmetic on this platform: 60 Hz mains does not vanish above Nyquist, it
    /// folds — and at the app's default 50 Hz it folds to 10 Hz, 1.7 Hz from the 8.3 Hz target.
    func testMainsFoldsOntoTheTargetBandAtTheDefaultRate() {
        XCTAssertEqual(SignalCensus.aliasOf(60, sampleRateHz: 50), 10, accuracy: 1e-9)
        XCTAssertTrue(SignalCensus.isAliased(60, sampleRateHz: 50))
        // Raising the rate moves it — which is exactly why the discriminator is a rate change.
        XCTAssertEqual(SignalCensus.aliasOf(60, sampleRateHz: 100), 40, accuracy: 1e-9)
        XCTAssertEqual(SignalCensus.aliasOf(50, sampleRateHz: 50), 0, accuracy: 1e-9)
        // Below Nyquist a tone is where it says it is.
        XCTAssertFalse(SignalCensus.isAliased(20, sampleRateHz: 50))
        XCTAssertEqual(SignalCensus.aliasOf(20, sampleRateHz: 50), 20, accuracy: 1e-9)
    }

    /// Every unit of measured power is accounted for. This is the whole contract.
    func testSharesPartitionTheVariance() {
        let samples = record { t in
            48 + 0.4 * sin(2 * .pi * 8.3 * t) + 0.3 * sin(2 * .pi * 17.11 * t)
                + 0.05 * sin(2 * .pi * 0.03 * t)
        }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        let total = result.components.reduce(0) { $0 + $1.fraction }
        XCTAssertEqual(total, 1.0, accuracy: 0.02)
        XCTAssertGreaterThan(result.standingFieldMicrotesla, 47)
    }

    /// A line in no known band gets a number, not a name.
    ///
    /// 6.37 Hz is deliberately chosen: it falls in the gap between Pc1 (which stops at 5 Hz) and
    /// Schumann 1 (which starts at 7.2), so nothing in the registry can claim it.
    func testAnUnexplainedLineIsReportedAnonymouslyRatherThanGuessedAt() {
        let samples = record { t in 48 + 0.5 * sin(2 * .pi * 6.37 * t) }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        let anonymous = result.components.filter { $0.id.hasPrefix("U-") }
        XCTAssertEqual(anonymous.count, 1)
        let line = try! XCTUnwrap(anonymous.first)
        XCTAssertEqual(line.status, .unattributed)
        XCTAssertEqual(try XCTUnwrap(line.centreHz), 6.37, accuracy: 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(line.prominenceDB), 6)
        XCTAssertTrue(line.evidence.contains("inside no band this instrument knows about"))
        XCTAssertTrue(line.discriminator.contains("sample rate"))
        XCTAssertGreaterThan(result.unattributedFraction, 0.5)
    }

    /// A band wider than the sampled spectrum folds onto several stretches at once and must be
    /// given NO bins. The mains-harmonic band (99–181 Hz) does this at 50 Hz, and when it was
    /// allowed a location it claimed 0–22.5 Hz and swallowed every other component.
    func testAWideBandThatWrapsIsRefusedALocation() {
        let harmonics = try! XCTUnwrap(BandRegistry.band("mains-harmonic"))
        let seen = BandRegistry.visibility(of: harmonics, sampleRateHz: 50, targetHz: 8.3)
        XCTAssertEqual(seen.visibility, .smeared)
        XCTAssertTrue(seen.note.contains("crosses a Nyquist boundary"))

        let samples = record { t in 48 + 0.5 * sin(2 * .pi * 6.37 * t) }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        let entry = try! XCTUnwrap(result.components.first { $0.id == "mains-harmonic" })
        XCTAssertEqual(entry.fraction, 0, "an unlocatable band may not claim any share")
        XCTAssertTrue(result.notes.contains { $0.contains("cannot be located") })
        // And with it refused, the 6.37 Hz line is visible again as an anonymous entry.
        XCTAssertEqual(result.components.filter { $0.id.hasPrefix("U-") }.count, 1)

        // At 100 Hz the same band sits inside one Nyquist zone and becomes locatable.
        XCTAssertEqual(BandRegistry.visibility(of: harmonics, sampleRateHz: 400, targetHz: 8.3).visibility, .direct)
    }

    /// The complement: a line that DOES fall in a known band is named by the registry rather than
    /// numbered. 20.8 Hz is the third Schumann mode's nominal frequency.
    func testALineInsideAKnownBandTakesThatBandsName() {
        let samples = record { t in 48 + 0.5 * sin(2 * .pi * 20.8 * t) }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        let band = try! XCTUnwrap(result.components.first { $0.id == "schumann-3" })
        XCTAssertEqual(band.status, .suspected, "a line in a known band is suspected, never attributed")
        XCTAssertGreaterThan(band.fraction, 0.5)
        XCTAssertTrue(band.evidence.contains("Third cavity mode"))
        // And the expected amplitude travels with it, so nobody reads this as a Schumann detection.
        XCTAssertTrue(band.evidence.contains("0.3 pT"))
        XCTAssertTrue(result.components.filter { $0.id.hasPrefix("U-") }.isEmpty)
    }

    /// Power in the target band is not evidence of the coded signal, and the census says so rather
    /// than letting a green number imply it.
    func testTargetBandIsAttributedToTheREQUESTNotToADetection() {
        let samples = record { t in 48 + 0.5 * sin(2 * .pi * 8.3 * t) }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        let target = try! XCTUnwrap(result.components.first { $0.id == "target" })
        XCTAssertGreaterThan(target.fraction, 0.5)
        XCTAssertTrue(target.evidence.contains("NOT evidence"))
        XCTAssertTrue(target.discriminator.contains("matched filter"))
    }

    /// A stationary record cannot answer whether motion couples, and must say "untested" instead of
    /// "0%" — the difference between a measurement and a missing measurement.
    func testStationaryRecordRefusesToClearMotion() {
        let samples = record { t in 48 + 0.2 * sin(2 * .pi * 8.3 * t) }
        let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
        XCTAssertNil(result.motion.varianceExplained)
        XCTAssertTrue(result.motion.verdict.contains("untested"))
    }

    /// With the phone actually moving, the coupling is measured — and a field that tracks the
    /// phone's ORIENTATION is caught rather than counted as signal.
    ///
    /// The predictor is attitude, not rotation rate: |ω| is unsigned and peaks twice per cycle, so
    /// regressing on it returned R² = 1.5e-9 for this very record. The test kept its record and the
    /// implementation changed.
    func testMotionCouplingIsDetectedWhenThePhoneMoves() {
        let rate = 50.0
        let samples = (0..<3000).map { index -> SensorSample in
            let t = Double(index) / rate
            let angle = 2 * Double.pi * 0.4 * t
            // Attitude sweeping through a rotation about x, and a |B| that follows it — the
            // signature of ordinary axis gain error in a real magnetometer.
            let qx = sin(angle / 2)
            let qw = cos(angle / 2)
            return SensorSample(
                monotonicTime: t, wallTime: Date(timeIntervalSince1970: t),
                magnetic: Vector3(x: 48 + 3.0 * qx, y: 0, z: 0),
                rotationRate: Vector3(x: 2 * Double.pi * 0.4, y: 0, z: 0),
                attitude: Quaternion(x: qx, y: 0, z: 0, w: qw))
        }
        let result = SignalCensus.census(samples: samples, sampleRateHz: rate, targetHz: 8.3)
        let explained = try! XCTUnwrap(result.motion.varianceExplained)
        XCTAssertGreaterThan(explained, 0.8)
        XCTAssertTrue(result.motion.verdict.contains("recording of the phone moving"))
    }

    /// Rotation RATE cannot predict a field that follows orientation. Pinned so the regressor is
    /// never quietly swapped back.
    func testRotationRateIsTheWrongPredictor() {
        let n = 2000
        let rate = 50.0
        // One rotation cycle: attitude sweeps once, |ω| peaks twice, and the field follows attitude.
        let field = (0..<n).map { 3.0 * sin(2 * .pi * 0.4 * Double($0) / rate) }
        let speed = (0..<n).map { abs(1.5 * cos(2 * .pi * 0.4 * Double($0) / rate)) }
        let attitude = field
        XCTAssertLessThan(SignalCensus.varianceExplained(y: field, predictors: [speed]), 0.05)
        XCTAssertGreaterThan(SignalCensus.varianceExplained(y: field, predictors: [attitude]), 0.9)
        // A predictor that never varies must be ignored, not fatal: rotating about one axis leaves
        // two quaternion components flat, and letting those veto the fit returned R² = 0 for a
        // record that was entirely orientation-driven.
        let flat = [Double](repeating: 1, count: n)
        XCTAssertGreaterThan(SignalCensus.varianceExplained(y: field, predictors: [flat, attitude]), 0.9)
    }

    /// A phone turning at a CONSTANT rate has a rotation-rate range of zero while its orientation
    /// sweeps a full circle. The "did it move" gate must not be fooled by that, and once was.
    func testConstantRotationStillCountsAsMotion() {
        let rate = 50.0
        let samples = (0..<600).map { index -> SensorSample in
            let t = Double(index) / rate
            let angle = 2 * Double.pi * 0.4 * t
            return SensorSample(
                monotonicTime: t, wallTime: Date(),
                magnetic: Vector3(x: 48 + 3.0 * sin(angle / 2), y: 0, z: 0),
                rotationRate: Vector3(x: 2 * Double.pi * 0.4, y: 0, z: 0),
                attitude: Quaternion(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2)))
        }
        let coupling = SignalCensus.motionCoupling(
            samples: samples,
            ac: samples.map(\.magnetic.magnitude))
        XCTAssertEqual(coupling.rotationRangeRadPerS, 0, accuracy: 1e-9)
        XCTAssertNotNil(coupling.varianceExplained, "constant rotation is still motion")
    }

    /// The scenario this whole screen exists for: real 60 Hz mains in the room, sampled at the
    /// app's default 50 Hz. The samples alias to 10 Hz — 1.7 Hz from the 8.3 Hz target — and the
    /// census has to say so loudly rather than let it read as a nearby signal.
    func testRealMainsSampledAt50HzLandsBesideTheTargetAndIsFlagged() {
        let rate = 50.0
        var generator = SeededGenerator(seed: 5)
        let samples = (0..<3000).map { index -> SensorSample in
            let t = Double(index) / rate
            let mains: Double = 0.35 * sin(2 * .pi * 60.0 * t)  // genuinely 60 Hz in the room
            let noise: Double = Double.random(in: -0.05...0.05, using: &generator)
            return SensorSample(
                monotonicTime: t, wallTime: Date(),
                magnetic: Vector3(x: 48 + mains + noise, y: 0, z: 0))
        }
        let result = SignalCensus.census(samples: samples, sampleRateHz: rate, targetHz: 8.3)
        let mains = try! XCTUnwrap(result.components.first { $0.id == "mains-60" })
        XCTAssertEqual(mains.status, .suspected)
        XCTAssertEqual(try XCTUnwrap(mains.centreHz), 10.0, accuracy: 0.3)
        XCTAssertTrue(mains.label.contains("folded"))
        XCTAssertGreaterThan(mains.fraction, 0.5)
        XCTAssertTrue(
            result.notes.contains { $0.contains("folds to") && $0.contains("target") },
            "the fold onto the target band must be called out in the notes")

        print("\n— census of a 60 Hz-contaminated 50 Hz record —")
        print(
            String(
                format: "standing %.2f µT · AC RMS %.4f µT · unattributed %.1f%%",
                result.standingFieldMicrotesla, result.acRMSMicrotesla,
                result.unattributedFraction * 100))
        for component in result.components {
            print(
                String(
                    format: "  %-46@ %-14@ %6.2f%%", component.label as NSString,
                    component.status.rawValue as NSString, component.fraction * 100))
        }
        for note in result.notes where note.hasPrefix("⚠️") { print("  " + note) }
    }

    /// Noise does not become a finding by falling inside a named band, and it does not become an
    /// unidentified line either. Run over several seeds, because a false-alarm claim made from one
    /// noise record is not a claim about the false-alarm rate.
    func testNoiseProducesNoFindingsAcrossSeeds() {
        for seed in [UInt64(99), 1234, 20260822, 7] {
            var generator = SeededGenerator(seed: seed)
            let samples = (0..<3000).map { index -> SensorSample in
                let value = Double.random(in: -0.2...0.2, using: &generator)
                return SensorSample(
                    monotonicTime: Double(index) / 50, wallTime: Date(),
                    magnetic: Vector3(x: 48 + value, y: 0, z: 0))
            }
            let result = SignalCensus.census(samples: samples, sampleRateHz: 50, targetHz: 8.3)
            let floor = try! XCTUnwrap(result.components.first { $0.id == "floor" })
            XCTAssertEqual(floor.status, .unattributed)
            XCTAssertTrue(floor.evidence.contains("not an identification"))
            // Everything except the target band must be unattributed. The target is `attributed`
            // by construction — attributed to the REQUEST, not to a detection — and it legitimately
            // holds ~4% of the variance on a noise record simply by being 1 Hz wide.
            let targetShare = result.components.first { $0.id == "target" }?.fraction ?? 0
            XCTAssertGreaterThan(
                result.unattributedFraction + targetShare, 0.99,
                "seed \(seed): a named band holding only noise must stay unattributed")
            for component in result.components where component.id != "target" {
                XCTAssertEqual(
                    component.status, .unattributed,
                    "seed \(seed): \(component.id) claimed noise as a finding")
            }
            XCTAssertTrue(
                result.components.filter { $0.id.hasPrefix("U-") }.isEmpty,
                "seed \(seed): pure noise must not produce unidentified LINES")
            XCTAssertTrue(
                result.components.allSatisfy { $0.status != .suspected },
                "seed \(seed): pure noise must not produce a suspected band")
        }
    }

    /// The prominence bar is computed from how many bins were searched, not chosen. At 1024 bins
    /// and a 1% family-wise false-alarm rate it is 12.2 dB; the flat 4 dB it replaced let pure
    /// noise produce eight "unidentified lines".
    func testProminenceThresholdScalesWithTheSearchSize() {
        XCTAssertEqual(SignalCensus.prominenceThresholdDB(binCount: 1024), 12.2, accuracy: 0.15)
        // More places to look means a higher bar.
        XCTAssertGreaterThan(
            SignalCensus.prominenceThresholdDB(binCount: 8192),
            SignalCensus.prominenceThresholdDB(binCount: 1024))
        // A stricter false-alarm rate means a higher bar.
        XCTAssertGreaterThan(
            SignalCensus.prominenceThresholdDB(binCount: 1024, alpha: 0.001),
            SignalCensus.prominenceThresholdDB(binCount: 1024, alpha: 0.01))
    }

    /// A component that appears halfway through a run is a different object from one that was
    /// always there, and the census measures which.
    func testHalfSplitCatchesAComponentThatArrivesMidRun() {
        let rate = 50.0
        var generator = SeededGenerator(seed: 3)
        let signal = (0..<3000).map { index -> Double in
            let t = Double(index) / rate
            let noise = Double.random(in: -0.02...0.02, using: &generator)
            return noise + (t > 30 ? 0.5 * sin(2 * .pi * 12.0 * t) : 0)
        }
        let drift = try! XCTUnwrap(SignalCensus.halfSplitDB(signal, rate: rate, centre: 12.0, halfWidth: 0.5))
        XCTAssertGreaterThan(drift, 20)
    }
}
