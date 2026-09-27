import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

final class SignalProcessorTests: XCTestCase {
    private let processor = SignalProcessor()

    func testSyntheticNoisySineRecovery() {
        let rate = 50.0
        let frequency = 8.3
        let signal = (0..<5_000).map { index -> Double in
            let time = Double(index) / rate
            let target = 0.08 * sin(2.0 * Double.pi * frequency * time)
            let interference = 0.3 * sin(Double(index) * 1.731)
            return target + interference
        }
        let result = processor.lockIn(signal: signal, sampleRate: rate, frequency: frequency)
        XCTAssertEqual(result.amplitude, 0.08, accuracy: 0.012)
        XCTAssertGreaterThan(result.confidence, 0.99)
    }

    func testPhaseDetection() {
        let rate = 100.0
        let frequency = 4.0
        let phase = 0.7
        let signal = (0..<2_000).map { index in cos(2 * .pi * frequency * Double(index) / rate - phase) }
        let result = processor.lockIn(signal: signal, sampleRate: rate, frequency: frequency)
        XCTAssertEqual(result.phaseRadians, phase, accuracy: 0.02)
    }

    func testMatchedFilterRecoversKnownLag() {
        let rate = 50.0
        let reference = processor.codedReference(
            count: 2_000, sampleRate: rate, carrierHz: 8.3,
            code: [1, 1, 1, -1, -1, 1, -1], chipDuration: 0.25)
        let lag = 17
        let signal = Array(repeating: 0.0, count: lag) + Array(reference.dropLast(lag))
        let result = processor.matchedFilter(signal: signal, reference: reference, shuffleCount: 150)
        XCTAssertEqual(result.bestLagSamples, lag, accuracy: 1)
        XCTAssertGreaterThan(result.peakCorrelation, 0.98)
        XCTAssertLessThan(result.pValue, 0.02)
    }

    func testNullShuffleBehavior() {
        let signal = (0..<1_000).map { sin(Double($0) * 1.231) + cos(Double($0) * 0.417) }
        let reference = (0..<1_000).map { sin(Double($0) * 0.913) }
        let result = processor.matchedFilter(signal: signal, reference: reference, shuffleCount: 120)
        XCTAssertLessThan(abs(result.peakCorrelation), 0.25)
        XCTAssertGreaterThan(result.pValue, 0.05)
    }

    func testTimingAlignmentUsesMedianInterval() {
        let times = [0.0, 0.02, 0.04, 0.061, 0.08, 0.10, 0.12]
        XCTAssertEqual(processor.estimatedSampleRate(times: times, fallback: 10), 50, accuracy: 0.1)
    }

    func testBenjaminiHochbergCorrection() {
        let adjusted = processor.benjaminiHochberg([0.01, 0.04, 0.20, 0.001])
        XCTAssertEqual(adjusted[0], 0.02, accuracy: 0.0001)
        XCTAssertEqual(adjusted[1], 0.053333, accuracy: 0.0001)
        XCTAssertEqual(adjusted[2], 0.20, accuracy: 0.0001)
        XCTAssertEqual(adjusted[3], 0.004, accuracy: 0.0001)
    }
}

/// The controls that used to be toggles doing nothing, and the two numbers that used to be wrong.
extension SignalProcessorTests {

    /// The lock-in now returns a real F-test p-value. The old `1 − confidence` was an ad-hoc
    /// `1 − exp(−(A/N)²·n/4)` that was being Benjamini–Hochberg corrected beside a genuine
    /// permutation p-value — two numbers on different scales in one correction.
    func testLockInPValueIsAnFTestAndBehavesLikeOne() {
        let rate = 100.0
        let n = 4000
        var generator = SeededGenerator(seed: 11)
        let noise = (0..<n).map { _ in Double.random(in: -1...1, using: &generator) }
        let quiet = SignalProcessor().lockIn(signal: noise, sampleRate: rate, frequency: 8.3)
        XCTAssertGreaterThan(quiet.pValue, 0.01, "pure noise must not produce a small p")

        let withSignal = (0..<n).map { index -> Double in
            noise[index] + 0.25 * sin(2 * .pi * 8.3 * Double(index) / rate)
        }
        let loud = SignalProcessor().lockIn(signal: withSignal, sampleRate: rate, frequency: 8.3)
        XCTAssertLessThan(loud.pValue, 1e-6)
        XCTAssertEqual(loud.confidence, 1 - loud.pValue, accuracy: 1e-12)
        // The closed form is exact for d1 = 2, which is why the fit has exactly two parameters.
        XCTAssertEqual(SignalProcessor().fTestPValue(f: 0, d1: 2, d2: 100), 1.0, accuracy: 1e-12)
    }

    /// Timestamp correction is a real control with a measurable effect: with a jittering clock, the
    /// lock-in that uses the true sample instants recovers more amplitude than the one assuming a
    /// uniform grid.
    func testTimestampCorrectionRecoversAmplitudeAJitteringClockLoses() {
        let nominal = 100.0
        let n = 6000
        let frequency = 8.3
        var generator = SeededGenerator(seed: 5)
        var times: [Double] = []
        var t = 0.0
        for _ in 0..<n {
            t += (1 / nominal) * Double.random(in: 0.5...1.5, using: &generator)
            times.append(t)
        }
        let signal = times.map { sin(2 * .pi * frequency * $0) }
        let processor = SignalProcessor()
        let rate = processor.estimatedSampleRate(times: times, fallback: nominal)
        let assumed = processor.lockIn(signal: signal, sampleRate: rate, frequency: frequency)
        let corrected = processor.lockIn(
            signal: signal, sampleRate: rate, frequency: frequency,
            times: times.map { $0 - times[0] })
        XCTAssertEqual(corrected.amplitude, 1.0, accuracy: 0.05)
        XCTAssertLessThan(
            assumed.amplitude, corrected.amplitude * 0.8,
            "an assumed uniform clock should lose amplitude to jitter; if it does not, this test is not exercising jitter")
    }

    /// Harmonics separate a linear carrier from a mechanical or switching artefact at the same rate.
    func testHarmonicsSeparateACleanCarrierFromASquareOne() {
        let rate = 100.0
        let n = 4000
        let frequency = 8.3
        let clean = (0..<n).map { sin(2 * .pi * frequency * Double($0) / rate) }
        let square = (0..<n).map { sin(2 * .pi * frequency * Double($0) / rate) >= 0 ? 1.0 : -1.0 }
        let processor = SignalProcessor()
        let cleanReport = processor.harmonicReport(clean, sampleRate: rate, fundamental: frequency, times: nil)
        let squareReport = processor.harmonicReport(square, sampleRate: rate, fundamental: frequency, times: nil)
        XCTAssertLessThan(cleanReport.thirdHarmonicDB, -40)
        XCTAssertGreaterThan(squareReport.thirdHarmonicDB, -15, "a square wave is a third of its fundamental at 3f")
    }

    /// Phase tracking is the cheapest way to tell the phone's own emission from the world: a source
    /// sharing the sample clock does not drift, and everything external does.
    func testPhaseDoesNotDriftForASourceLockedToTheSampleClock() {
        let rate = 100.0
        let n = 6000
        let locked = (0..<n).map { sin(2 * .pi * 8.0 * Double($0) / rate) }
        let offset = (0..<n).map { sin(2 * .pi * 8.02 * Double($0) / rate) }  // 0.02 Hz adrift
        let processor = SignalProcessor()
        let lockedTrace = processor.phaseTrace(locked, sampleRate: rate, frequency: 8.0)
        let driftTrace = processor.phaseTrace(offset, sampleRate: rate, frequency: 8.0)
        let lockedDrift = abs((lockedTrace.last?.value ?? 0) - (lockedTrace.first?.value ?? 0))
        let realDrift = abs((driftTrace.last?.value ?? 0) - (driftTrace.first?.value ?? 0))
        XCTAssertLessThan(lockedDrift, 0.05)
        XCTAssertGreaterThan(realDrift, 1.0)
    }

    /// Coherent averaging reports what it ACHIEVED against the ideal √N, so a signal that is not
    /// phase-stable across code periods shows up as a shortfall rather than as a gain.
    func testCoherentAveragingReportsAchievedVersusIdealGain() {
        let rate = 100.0
        let period = 1.75  // 7 chips at 0.25 s
        let n = Int(rate * period * 20)
        var generator = SeededGenerator(seed: 3)
        let stable = (0..<n).map { index -> Double in
            let t = Double(index) / rate
            return sin(2 * .pi * 8.0 * t) + Double.random(in: -2...2, using: &generator)
        }
        let processor = SignalProcessor()
        let report = processor.coherentAveragingReport(stable, sampleRate: rate, periodSeconds: period)
        XCTAssertEqual(report.epochs, 19)  // 20 recorded, first dropped for filter settling
        XCTAssertGreaterThan(report.idealGainDB, 12)
        XCTAssertGreaterThan(report.achievedGainDB, 0)
        XCTAssertFalse(report.note.isEmpty)
        // The whole point of the rewrite: the achieved gain can NEVER beat the √N ceiling, because
        // noise cannot average better than independent. The old metric reported 30 dB against 15.
        XCTAssertLessThanOrEqual(report.achievedGainDB, report.idealGainDB + 1e-9)
        XCTAssertFalse(report.exceedsIdeal)
    }

    /// A record that is pure DRIFT with no phase-locked content used to report an impossible gain,
    /// because the first-epoch RMS was huge and the averaged mean was near zero. Now it is either a
    /// modest number or flagged, but never above the ceiling.
    func testAveragingRefusesToBeatRootN() {
        let rate = 100.0
        let period = 1.75
        let n = Int(rate * period * 12)
        let drift = (0..<n).map { Double($0) / Double(n) * 100 }  // a ramp: all drift, no signal, no noise
        let report = SignalProcessor().coherentAveragingReport(drift, sampleRate: rate, periodSeconds: period)
        XCTAssertLessThanOrEqual(report.achievedGainDB, report.idealGainDB + 1e-9)
    }

    /// The tier is computed from what happened. A `preregistered` switch can no longer promote a
    /// result on its own, and a run with the phone's own emitter on can never reach `significant`.
    func testTierIsComputedAndTheEmitterCapsIt() {
        let rate = 100.0
        var plan = ExperimentProtocol()
        plan.sampleRateHz = rate
        plan.durationSeconds = 40
        plan.targetFrequencyHz = 8.3
        let reference = SignalProcessor().codedReference(
            count: 4000, sampleRate: rate, carrierHz: 8.3,
            code: plan.code, chipDuration: plan.chipDurationSeconds)
        // Realistic wall times (span == monotonic span) and a healthy 48 µT baseline, so the data
        // gates PASS and the tier is decided by the detection alone.
        let base = 1_756_000_000.0
        let samples = reference.enumerated().map { index, value in
            SensorSample(
                monotonicTime: Double(index) / rate, wallTime: Date(timeIntervalSince1970: base + Double(index) / rate),
                magnetic: Vector3(x: 48 + 0.5 * value, y: 0, z: 0))
        }
        let started = Date(timeIntervalSince1970: base)
        let ended = Date(timeIntervalSince1970: base + 40)
        let external = SignalProcessor().analyze(
            samples: samples, protocol: plan, shuffleCount: 60,
            startedAt: started, endedAt: ended)
        XCTAssertTrue(external.passedNullControls)
        XCTAssertFalse(external.gates.blocks, "the synthetic record must clear every data gate")
        XCTAssertEqual(external.resultTier, .significant)

        let selfEmitted = SignalProcessor().analyze(
            samples: samples, protocol: plan,
            shuffleCount: 60, emitterRunning: true,
            startedAt: started, endedAt: ended)
        XCTAssertTrue(selfEmitted.passedNullControls, "the detection is real — of our own emission")
        XCTAssertEqual(selfEmitted.resultTier, .exploratory, "and it may never be reported as significant")
        XCTAssertTrue(selfEmitted.warnings.contains { $0.contains(EmitterSchedule.stamp) })
    }

    /// The passband has to be at least as wide as the code, or the filter removes the code.
    /// Found by feeding the analysis a noiseless copy of its own reference and watching it fail.
    func testPassbandIsDerivedFromTheCodeAndWarnsWhenItIsNot() {
        let processor = SignalProcessor()
        var plan = ExperimentProtocol()
        plan.targetFrequencyHz = 8.3
        plan.chipDurationSeconds = 0.25
        let band = processor.passband(for: plan, sampleRate: 100)
        XCTAssertEqual(band.low, 4.3, accuracy: 0.01)
        XCTAssertEqual(band.high, 12.3, accuracy: 0.01)
        XCTAssertEqual(processor.codeBandwidthHz(plan), 8.0, accuracy: 1e-9)

        // Set by hand and too narrow: the analysis still runs and says what is wrong.
        plan.processing.autoBandwidthFromCode = false
        plan.processing.lowCutoffHz = 7.8
        plan.processing.highCutoffHz = 8.8
        let samples = (0..<2000).map { index in
            SensorSample(
                monotonicTime: Double(index) / 100, wallTime: Date(),
                magnetic: Vector3(x: 48, y: 0, z: 0))
        }
        let result = processor.analyze(samples: samples, protocol: plan, shuffleCount: 20)
        XCTAssertTrue(result.warnings.contains { $0.contains("removing the code") }, "\(result.warnings)")
    }

    /// The representation picker is a real choice: a rotation writes into a single axis and not into
    /// the rotation-invariant magnitude, which is why magnitude is the default.
    func testRepresentationChoiceChangesWhatIsAnalysed() {
        let samples = (0..<600).map { index -> SensorSample in
            let angle = 2 * Double.pi * 0.5 * Double(index) / 100
            return SensorSample(
                monotonicTime: Double(index) / 100, wallTime: Date(),
                magnetic: Vector3(x: 48 * cos(angle), y: 48 * sin(angle), z: 0),
                attitude: Quaternion(x: 0, y: 0, z: sin(angle / 2), w: cos(angle / 2)))
        }
        let processor = SignalProcessor()
        let magnitude = processor.channel(.magnitude, from: samples)
        let axisX = processor.channel(.axisX, from: samples)
        let spreadMagnitude = (magnitude.max() ?? 0) - (magnitude.min() ?? 0)
        let spreadAxis = (axisX.max() ?? 0) - (axisX.min() ?? 0)
        XCTAssertLessThan(spreadMagnitude, 0.01, "|B| is rotation-invariant")
        XCTAssertGreaterThan(spreadAxis, 90, "a single axis is not")
    }
}
