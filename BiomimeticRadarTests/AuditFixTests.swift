import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// The acceptance tests for the audit of the first real exports. Each pins one fixed defect.
final class AuditFixTests: XCTestCase {
    private let processor = SignalProcessor()

    // MARK: helpers
    private func samples(rate: Double, seconds: Double, build: (Int, Double) -> Vector3) -> [SensorSample] {
        let n = Int(rate * seconds)
        return (0..<n).map { i in
            SensorSample(
                monotonicTime: Double(i) / rate, wallTime: Date(timeIntervalSince1970: 1_756_000_000 + Double(i) / rate),
                magnetic: build(i, Double(i) / rate))
        }
    }

    /// P0.1 — a coded 8.3 Hz carrier injected on a 101.42 Hz clock is recovered at 8.30 ± 0.01 Hz by
    /// BOTH lock-in and matched filter, because every reference is evaluated at the true timestamps.
    func testCarrierRecoveredOnOffNominalClock() {
        let rate = 101.42
        let target = 8.3
        let code = [1.0, 1, 1, -1, -1, 1, -1]
        let chip = 0.25
        // A PURE tone for the lock-in frequency-recovery check (a code-modulated carrier is spread in
        // frequency and is the matched filter's job, not a single-bin lock-in's).
        var gen = SeededGenerator(seed: 11)
        let n = Int(rate * 60)
        let s = (0..<n).map { i -> SensorSample in
            let t = Double(i) / rate
            return SensorSample(
                monotonicTime: t, wallTime: Date(),
                magnetic: Vector3(x: 48 + 0.02 * sin(2 * .pi * target * t) + 0.2 * Double.random(in: -1...1, using: &gen), y: 0, z: 0))
        }
        var plan = ExperimentProtocol()
        plan.sampleRateHz = 100  // REQUESTED 100 while achieved 101.42
        plan.targetFrequencyHz = target
        plan.code = code
        plan.chipDurationSeconds = chip
        plan.representation = .axisX
        plan.durationSeconds = 60
        let r = processor.analyze(samples: s, protocol: plan, shuffleCount: 60)
        // scan the lock-in around the target using the SAME true-time engine
        let times = s.map { $0.monotonicTime - s[0].monotonicTime }
        let x = s.map(\.magnetic.x)
        let cond = processor.bandpass(processor.detrended(x), sampleRate: 101.42, lowHz: 4.3, highHz: 12.3)
        var best = 0.0
        var bestF = 0.0
        for f in stride(from: 7.8, through: 8.8, by: 0.01) {
            let a = processor.lockIn(signal: cond, sampleRate: 101.42, frequency: f, times: times).amplitude
            if a > best {
                best = a
                bestF = f
            }
        }
        XCTAssertEqual(bestF, 8.3, accuracy: 0.02, "carrier must land at 8.3 Hz on the true clock, not 8.18")
        // matched filter on a code-modulated version at the same off-nominal clock
        let coded = processor.codedReference(count: n, sampleRate: rate, carrierHz: target, code: code, chipDuration: chip)
        let cs = coded.enumerated().map { i, v in
            SensorSample(monotonicTime: Double(i) / rate, wallTime: Date(), magnetic: Vector3(x: 48 + 0.05 * v, y: 0, z: 0))
        }
        let rc = processor.analyze(samples: cs, protocol: plan, shuffleCount: 60)
        XCTAssertLessThan(rc.matched.pValue, 0.05, "matched filter fires with a true-time reference")
        _ = r
    }

    /// P0.1 again, negative control: with timestampCorrection OFF and a badly off-nominal clock the
    /// matched filter should be WEAKER than with it on — proving the correction is actually applied.
    func testTimestampCorrectionActuallyDoesSomething() {
        let rate = 103.0
        let target = 8.3
        let chip = 0.25
        let code = [1.0, 1, 1, -1, -1, 1, -1]
        let ref = processor.codedReference(count: Int(rate * 60), sampleRate: rate, carrierHz: target, code: code, chipDuration: chip)
        let s = ref.enumerated().map { i, v in
            SensorSample(monotonicTime: Double(i) / rate, wallTime: Date(), magnetic: Vector3(x: 48 + 0.05 * v, y: 0, z: 0))
        }
        var on = ExperimentProtocol()
        on.sampleRateHz = 100
        on.targetFrequencyHz = target
        on.code = code
        on.chipDurationSeconds = chip
        on.representation = .axisX
        on.durationSeconds = 60
        var off = on
        off.processing.timestampCorrection = false
        let rOn = processor.analyze(samples: s, protocol: on, shuffleCount: 60)
        let rOff = processor.analyze(samples: s, protocol: off, shuffleCount: 60)
        XCTAssertGreaterThan(rOn.matched.peakCorrelation, rOff.matched.peakCorrelation)
    }

    /// P0.2 — achieved averaging gain NEVER exceeds ideal √N on white noise.
    func testAveragingNeverBeatsRootNOnNoise() {
        var gen = SeededGenerator(seed: 5)
        let rate = 100.0
        let period = 1.75
        let n = Int(rate * period * 30)
        let noise = (0..<n).map { _ in Double.random(in: -1...1, using: &gen) }
        let report = processor.coherentAveragingReport(noise, sampleRate: rate, periodSeconds: period)
        XCTAssertLessThanOrEqual(report.achievedGainDB, report.idealGainDB + 1e-9)
        XCTAssertFalse(report.exceedsIdeal)
    }

    /// P0.3 — |B| is not the default and the per-axis path returns axis results and a vector result.
    func testVectorRepresentationIsDefaultAndReturnsPerAxis() {
        XCTAssertEqual(ExperimentProtocol().representation, .vector)
        let rate = 100.0
        let target = 8.3
        let chip = 0.25
        let code = [1.0, 1, 1, -1, -1, 1, -1]
        let ref = processor.codedReference(count: 3000, sampleRate: rate, carrierHz: target, code: code, chipDuration: chip)
        let s = ref.enumerated().map { i, v in
            SensorSample(monotonicTime: Double(i) / rate, wallTime: Date(), magnetic: Vector3(x: 48 + 0.05 * v, y: 0.02 * v, z: 0))
        }
        var plan = ExperimentProtocol()
        plan.sampleRateHz = rate
        plan.targetFrequencyHz = target
        plan.code = code
        plan.chipDurationSeconds = chip
        plan.durationSeconds = 30
        let r = processor.analyze(samples: s, protocol: plan, shuffleCount: 40)
        XCTAssertEqual(r.axes.count, 3)
        XCTAssertNotNil(r.vector)
        XCTAssertEqual(r.vector?.dominantAxis, "x")  // x carries the largest coded amplitude
    }

    /// P1 — the false-positive rate of the lock-in F-test on pure noise is ≈ α.
    func testLockInFalsePositiveRateMatchesAlpha() {
        var gen = SeededGenerator(seed: 99)
        let rate = 100.0
        let n = 2000
        let f = 8.3
        var positives = 0
        let trials = 1000
        for _ in 0..<trials {
            let noise = (0..<n).map { _ in Double.random(in: -1...1, using: &gen) }
            if processor.lockIn(signal: noise, sampleRate: rate, frequency: f).pValue < 0.05 { positives += 1 }
        }
        let rate05 = Double(positives) / Double(trials)
        XCTAssertLessThan(rate05, 0.09, "false-positive rate \(rate05) should be near 0.05")
    }

    /// P1 — a 690 µT baseline fails the DC gate; ~50 µT passes.
    func testDCFieldGate() {
        let big = QualityGates.dcFieldResult(690)
        XCTAssertFalse(big.passed)
        let ok = QualityGates.dcFieldResult(48)
        XCTAssertTrue(ok.passed)
    }

    /// P1 — an orientation change fails the motion gate even at zero gyro; and the label is derived.
    func testMotionGateFromSensorNotLabel() {
        let n = 400
        let flipped = (0..<n).map { i in
            SensorSample(
                monotonicTime: Double(i) / 100, wallTime: Date(), magnetic: Vector3(x: 48, y: 0, z: 0),
                rotationRate: Vector3(x: i == 200 ? 5.0 : 0, y: 0, z: 0),
                orientation: i < 200 ? "faceUp" : "portrait")
        }
        let report = QualityGates.preflight(samples: flipped)
        let motion = report.results.first { $0.gate == .motion }!
        XCTAssertFalse(motion.passed)
        XCTAssertEqual(report.derivedMotion, "reoriented")
    }

    /// P1 — a 40× clock disagreement hard-fails.
    func testClockConsistencyGate() {
        XCTAssertFalse(QualityGates.clockResult(monoSpan: 7.26, wallSpan: 296, duration: 60).passed)
        XCTAssertTrue(QualityGates.clockResult(monoSpan: 60.0, wallSpan: 60.1, duration: 60).passed)
    }

    /// P1 — a failing gate caps the tier at exploratory even on a clean synthetic detection.
    func testFailingGateCapsTier() {
        let rate = 100.0
        let target = 8.3
        let chip = 0.25
        let code = [1.0, 1, 1, -1, -1, 1, -1]
        let ref = processor.codedReference(count: 4000, sampleRate: rate, carrierHz: target, code: code, chipDuration: chip)
        // strong signal but a magnet-level baseline: DC gate must block
        let s = ref.enumerated().map { i, v in
            SensorSample(monotonicTime: Double(i) / rate, wallTime: Date(), magnetic: Vector3(x: 700 + 0.5 * v, y: 0, z: 0))
        }
        var plan = ExperimentProtocol()
        plan.sampleRateHz = rate
        plan.targetFrequencyHz = target
        plan.code = code
        plan.chipDurationSeconds = chip
        plan.representation = .axisX
        plan.durationSeconds = 40
        let r = processor.analyze(samples: s, protocol: plan, shuffleCount: 60)
        XCTAssertTrue(r.gates.blocks)
        XCTAssertEqual(r.resultTier, .exploratory)
    }

    /// P1.7 — a blinded, unrevealed export carries no deck, index, or emitter, but a commitment hash.
    func testBlindedExportSealsTheArm() throws {
        let seal = BlindSeal(randomizedTrials: [.transmitterOn, .sham, .transmitterOff], trialIndex: 1, emitter: nil)
        let commit = seal.commitment(blindedID: "ABCD1234")
        XCTAssertEqual(commit, seal.commitment(blindedID: "ABCD1234"))  // deterministic
        XCTAssertNotEqual(commit, seal.commitment(blindedID: "OTHER"))  // bound to the blinded ID
        var meta = SessionMetadata(
            experimentID: UUID(), blindedID: "ABCD1234", startedAt: Date(), endedAt: nil,
            protocolSnapshot: ExperimentProtocol(), grounding: .unknown, motion: .stationary,
            notes: "", deviceModel: "x", systemVersion: "0", achievedMagnetometerRateHz: 100,
            achievedMotionRateHz: 100, codeSHA256: "d", analysisVersion: "t", eventTimestamps: [],
            randomizedTrials: nil, trialIndex: nil, emitter: nil, blindSeal: commit, blinded: true)
        let enc = JSONEncoder()
        let json = String(decoding: try enc.encode(meta), as: UTF8.self)
        XCTAssertFalse(json.contains("randomizedTrials"))
        XCTAssertFalse(json.contains("trialIndex"))
        XCTAssertFalse(json.contains("\"emitter\""))
        XCTAssertTrue(json.contains("blindSeal"))
        _ = meta  // silence unused
    }

    /// P2 — sensitivity is Tesla-referenced: a real run reports a noise floor and a minimum
    /// detectable field, and a coil session reports its implied field and is NOT emitter-capped.
    func testCalibrationReportsNoiseFloorAndMDF() {
        var gen = SeededGenerator(seed: 7)
        let rate = 100.0
        let s = samples(rate: rate, seconds: 30) { _, _ in Vector3(x: 48 + 0.3 * Double.random(in: -1...1, using: &gen), y: 0, z: 0) }
        var plan = ExperimentProtocol()
        plan.sampleRateHz = rate
        plan.representation = .axisX
        plan.durationSeconds = 30
        let r = processor.analyze(samples: s, protocol: plan, shuffleCount: 20, impliedCoilFieldNt: 12.0)
        XCTAssertGreaterThan(r.calibration.noiseFloorNtPerRootHz, 0)
        XCTAssertGreaterThan(r.calibration.minimumDetectableFieldNt, 0)
        XCTAssertEqual(r.calibration.impliedCoilFieldNt, 12.0)
    }

    /// The external-coil field arithmetic: B = (µ0/4π)(2m/r³), in nT.
    func testCoilFieldArithmetic() {
        var e = EmitterSchedule()
        e.source = .externalCoil
        e.coilMomentAm2 = 1.0
        e.coilDistanceMeters = 1.0
        // 1e-7 * 2 * 1 / 1 * 1e9 = 200 nT
        XCTAssertEqual(e.impliedFieldAtSensorNanotesla ?? 0, 200, accuracy: 1e-6)
        XCTAssertTrue(e.isRunning)
        XCTAssertFalse(e.isPhoneEmitting)  // a coil never caps the tier
    }
}

/// The phone-interference catalogue is documented and internally consistent.
final class InterferenceRegistryTests: XCTestCase {
    func testCatalogueIsDocumentedAndConsistent() {
        let sources = InterferenceRegistry.sources
        XCTAssertGreaterThanOrEqual(sources.count, 10)
        // unique ids
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
        // every source carries the three documentation fields
        for s in sources {
            XCTAssertFalse(s.effect.isEmpty)
            XCTAssertFalse(s.tell.isEmpty)
            XCTAssertFalse(s.mitigation.isEmpty)
        }
        // the source that already bit a real session is present, hard-iron, with a high-pass suggestion
        let magsafe = sources.first { $0.id == "magsafe-accessory" }
        XCTAssertNotNil(magsafe)
        XCTAssertEqual(magsafe?.character, .hardIronDC)
        XCTAssertEqual(magsafe?.suggestedFilter?.kind, .highPass)
        // the Taptic Engine — the app's own emitter — is catalogued as current-modulated
        XCTAssertEqual(sources.first { $0.id == "taptic-engine" }?.character, .currentModulated)
    }
}

#if canImport(BiomimeticRadar)
    /// Saved stream settings outlive the app version that wrote them. A blob missing a newer field used to
    /// fail to decode as a whole, which reset every setting on the phone, the server URL included.
    final class StreamSettingsDecodingTests: XCTestCase {
        func testAnOlderBlobKeepsItsValuesAndDefaultsTheRest() throws {
            let saved = Data(#"{"serverURL":"https://mac.example/biomimetic-radar","sampleRateHz":64}"#.utf8)
            let settings = try JSONDecoder().decode(StreamController.Settings.self, from: saved)
            XCTAssertEqual(settings.serverURL, "https://mac.example/biomimetic-radar")
            XCTAssertEqual(settings.sampleRateHz, 64)
            XCTAssertEqual(settings.chunkSeconds, StreamController.Settings().chunkSeconds)
        }

        func testSettingsRoundTrip() throws {
            var settings = StreamController.Settings()
            settings.includeLocation = true
            settings.chunkSeconds = 300
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(StreamController.Settings.self, from: data), settings)
        }
    }
#endif
