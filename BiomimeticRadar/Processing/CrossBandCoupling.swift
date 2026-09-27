import Foundation

/// Is something quiet riding on something loud?
///
/// This is the test that makes keeping mains, drift and every other "noise" band worthwhile. A
/// notch filter answers the question *is the target band clean* and forecloses the question *is the
/// target band modulating something else*. Phase-amplitude coupling answers the second: does the
/// phase of a slow band predict the amplitude of a fast one.
///
/// The statistic is the **Tort modulation index** (Tort et al. 2010) against a **circular-shift
/// surrogate null**, because a
/// magnetometer trace is heavily autocorrelated and an unstructured shuffle would make almost
/// anything significant.
///
/// **Three refusals, and two of them were bought by another project's mistakes.**
///
/// 1. `projects/elf-structure-reader` established that **the Schumann modes are too closely spaced
///    for phase-amplitude coupling between them to be measurable from one sensor**: the amplitude
///    band needed to see modulation of one mode contains its neighbours, so modulation and mode
///    beating cannot be separated. Any pair whose amplitude band contains more than one known band
///    centre is refused rather than scored.
/// 2. **A p-value is not an effect size.** Both are returned, and the verdict wording leads with the
///    effect. That project found a pure sawtooth scoring p = 0.038 against a real surrogate test.
/// 3. **The fast band must sit above twice the slow band's top**, or the "modulator" and the
///    "carrier" share energy and the index measures the overlap rather than any coupling.
struct CrossBandCoupling: Sendable {

    struct Result: Codable, Sendable, Identifiable, Equatable {
        var id: String { "\(slowBandID)->\(fastBandID)" }
        let slowBandID: String
        let fastBandID: String
        let slowLabel: String
        let fastLabel: String
        /// Tort modulation index in [0, 1]. `nil` when the pair was refused.
        let modulationIndex: Double?
        /// Mean envelope amplitude of the SLOW band, in the record's own units.
        ///
        /// Read it before the index. Phase-amplitude coupling takes its phase reference from the
        /// slow band being *present in the record*, and a modulator that exists only as sidebands
        /// around the carrier leaves nothing to take a phase from — the test then measures the
        /// phase of noise. A near-zero value here means the index below is meaningless whatever it says.
        let modulatorAmplitude: Double?
        /// Where the observed index sits in its surrogate null, in null standard deviations.
        let effectInNullSD: Double?
        let pValue: Double?
        let surrogates: Int
        let admissible: Bool
        /// Always populated: either the verdict or the reason for refusing.
        let verdict: String
    }

    /// Number of phase bins. 18 is the common choice for the Tort modulation index.
    static let phaseBins = 18

    /// Below this, a Tort index is numerical noise rather than weak coupling. Published PAC effects
    /// sit between roughly 1e-3 and 1e-1; 1e-5 is two orders below anything anyone reports.
    static let minimumMeaningfulIndex = 1e-5

    static func couple(
        signal: [Double], sampleRateHz rate: Double,
        slow: BandRegistry.Band, fast: BandRegistry.Band,
        surrogates: Int = 200, seed: UInt64 = 0x5EEDB0D
    ) -> Result {
        func refuse(_ reason: String) -> Result {
            Result(
                slowBandID: slow.id, fastBandID: fast.id, slowLabel: slow.label,
                fastLabel: fast.label, modulationIndex: nil, modulatorAmplitude: nil,
                effectInNullSD: nil, pValue: nil, surrogates: 0, admissible: false, verdict: reason)
        }

        // Both bands are searched WHERE THEY ACTUALLY APPEAR, which for mains is never where it is.
        //
        // Undersampling a carrier does not destroy its amplitude envelope — that is bandpass
        // sampling, and it is why this test is possible at all on hardware that tops out at 100 Hz
        // and can never see 60 Hz directly. The carrier's sidebands fold with it, mirrored: the
        // ORDER of the sidebands inverts, which changes nothing for an amplitude envelope. If this
        // test were about phase or sideband asymmetry it would be invalid, and it is not.
        let slowSeen = BandRegistry.visibility(of: slow, sampleRateHz: rate, targetHz: 0)
        let fastSeen = BandRegistry.visibility(of: fast, sampleRateHz: rate, targetHz: 0)
        guard slowSeen.visibility != .smeared, fastSeen.visibility != .smeared else {
            return refuse(
                "Refused: at \(String(format: "%.0f", rate)) Hz one of these bands folds onto several stretches of the spectrum at once, so it has no envelope of its own to measure."
            )
        }
        let slowLow = max(0.01, slowSeen.apparentCentreHz - slow.widthHz / 2)
        let slowHigh = slowSeen.apparentCentreHz + slow.widthHz / 2
        let fastLow = fastSeen.apparentCentreHz - fast.widthHz / 2
        let fastHigh = fastSeen.apparentCentreHz + fast.widthHz / 2

        let nyquist = rate / 2
        guard fastHigh < nyquist, fastLow > 0 else {
            return refuse("Refused: the \(fast.label) band does not fit inside the sampled spectrum at \(String(format: "%.0f", rate)) Hz.")
        }
        guard fastLow > 2 * slowHigh else {
            return refuse(
                "Refused: as they APPEAR at this sample rate, the bands are too close (\(String(format: "%.2f", fastLow)) Hz vs a modulator topping out at \(String(format: "%.2f", slowHigh)) Hz). A carrier must sit above twice the modulator's top edge, or the index measures their overlap rather than any coupling."
            )
        }
        // The amplitude band a modulation search needs is fast ± slow.high. If that contains another
        // band's apparent location, modulation and beating between them are unseparable.
        let amplitudeLow = fastLow - slowHigh
        let amplitudeHigh = fastHigh + slowHigh
        let occupants = BandRegistry.bands.filter { other in
            guard other.id != fast.id, other.id != slow.id else { return false }
            let seen = BandRegistry.visibility(of: other, sampleRateHz: rate, targetHz: 0)
            guard seen.visibility != .smeared else { return false }
            return seen.apparentCentreHz >= amplitudeLow && seen.apparentCentreHz <= amplitudeHigh
        }
        if !occupants.isEmpty {
            return refuse(
                "Refused: the amplitude band this search needs (\(String(format: "%.2f–%.2f", amplitudeLow, amplitudeHigh)) Hz as sampled) also contains \(occupants.map(\.label).joined(separator: ", ")). Modulation and beating between neighbours are unseparable from one sensor — elf-structure-reader established this for the Schumann modes, and the same arithmetic applies here."
            )
        }
        // The carrier's envelope lives in its SIDEBANDS, at fast ± the modulation frequency. Pulling
        // the envelope from the carrier band alone excludes exactly the thing being measured — the
        // first version did that and reported nothing for a record modulated 80% deep. The fast
        // band is therefore extracted over the full amplitude band, which is also the band the
        // occupancy check above just cleared.
        guard
            let slowAnalytic = FFT.analyticBand(
                signal, sampleRateHz: rate,
                lowHz: slowLow, highHz: slowHigh),
            let fastAnalytic = FFT.analyticBand(
                signal, sampleRateHz: rate,
                lowHz: max(0.01, amplitudeLow), highHz: amplitudeHigh)
        else {
            return refuse("Refused: the record is too short to resolve both bands.")
        }

        let phase = slowAnalytic.phase
        let amplitude = fastAnalytic.envelope
        let observed = modulationIndex(phase: phase, amplitude: amplitude)
        let modulatorAmplitude = slowAnalytic.envelope.reduce(0, +) / Double(max(1, slowAnalytic.envelope.count))

        var generator = SeededGenerator(seed: seed)
        var nulls: [Double] = []
        nulls.reserveCapacity(surrogates)
        let n = amplitude.count
        for _ in 0..<surrogates {
            let shift = Int.random(in: (n / 20)...(n - n / 20), using: &generator)
            let shifted = Array(amplitude[shift...] + amplitude[..<shift])
            nulls.append(modulationIndex(phase: phase, amplitude: shifted))
        }
        let nullMean = nulls.reduce(0, +) / Double(nulls.count)
        let nullSD = sqrt(nulls.reduce(0.0) { $0 + ($1 - nullMean) * ($1 - nullMean) } / Double(max(1, nulls.count - 1)))
        let exceed = nulls.filter { $0 >= observed }.count
        let p = Double(exceed + 1) / Double(nulls.count + 1)
        let effect = nullSD > 0 ? (observed - nullMean) / nullSD : Double.nan

        // An effect size is a ratio, and a ratio against a null with almost no spread explodes. An
        // unmodulated pure carrier produces exactly that: every surrogate returns essentially the
        // same near-zero index, and the first version reported it as 21 null SD — a huge effect
        // made of nothing. A modulation index below the numerical floor is no modulation, whatever
        // the z-score says, and that check comes first.
        if observed < minimumMeaningfulIndex {
            return Result(
                slowBandID: slow.id, fastBandID: fast.id, slowLabel: slow.label,
                fastLabel: fast.label, modulationIndex: observed,
                modulatorAmplitude: modulatorAmplitude, effectInNullSD: nil,
                pValue: p, surrogates: surrogates, admissible: true,
                verdict: String(
                    format:
                        "No measurable modulation: MI %.2e is below the %.0e floor this test can resolve. The surrogate spread at this level is numerical noise, so no effect size is offered — a large z against a null with no width is a big number made of nothing.",
                    observed, minimumMeaningfulIndex))
        }
        let modulatorNote = String(
            format:
                " Modulator amplitude in the %@ band: %.3g — if that is at the record's noise level, the phase reference is noise and the index above means nothing.",
            slow.label, modulatorAmplitude)
        let foldNote =
            fastSeen.visibility == .folded
            ? String(
                format:
                    " The carrier is folded: %.1f Hz appears at %.1f Hz here. Its envelope survives undersampling, its sideband order does not — which matters for a phase claim and not for this one.",
                fast.centreHz, fastSeen.apparentCentreHz)
            : ""

        let verdict: String
        if effect.isFinite && effect >= 4 && p <= 0.01 {
            verdict =
                String(
                    format:
                        "%.1f null SD above its surrogates (MI %.2e, p %.4f). Read the effect size first: this is a large one. It is still a statement about THIS record, and a nested signal claim needs it to repeat.",
                    effect, observed, p) + foldNote + modulatorNote
        } else if effect.isFinite && effect >= 2 {
            verdict =
                String(
                    format:
                        "%.1f null SD above its surrogates (MI %.2e, p %.4f). Suggestive and no more — this size of effect appears routinely in autocorrelated records.",
                    effect, observed, p) + foldNote + modulatorNote
        } else {
            verdict =
                String(
                    format:
                        "Nothing: %.1f null SD (MI %.2e, p %.4f). The slow band's phase does not predict the fast band's amplitude in this record.",
                    effect, observed, p) + foldNote + modulatorNote
        }

        return Result(
            slowBandID: slow.id, fastBandID: fast.id, slowLabel: slow.label,
            fastLabel: fast.label, modulationIndex: observed,
            modulatorAmplitude: modulatorAmplitude,
            effectInNullSD: effect.isFinite ? effect : nil, pValue: p,
            surrogates: surrogates, admissible: true, verdict: verdict)
    }

    /// Tort modulation index: `(log N − H(P)) / log N`, 0 = flat, 1 = all amplitude in one phase bin.
    static func modulationIndex(phase: [Double], amplitude: [Double]) -> Double {
        let n = min(phase.count, amplitude.count)
        guard n > phaseBins * 4 else { return 0 }
        var sums = [Double](repeating: 0, count: phaseBins)
        var counts = [Int](repeating: 0, count: phaseBins)
        for index in 0..<n {
            let normalised: Double = (phase[index] + Double.pi) / (2 * Double.pi)
            let bin = min(phaseBins - 1, max(0, Int(normalised * Double(phaseBins))))
            sums[bin] += amplitude[index]
            counts[bin] += 1
        }
        var means = [Double](repeating: 0, count: phaseBins)
        for bin in 0..<phaseBins where counts[bin] > 0 {
            means[bin] = sums[bin] / Double(counts[bin])
        }
        let total = means.reduce(0, +)
        guard total > 0 else { return 0 }
        var entropy = 0.0
        for bin in 0..<phaseBins {
            let probability = means[bin] / total
            if probability > 0 { entropy -= probability * log(probability) }
        }
        return (log(Double(phaseBins)) - entropy) / log(Double(phaseBins))
    }

    /// Every admissible pair under the current policies: `.watch` bands modulate `.carrier` bands.
    static func pairs(policies: [String: BandRegistry.Policy]) -> [(slow: BandRegistry.Band, fast: BandRegistry.Band)] {
        let watched = BandRegistry.bands.filter { policies[$0.id] == .watch }
        let carriers = BandRegistry.bands.filter { policies[$0.id] == .carrier }
        var out: [(BandRegistry.Band, BandRegistry.Band)] = []
        for slow in watched {
            for fast in carriers where fast.lowHz > 2 * slow.highHz {
                out.append((slow, fast))
            }
        }
        return out
    }
}
