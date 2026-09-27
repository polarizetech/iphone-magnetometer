import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// The band registry, the nested-signal test, the reference-signal catalogue and the emitter.
/// Together they answer one question the project could not answer before: *is there anything to
/// look for, and could this rig see it.*
final class BandAndCouplingTests: XCTestCase {

    // MARK: - registry

    func testELFBandsComeFirstAndNothingIsExcludedByDefault() {
        XCTAssertFalse(BandRegistry.elf.isEmpty)
        XCTAssertTrue(
            BandRegistry.elf.allSatisfy { $0.highHz <= 40 },
            "the ELF set is 0–40 Hz; anything above belongs to the anthropogenic ranks")
        XCTAssertTrue(
            BandRegistry.bands.allSatisfy { $0.defaultPolicy != .excluded },
            "no band may start life excluded — that decision is the operator's")
        // The bands the project is actually about are all present.
        for id in ["schumann-1", "pc1", "cardiac", "human-alpha", "mains-60"] {
            XCTAssertNotNil(BandRegistry.band(id), "missing band \(id)")
        }
    }

    /// Every band carries what it is worth and what it costs to believe.
    func testEveryBandStatesItsExpectedAmplitudeWithATier() {
        for band in BandRegistry.bands {
            XCTAssertFalse(band.origin.isEmpty, "\(band.id) has no stated origin")
            XCTAssertTrue(
                band.expectedAmplitude.contains("["),
                "\(band.id)'s expected amplitude carries no evidence tier")
        }
    }

    /// The finding that drove the default sample rate: at 50 Hz, 60 Hz mains folds INTO the human
    /// alpha band. Whatever else this instrument does, it must not report grid power as alpha.
    func testMainsFoldsIntoTheHumanAlphaBandAt50Hz() {
        let mains = try! XCTUnwrap(BandRegistry.band("mains-60"))
        let alpha = try! XCTUnwrap(BandRegistry.band("human-alpha"))
        let at50 = BandRegistry.visibility(of: mains, sampleRateHz: 50, targetHz: 8.3)
        XCTAssertEqual(at50.visibility, .folded)
        XCTAssertEqual(at50.apparentCentreHz, 10.0, accuracy: 0.01)
        XCTAssertTrue(alpha.contains(at50.apparentCentreHz), "60 Hz lands inside 8–13 Hz at 50 Hz sampling")

        // At 100 Hz it lands at 40 Hz — clear of every ELF band.
        let at100 = BandRegistry.visibility(of: mains, sampleRateHz: 100, targetHz: 8.3)
        XCTAssertEqual(at100.apparentCentreHz, 40.0, accuracy: 0.01)
        XCTAssertFalse(BandRegistry.elf.contains { $0.contains(at100.apparentCentreHz) })
    }

    /// The rate advice is computed from the catalogue, not chosen.
    func testRecommendedRateKeepsAnthropogenicBandsAwayFromTheTarget() {
        let advice = BandRegistry.recommendedRate(targetHz: 8.3)
        XCTAssertGreaterThanOrEqual(advice.rate, 40)
        for band in BandRegistry.bands where band.family == .anthropogenic {
            let apparent = SignalCensus.aliasOf(band.centreHz, sampleRateHz: advice.rate)
            XCTAssertGreaterThan(
                abs(apparent - 8.3), 4,
                "\(band.label) lands too close to the target at the recommended rate")
        }
    }

    // MARK: - nested signals

    /// A carrier whose amplitude is modulated by a slow band IS found — and this is the whole reason
    /// mains is kept rather than notched out.
    ///
    /// The modulator is present in the record in its own right as well as in the sidebands, because
    /// that is what a real slow field does and because phase-amplitude coupling needs it: a
    /// modulator visible only as sidebands leaves nothing to take a phase reference from.
    func testAPlantedNestedSignalIsFound() {
        let rate = 100.0
        let n = 8192
        // The modulator is three incommensurate tones inside the cardiac band rather than one.
        // A strictly periodic modulator inflates the circular-shift null — shifting it often
        // re-aligns it with itself — which is the same mechanism the offline epoch test found for
        // periodic event trains. An irregular modulator is both more realistic and more detectable,
        // and the difference is measured: 3.4 null SD for a single tone, >6 for this.
        let signal = (0..<n).map { index -> Double in
            let t = Double(index) / rate
            let modulator: Double =
                (sin(2 * .pi * 1.30 * t)
                    + sin(2 * .pi * 0.91 * t + 1.0)
                    + sin(2 * .pi * 2.17 * t + 2.0)) / 3
            let envelope: Double = 1 + 0.8 * modulator
            return envelope * sin(2 * .pi * 60.0 * t) + 0.5 * modulator
        }
        let slow = try! XCTUnwrap(BandRegistry.band("cardiac"))
        let fast = try! XCTUnwrap(BandRegistry.band("mains-60"))
        let result = CrossBandCoupling.couple(signal: signal, sampleRateHz: rate, slow: slow, fast: fast)
        XCTAssertTrue(result.admissible, result.verdict)
        XCTAssertGreaterThan(try XCTUnwrap(result.effectInNullSD), 4, result.verdict)
        XCTAssertLessThan(try XCTUnwrap(result.pValue), 0.02, result.verdict)
        XCTAssertGreaterThan(
            try XCTUnwrap(result.modulatorAmplitude), 0.1,
            "the modulator has to be present for its phase to mean anything")
        // It must also say that the carrier it measured was folded, because it was.
        XCTAssertTrue(result.verdict.contains("folded"), result.verdict)
    }

    /// The same carrier with no modulation returns nothing — and specifically returns NO effect
    /// size, because a z-score against a null with no width is a big number made of nothing.
    func testAnUnmodulatedCarrierReturnsNothing() {
        let rate = 100.0
        let n = 8192
        let signal = (0..<n).map { index -> Double in
            let t = Double(index) / rate
            return sin(2 * .pi * 60.0 * t) + 0.5 * sin(2 * .pi * 1.3 * t)
        }
        let slow = try! XCTUnwrap(BandRegistry.band("cardiac"))
        let fast = try! XCTUnwrap(BandRegistry.band("mains-60"))
        let result = CrossBandCoupling.couple(signal: signal, sampleRateHz: rate, slow: slow, fast: fast)
        XCTAssertTrue(result.admissible)
        if let effect = result.effectInNullSD {
            XCTAssertLessThan(effect, 4, result.verdict)
        } else {
            XCTAssertTrue(result.verdict.contains("No measurable modulation"), result.verdict)
            XCTAssertTrue(result.verdict.contains("made of nothing"), result.verdict)
        }
    }

    /// The refusal bought by `elf-structure-reader`: modes too close together cannot be tested for
    /// coupling from one sensor, because the amplitude band contains the neighbour.
    func testNeighbouringBandsAreRefusedRatherThanScored() {
        let slow = try! XCTUnwrap(BandRegistry.band("schumann-1"))
        let fast = try! XCTUnwrap(BandRegistry.band("schumann-3"))
        let signal = (0..<8192).map { sin(2 * .pi * 20.8 * Double($0) / 100) }
        let result = CrossBandCoupling.couple(signal: signal, sampleRateHz: 100, slow: slow, fast: fast)
        XCTAssertFalse(result.admissible)
        XCTAssertTrue(result.verdict.contains("Refused"))
        XCTAssertNil(result.modulationIndex)
    }

    /// Pairing is driven by the policies, so the operator's toggles decide what is tested.
    func testPolicyDecidesWhichPairsAreTried() {
        var policies = BandRegistry.defaultPolicies
        XCTAssertFalse(
            CrossBandCoupling.pairs(policies: policies).isEmpty,
            "mains defaults to CARRIER, so pairs exist out of the box")
        for id in policies.keys where policies[id] == .carrier { policies[id] = .context }
        XCTAssertTrue(
            CrossBandCoupling.pairs(policies: policies).isEmpty,
            "with no carrier declared there is nothing to nest in")
    }

    // MARK: - reference signals

    /// The catalogue's job is to be honest about what cannot be seen, not to be encouraging.
    func testReferenceCatalogueIsHonestAboutReach() {
        let floor = 0.15  // µT — a plausible phone magnetometer floor
        let assessments = Dictionary(
            uniqueKeysWithValues: ReferenceSignals.sources.map {
                ($0.id, ReferenceSignals.assess($0, sampleRateHz: 100, noiseFloorMicrotesla: floor))
            })
        XCTAssertEqual(assessments["schumann"]?.reach, .outOfReach)
        XCTAssertEqual(assessments["pc1"]?.reach, .outOfReach)
        XCTAssertEqual(assessments["vlf-transmitters"]?.reach, .outOfReach)
        // And VLF is refused for the RIGHT reason: bandwidth, not amplitude.
        XCTAssertTrue(try XCTUnwrap(assessments["vlf-transmitters"]?.reason).contains("analogue bandwidth"))
        XCTAssertTrue(try XCTUnwrap(assessments["vlf-transmitters"]?.reason).contains("does not alias"))
        // Mains is the one that can actually be used, and it says it is folded.
        XCTAssertTrue(assessments["mains"]?.folded == true)
    }

    func testNoFloorMeansNoVerdict() {
        for source in ReferenceSignals.sources where source.frequencyHz < 1000 {
            let assessment = ReferenceSignals.assess(source, sampleRateHz: 100, noiseFloorMicrotesla: nil)
            XCTAssertEqual(assessment.reach, .undetermined, source.id)
            XCTAssertTrue(assessment.reason.contains("not the same as promising"))
        }
        // With nothing measured, the honest recommendation is the one we control.
        let recommended = ReferenceSignals.recommended(sampleRateHz: 100, noiseFloorMicrotesla: nil)
        XCTAssertEqual(recommended?.source.id, "self-emitter")
    }

    // MARK: - the emitter

    /// The emitter's drive IS the matched filter's reference, so a detection is a detection of the
    /// thing being searched for rather than of something adjacent.
    func testEmitterDriveMatchesTheMatchedFilterReference() {
        let schedule = EmitterSchedule(
            transducer: .haptics, carrierHz: 8.3,
            code: [1, 1, 1, -1, -1, 1, -1], chipSeconds: 0.25, amplitude: 1.0)
        let rate = 100.0
        let reference = SignalProcessor().codedReference(
            count: 500, sampleRate: rate, carrierHz: 8.3,
            code: [1, 1, 1, -1, -1, 1, -1], chipDuration: 0.25)
        for index in 0..<500 {
            XCTAssertEqual(schedule.drive(at: Double(index) / rate), reference[index], accuracy: 1e-12)
        }
    }

    /// A transducer that cannot go negative gets the code as amplitude around a mid-level, which is
    /// bipolar again after the analysis detrends it.
    func testUnipolarDriveStaysInRangeAndKeepsTheCode() {
        let schedule = EmitterSchedule(transducer: .haptics, amplitude: 1.0)
        let samples = (0..<400).map { schedule.unipolarDrive(at: Double($0) / 100) }
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
        let mean = samples.reduce(0, +) / Double(samples.count)
        let centred = samples.map { $0 - mean }
        XCTAssertGreaterThan(centred.max() ?? 0, 0.3)
        XCTAssertLessThan(centred.min() ?? 0, -0.3)
    }

    func testEmitterOffMeansOff() {
        let schedule = EmitterSchedule()
        XCTAssertEqual(schedule.transducer, .none)
        XCTAssertFalse(schedule.isRunning)
        XCTAssertTrue(EmitterSchedule.firewall.contains("never support a claim about an external signal"))
    }

    func testRequiredAmplitudeNeedsAMeasuredFloor() {
        XCTAssertNil(EmitterSchedule.requiredAmplitudeMicrotesla(noiseFloorMicrotesla: nil))
        XCTAssertEqual(
            try XCTUnwrap(EmitterSchedule.requiredAmplitudeMicrotesla(noiseFloorMicrotesla: 0.2)),
            0.6, accuracy: 1e-9)
    }
}
