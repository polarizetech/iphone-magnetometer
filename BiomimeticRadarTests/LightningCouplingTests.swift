import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// These pin the arithmetic that decides whether a lightning-mode session is worth running at all.
/// Every one of them is a refusal or an order-of-magnitude check, not a curve fit.
final class LightningCouplingTests: XCTestCase {

    /// Ampère's law against a hand calculation: 30 kA at 1 km is 6 µT, which is a large fraction of
    /// the Earth's own ~50 µT field. The field is NOT the hard part — see the next test.
    func testReturnStrokeFieldMatchesAmpere() {
        let value = LightningCoupling.returnStrokeMicrotesla(peakCurrentA: 30_000, distanceMeters: 1_000)
        XCTAssertEqual(value, 6.0, accuracy: 0.05)
        // 1/r, so ten times further is a tenth.
        let far = LightningCoupling.returnStrokeMicrotesla(peakCurrentA: 30_000, distanceMeters: 10_000)
        XCTAssertEqual(far, value / 10, accuracy: 1e-6)
    }

    /// The load-bearing result: a 100 µs return stroke into a 50 Hz sampler survives at 0.5%, so a
    /// 6 µT field arrives as 30 nT — two orders of magnitude of loss that no integration recovers,
    /// because it happened before the ADC.
    func testReturnStrokeIsDestroyedByTheSampler() {
        let surviving = LightningCoupling.survival(durationSeconds: 100e-6, sampleRateHz: 50)
        XCTAssertEqual(surviving, 0.005, accuracy: 1e-9)
        let arrivals = LightningCoupling.arrivals(
            distanceMeters: 1_000, sampleRateHz: 50,
            noiseFloorMicrotesla: 0.2)
        let stroke = try! XCTUnwrap(arrivals.first { $0.name.contains("Return-stroke") })
        XCTAssertEqual(stroke.peakMicrotesla, 6.0, accuracy: 0.05)
        XCTAssertEqual(stroke.deliveredMicrotesla, 0.03, accuracy: 0.001)
        XCTAssertEqual(stroke.reach, .outOfReach)
        XCTAssertTrue(stroke.reason.contains("Unresolvable"))
    }

    /// The continuing current is 300× weaker as a field and still the ONLY arrival that can reach a
    /// sample, because it is slow. Size and timescale are separate questions and the code keeps them so.
    func testContinuingCurrentIsTheOnlyOneTheBandwidthAllows() {
        let arrivals = LightningCoupling.arrivals(
            distanceMeters: 300, sampleRateHz: 50,
            noiseFloorMicrotesla: 0.005)
        let continuing = try! XCTUnwrap(arrivals.first { $0.name.contains("Continuing") })
        XCTAssertEqual(continuing.survivingFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(continuing.peakMicrotesla, 0.0667, accuracy: 0.001)
        XCTAssertEqual(continuing.reach, .withinReach)
    }

    /// The Schumann transient the 8.3 Hz target would actually be listening for is ~1 pT, which is
    /// ~5 orders below a good phone magnetometer floor. This test exists so that number can never
    /// quietly disappear from the app.
    func testCavityRingingIsOutOfReachByFiveOrdersOfMagnitude() {
        let arrivals = LightningCoupling.arrivals(
            distanceMeters: 500_000, sampleRateHz: 50,
            noiseFloorMicrotesla: 0.15)
        let cavity = try! XCTUnwrap(arrivals.first { $0.name.contains("Cavity") })
        XCTAssertEqual(cavity.peakMicrotesla, 1e-6, accuracy: 1e-12)
        XCTAssertEqual(cavity.reach, .outOfReach)
        let margin = try! XCTUnwrap(cavity.marginVersusNoise)
        XCTAssertLessThan(margin, 1e-5)
    }

    /// No measured noise floor, no verdict. The same rule `eeg-bridge.noise_budget.budget()` enforces:
    /// a permissive default here would be an instrument that always says yes.
    func testNoNoiseFloorYieldsUndeterminedRatherThanReassurance() {
        for arrival in LightningCoupling.arrivals(distanceMeters: 1_000, sampleRateHz: 50) {
            XCTAssertEqual(arrival.reach, .undetermined)
            XCTAssertNil(arrival.marginVersusNoise)
            XCTAssertTrue(arrival.reason.contains("not an estimate that it is fine"))
        }
        XCTAssertNil(LightningCoupling.equalNoiseDistanceMeters(sampleRateHz: 50, noiseFloorMicrotesla: nil))
    }

    /// A faster sampler moves the return-stroke verdict, which is the actionable half of all this:
    /// the limit is bandwidth, so the fix is bandwidth, not dwell.
    func testSurvivalScalesWithSampleRate() {
        XCTAssertEqual(LightningCoupling.survival(durationSeconds: 100e-6, sampleRateHz: 100), 0.01, accuracy: 1e-9)
        XCTAssertEqual(LightningCoupling.survival(durationSeconds: 100e-6, sampleRateHz: 10_000), 1.0, accuracy: 1e-9)
    }

    /// The NWS validTime interval reader, which decides which forecast block "now" falls in.
    func testISOIntervalParsing() {
        let parsed = ISOInterval.parse("2026-08-22T12:00:00+00:00/PT3H")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.end.timeIntervalSince(parsed!.start), 10_800, accuracy: 0.001)
        XCTAssertEqual(ISOInterval.duration("P1DT6H"), 108_000, accuracy: 0.001)
        // `M` before the T is months, after it is minutes. Confusing these shifts a forecast by weeks.
        XCTAssertEqual(ISOInterval.duration("PT30M"), 1_800, accuracy: 0.001)
        XCTAssertEqual(ISOInterval.duration("P1M"), 2_592_000, accuracy: 0.001)
        XCTAssertNil(ISOInterval.parse("2026-08-22T12:00:00+00:00"))
    }
}
