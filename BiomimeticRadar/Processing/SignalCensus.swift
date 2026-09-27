import Foundation

/// What is actually in this recording, broken out by source — and, where a source cannot be named,
/// an honest anonymous entry instead of a guess.
///
/// **The rule this file exists to enforce: every unit of measured power is accounted for.** A
/// spectrum with the target frequency circled tells you nothing about the other 99% of what the
/// sensor returned. So the census assigns every spectral bin to exactly one component, the shares
/// sum to 1, and whatever cannot be attributed lands in numbered `U-nn` entries and an
/// `unattributed` remainder that is displayed as prominently as anything else.
///
/// **Naming is earned, never assumed.** A component is `.attributed` only when something in *this*
/// record supports it (the DC level is the standing field because it is a standing level; a line is
/// the target because we asked for it there). Everything else is `.suspected` — plausible, with the
/// discriminator that would settle it printed beside it — or `.unattributed`, which is a real
/// finding and not a failure.
///
/// **Two budgets, never merged.** The spectral budget partitions variance by frequency and sums to
/// 1. Motion coupling is *cross-cutting*: rotating a phone in the Earth's 50 µT field writes signal
/// across the whole band, so its share overlaps the spectral slices and adding the two together
/// would double-count. They are returned separately and the UI may not stack them.
struct SignalCensus: Sendable {

    enum Status: String, Codable, Sendable {
        /// Something in this record supports the name.
        case attributed
        /// Plausible and consistent with the record, but not established. `discriminator` says how to settle it.
        case suspected
        /// Real power with no name. The point of the exercise, not a gap in it.
        case unattributed
    }

    struct Component: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let label: String
        let status: Status
        /// Share of the AC variance. The spectral components sum to 1.
        let fraction: Double
        /// RMS amplitude in microtesla carried by this component.
        let amplitudeMicrotesla: Double
        let centreHz: Double?
        let bandwidthHz: Double?
        /// How far above the local spectral floor, in dB. `nil` for wideband components.
        let prominenceDB: Double?
        /// Change in this component's power between the first and second half of the record, in dB.
        /// A large number means it came or went during the run.
        let driftDB: Double?
        /// What in THIS record supports the entry.
        let evidence: String
        /// The cheapest next measurement that would confirm or kill it.
        let discriminator: String
    }

    struct MotionCoupling: Codable, Sendable, Equatable {
        /// Fraction of AC variance a linear fit on |rotation| and |acceleration| explains.
        /// `nil` when the phone did not move enough for the question to be answerable.
        let varianceExplained: Double?
        let rotationRangeRadPerS: Double
        let accelerationRangeG: Double
        let verdict: String
    }

    struct Result: Codable, Sendable, Equatable {
        let sampleRateHz: Double
        let resolutionHz: Double
        let durationSeconds: Double
        /// The Earth's standing field: reported on its own, in microtesla, never as a variance share.
        let standingFieldMicrotesla: Double
        let acRMSMicrotesla: Double
        let components: [Component]
        let motion: MotionCoupling
        /// Share of AC variance in no named component. Equals the sum of the `U-nn` entries plus
        /// the broadband floor.
        let unattributedFraction: Double
        /// Share of the ORIGINAL variance removed by `.excluded` policies before the budget was
        /// computed. Reported so an exclusion can never be silent.
        let excludedFraction: Double
        let policies: [String: BandRegistry.Policy]
        let notes: [String]
    }

    /// Mains frequency. 60 Hz here; a run in Europe wants 50 and the census marks both.
    static let mainsHz = 60.0
    static let alternateMainsHz = 50.0

    /// Where a real frequency lands after sampling at `rate`. A tone above Nyquist does not vanish,
    /// it folds — which is why a 60 Hz line can appear at 10 Hz on a 50 Hz recording and look
    /// exactly like something interesting near an 8.3 Hz target.
    static func aliasOf(_ frequency: Double, sampleRateHz rate: Double) -> Double {
        guard rate > 0 else { return frequency }
        let folded = frequency.truncatingRemainder(dividingBy: rate)
        return folded > rate / 2 ? rate - folded : folded
    }

    /// True when `frequency` is above Nyquist and therefore appears somewhere it is not.
    static func isAliased(_ frequency: Double, sampleRateHz rate: Double) -> Bool {
        frequency > rate / 2
    }

    // MARK: - the census

    static func census(
        samples: [SensorSample], sampleRateHz rate: Double,
        targetHz: Double, targetBandwidthHz: Double = 1.0,
        policies: [String: BandRegistry.Policy] = BandRegistry.defaultPolicies
    ) -> Result {
        let magnitude = samples.map(\.magnetic.magnitude)
        guard magnitude.count >= 64, rate > 0 else {
            return Result(
                sampleRateHz: rate, resolutionHz: 0, durationSeconds: 0,
                standingFieldMicrotesla: magnitude.first ?? 0, acRMSMicrotesla: 0,
                components: [],
                motion: MotionCoupling(
                    varianceExplained: nil, rotationRangeRadPerS: 0, accelerationRangeG: 0,
                    verdict: "Too few samples to census. At least 64 are needed."),
                unattributedFraction: 1, excludedFraction: 0, policies: policies,
                notes: ["Record too short to decompose."])
        }

        let standing = magnitude.reduce(0, +) / Double(magnitude.count)
        let ac = detrend(magnitude)
        let acRMS = rms(ac)
        let (freqs, power) = FFT.spectrum(ac, sampleRateHz: rate)
        guard !power.isEmpty else {
            return Result(
                sampleRateHz: rate, resolutionHz: 0, durationSeconds: 0,
                standingFieldMicrotesla: standing, acRMSMicrotesla: acRMS,
                components: [], motion: motionCoupling(samples: samples, ac: ac),
                unattributedFraction: 1, excludedFraction: 0, policies: policies,
                notes: ["Spectrum unavailable for this record length."])
        }
        let n = power.count * 2
        let resolution = rate / Double(n)
        let grossPower = power.reduce(0, +)

        var claimed = Array(repeating: false, count: power.count)
        var components: [Component] = []
        var notes: [String] = []

        // 0. Exclusions come out of the denominator FIRST, and are reported. Nothing is excluded by
        //    default; this only runs when the operator has chosen it.
        var excludedPower = 0.0
        for band in BandRegistry.bands where policies[band.id] == .excluded {
            let apparent = aliasOf(band.centreHz, sampleRateHz: rate)
            let half = min(band.widthHz / 2, rate / 4)
            let indices = freqs.indices.filter { !claimed[$0] && abs(freqs[$0] - apparent) <= half }
            guard !indices.isEmpty else { continue }
            excludedPower += indices.reduce(0.0) { $0 + power[$1] }
            indices.forEach { claimed[$0] = true }
            notes.append(
                "Excluded by policy: \(band.label). Its power is out of the budget below, and the budget therefore describes a filtered record."
            )
        }
        let totalPower = max(1e-30, grossPower - excludedPower)

        func share(_ indices: [Int]) -> Double {
            indices.reduce(0.0) { $0 + power[$1] } / totalPower
        }
        func amplitude(_ fraction: Double) -> Double { acRMS * sqrt(max(0, fraction)) }

        // 1. The target band claims first — it is narrower than the natural bands it sits inside,
        //    and it is the one band the experiment chose.
        let targetBins = freqs.indices.filter { !claimed[$0] && abs(freqs[$0] - targetHz) <= targetBandwidthHz / 2 }
        if !targetBins.isEmpty {
            let fraction = share(targetBins)
            targetBins.forEach { claimed[$0] = true }
            let host = BandRegistry.bands.first { $0.contains(targetHz) }
            components.append(
                Component(
                    id: "target", label: String(format: "Target band · %.2f Hz", targetHz),
                    status: .attributed, fraction: fraction, amplitudeMicrotesla: amplitude(fraction),
                    centreHz: targetHz, bandwidthHz: targetBandwidthHz,
                    prominenceDB: prominence(power, freqs: freqs, centre: targetHz, resolution: resolution),
                    driftDB: halfSplitDB(ac, rate: rate, centre: targetHz, halfWidth: targetBandwidthHz / 2),
                    evidence:
                        "This is where the protocol asked us to look. Power being here is NOT evidence of the coded signal — the matched filter and its permutation null answer that, not this census."
                        + (host.map { " It sits inside \($0.label), which is claimed around it." } ?? ""),
                    discriminator:
                        "The coded matched filter on the Analyze tab. A band with power and no code correlation is something else in the same band."
                ))
        }

        // 2. Every known band. **Folded bands claim first**, then ELF priority.
        //
        //    The order matters and was got wrong once. A folded band is an intruder sitting in
        //    another band's territory: at 50 Hz sampling, 60 Hz mains lands at 10 Hz — inside the
        //    8–13 Hz human alpha band. With ELF priority alone, alpha claimed those bins first and
        //    the census reported mains power as ALPHA. Whatever else this instrument does, it must
        //    not do that. So an aliased band takes its bins first and the resident band's entry says
        //    what was taken from it.
        let ordered = BandRegistry.bands.sorted { left, right in
            let leftFolded = BandRegistry.visibility(of: left, sampleRateHz: rate, targetHz: targetHz).visibility != .direct
            let rightFolded = BandRegistry.visibility(of: right, sampleRateHz: rate, targetHz: targetHz).visibility != .direct
            if leftFolded != rightFolded { return leftFolded }
            return left.rank < right.rank
        }
        for band in ordered {
            let policy = policies[band.id] ?? band.defaultPolicy
            guard policy != .excluded else { continue }
            let seen = BandRegistry.visibility(of: band, sampleRateHz: rate, targetHz: targetHz)

            // A band that folds onto several stretches at once gets no bins and no share. Giving it
            // a location would let it claim a swathe of spectrum it does not own — the mains
            // harmonic band did exactly that, swallowing 0–22.5 Hz at a 50 Hz rate.
            if seen.visibility == .smeared {
                components.append(
                    Component(
                        id: band.id, label: band.label + " · unlocatable at this rate",
                        status: .unattributed, fraction: 0, amplitudeMicrotesla: 0,
                        centreHz: nil, bandwidthHz: band.widthHz, prominenceDB: nil, driftDB: nil,
                        evidence: "\(band.origin) Expected: \(band.expectedAmplitude) \(seen.note)",
                        discriminator:
                            "Raise the sample rate until the band sits inside one Nyquist zone, or accept that this record cannot separate it from anything else."
                    ))
                notes.append(
                    "⚠️ \(band.label) cannot be located at \(String(format: "%.1f", rate)) Hz sampling — it folds onto several parts of the spectrum at once, so any component below could contain some of it."
                )
                continue
            }

            let half = min(band.widthHz / 2, rate / 4)
            let indices = freqs.indices.filter { !claimed[$0] && abs(freqs[$0] - seen.apparentCentreHz) <= half }
            guard !indices.isEmpty else { continue }
            let fraction = share(indices)
            let peak = prominence(power, freqs: freqs, centre: seen.apparentCentreHz, resolution: resolution)

            // A context band with no line and negligible power is left to the floor rather than
            // padding the list with fifteen near-zero rows.
            let bar = prominenceThresholdDB(binCount: power.count)
            if policy == .context && (peak ?? 0) < bar && fraction < 0.01 { continue }
            indices.forEach { claimed[$0] = true }

            // Which bands took bins that would otherwise be this one's, and how much of the range
            // is left. A band eaten by an intruder is not the same measurement as an intact one.
            let full = freqs.indices.filter { abs(freqs[$0] - seen.apparentCentreHz) <= half }
            let lostFraction = full.isEmpty ? 0 : 1 - Double(indices.count) / Double(full.count)
            let overlapping = BandRegistry.bands.filter { other in
                guard other.id != band.id else { return false }
                let otherSeen = BandRegistry.visibility(of: other, sampleRateHz: rate, targetHz: targetHz)
                guard otherSeen.visibility != .smeared else { return false }
                let otherHalf = min(other.widthHz / 2, rate / 4)
                return abs(otherSeen.apparentCentreHz - seen.apparentCentreHz) < half + otherHalf
            }
            let status: Status = (peak ?? 0) > bar ? .suspected : .unattributed
            var evidence = "\(band.origin) Expected: \(band.expectedAmplitude) \(seen.note)"
            if lostFraction > 0.05 && !overlapping.isEmpty {
                evidence += String(
                    format:
                        " %.0f%% of this band's bins were claimed by an overlapping band (%@) — folded bands claim first, then ELF priority. What is measured here is the remainder, not the whole band.",
                    lostFraction * 100, overlapping.map(\.label).joined(separator: ", ") as NSString)
            }
            if policy == .carrier {
                evidence += " Policy CARRIER: its envelope is being checked for modulation by the watched bands."
            }
            components.append(
                Component(
                    id: band.id,
                    label: band.label
                        + (seen.visibility == .direct ? "" : " · folded to \(String(format: "%.2f", seen.apparentCentreHz)) Hz"),
                    status: status, fraction: fraction, amplitudeMicrotesla: amplitude(fraction),
                    centreHz: seen.apparentCentreHz, bandwidthHz: 2 * half, prominenceDB: peak,
                    driftDB: halfSplitDB(ac, rate: rate, centre: seen.apparentCentreHz, halfWidth: half),
                    evidence: evidence,
                    discriminator: seen.visibility == .direct
                        ? "Rotate the phone 90°: a device-fixed source turns with it, an external one does not. Then move 10 m from any wiring or motor."
                        : "CHANGE THE SAMPLE RATE and re-census. An alias moves; a real line stays put. This is the cheapest discriminator on the whole screen and it settles the question in one run."
                ))
            if seen.visibility == .folded && band.family == .anthropogenic {
                let invaded = BandRegistry.bands.filter {
                    $0.family != .anthropogenic && $0.family != .instrument && $0.contains(seen.apparentCentreHz)
                }
                if !invaded.isEmpty {
                    notes.append(
                        "⚠️ \(band.label) folds to \(String(format: "%.2f", seen.apparentCentreHz)) Hz at \(String(format: "%.1f", rate)) Hz sampling — INSIDE \(invaded.map(\.label).joined(separator: " and ")). Those bands cannot be measured at this sample rate: whatever is there is at least partly grid power wearing a different frequency."
                    )
                }
            }
            if seen.visibility != .direct && seen.hzFromTarget < 2 {
                notes.append(
                    "⚠️ \(band.label) folds to \(String(format: "%.2f", seen.apparentCentreHz)) Hz at \(String(format: "%.1f", rate)) Hz sampling — \(String(format: "%.2f", seen.hzFromTarget)) Hz from the \(String(format: "%.2f", targetHz)) Hz target. Re-run at a different sample rate before believing anything in the target band."
                )
            }
        }

        // 3. Anonymous lines. Named by index, never by guess.
        let anonymous = anonymousPeaks(
            power: power, freqs: freqs, claimed: &claimed,
            resolution: resolution, limit: 8)
        for (index, peak) in anonymous.enumerated() {
            let identifier = String(format: "U-%02d", index + 1)
            let fraction = share(peak.bins)
            var relation = ""
            for earlier in anonymous.prefix(index) {
                for harmonic in 2...4 where abs(peak.frequency - Double(harmonic) * earlier.frequency) < 2 * resolution {
                    relation = " Sits at \(harmonic)× the frequency of an earlier anonymous line, so the two are probably one source."
                }
            }
            components.append(
                Component(
                    id: identifier,
                    label: String(format: "%@ · unidentified line at %.3f Hz", identifier, peak.frequency),
                    status: .unattributed, fraction: fraction, amplitudeMicrotesla: amplitude(fraction),
                    centreHz: peak.frequency, bandwidthHz: 2 * resolution,
                    prominenceDB: peak.prominenceDB,
                    driftDB: halfSplitDB(ac, rate: rate, centre: peak.frequency, halfWidth: 2 * resolution),
                    evidence: String(
                        format: "%.1f dB above the local spectral floor, and inside no band this instrument knows about.", peak.prominenceDB
                    ) + relation,
                    discriminator:
                        "Three cheap tests, in order: change the sample rate (an alias moves), rotate the phone 90° (a device-fixed source rotates with it, an external one does not), and walk 10 m away from any wiring or motor."
                ))
        }

        // 4. Everything left is the broadband floor. It is unattributed too, and says so.
        let floorBins = claimed.indices.filter { !claimed[$0] }
        let floorFraction = share(floorBins)
        components.append(
            Component(
                id: "floor", label: "Broadband floor", status: .unattributed,
                fraction: floorFraction, amplitudeMicrotesla: amplitude(floorFraction),
                centreHz: nil, bandwidthHz: rate / 2, prominenceDB: nil, driftDB: nil,
                evidence:
                    "All remaining power, spread across the band with no line structure. Sensor noise, quantisation and whatever else has no peak. This is a floor, not an identification.",
                discriminator:
                    "It is the quantity `noise_budget.local_noise` measures properly. Until a baseline run exists, no detection threshold on this rig is a number."
            ))

        let motion = motionCoupling(samples: samples, ac: ac)
        let unattributed = components.filter { $0.status == .unattributed }.reduce(0) { $0 + $1.fraction }

        notes.append(
            "The shares partition the AC variance and sum to 1. Motion coupling is reported separately because it writes across the whole band — adding it to a slice would count the same power twice."
        )
        notes.append(
            "Nothing is filtered out unless you set a band to EXCLUDE. Mains, drift and the sensor floor are all still in the budget, because a signal nested on a loud carrier is only findable while the carrier is still there."
        )

        return Result(
            sampleRateHz: rate, resolutionHz: resolution,
            durationSeconds: Double(magnitude.count) / rate,
            standingFieldMicrotesla: standing, acRMSMicrotesla: acRMS,
            components: components.sorted { $0.fraction > $1.fraction },
            motion: motion, unattributedFraction: unattributed,
            excludedFraction: excludedPower / max(1e-30, grossPower),
            policies: policies, notes: notes)
    }

    // MARK: - motion

    /// How much of the AC variance the phone's own ORIENTATION explains.
    ///
    /// This matters more here than anywhere else in the app: rotating a phone in the Earth's ~50 µT
    /// field changes each measured axis by microtesla — four orders of magnitude above anything this
    /// project is looking for. Analysing |B| rather than a single axis is most of the defence,
    /// because the magnitude of a vector is rotation-invariant. It is not all of it: axis gain and
    /// offset error (hard- and soft-iron) make a real sensor's |B| depend on which way it is
    /// pointing, so the residual coupling shows up as |B| tracking ATTITUDE.
    ///
    /// **The predictor is attitude, not rotation rate, and that was measured rather than assumed.**
    /// The first implementation regressed |B| on |rotation rate| and returned R² = 1.5e-9 for a
    /// record that was *entirely* rotation-driven. Two reasons, both fatal: |ω| is unsigned, so it
    /// peaks twice per cycle and cannot predict something that varies once per cycle; and the field
    /// on an axis depends on where the phone is POINTING (the integral of signed ω), not on how fast
    /// it is turning. Rotation rate is kept only as the gate for whether the question is answerable.
    ///
    /// **It refuses to answer when the phone did not move.** With no rotation there is nothing to
    /// regress against, and a fit through a constant returns ~0 explained — which would read as
    /// "motion is not a problem here" when the truth is "this record cannot say".
    static func motionCoupling(samples: [SensorSample], ac: [Double]) -> MotionCoupling {
        let rotation = samples.map { $0.rotationRate.magnitude }
        let acceleration = samples.map { $0.acceleration.magnitude }
        let rotationRange = (rotation.max() ?? 0) - (rotation.min() ?? 0)
        let accelerationRange = (acceleration.max() ?? 0) - (acceleration.min() ?? 0)

        // The gate asks "did the phone move", and the range of the rotation RATE does not answer it:
        // a phone turning at a constant speed has a rotation-rate range of exactly zero while its
        // orientation sweeps through a full circle. Caught by a test that did precisely that. The
        // gate is peak rotation speed and the spread of attitude itself.
        let peakRotation: Double = rotation.max() ?? 0
        let attitudeChannels: [[Double]] = [
            samples.map(\.attitude.x), samples.map(\.attitude.y),
            samples.map(\.attitude.z), samples.map(\.attitude.w),
        ]
        var attitudeSpread: Double = 0
        for column in attitudeChannels {
            let high: Double = column.max() ?? 0
            let low: Double = column.min() ?? 0
            attitudeSpread = max(attitudeSpread, high - low)
        }
        let moved: Bool = peakRotation > 0.02 || attitudeSpread > 0.01 || accelerationRange > 0.02
        guard rotation.count == ac.count, moved else {
            return MotionCoupling(
                varianceExplained: nil,
                rotationRangeRadPerS: rotationRange, accelerationRangeG: accelerationRange,
                verdict:
                    "Cannot answer: the phone barely moved (peak rotation \(String(format: "%.3f", peakRotation)) rad/s, attitude spread \(String(format: "%.3f", attitudeSpread))). With no motion there is nothing to regress against, so this record cannot show whether motion couples — it is untested, not absent. That is the right outcome for a stationary run."
            )
        }

        let predictors: [[Double]] = [
            samples.map(\.attitude.x), samples.map(\.attitude.y),
            samples.map(\.attitude.z), samples.map(\.attitude.w),
            acceleration,
        ]
        let explained = varianceExplained(y: ac, predictors: predictors)
        let verdict: String
        switch explained {
        case ..<0.05:
            verdict = String(
                format: "%.1f%% of the AC variance is predictable from attitude. Motion is not driving this record.", explained * 100)
        case ..<0.30:
            verdict = String(
                format:
                    "%.1f%% of the AC variance tracks attitude. Enough to contaminate a weak signal; re-run stationary before reading anything else on this screen.",
                explained * 100)
        default:
            verdict = String(
                format:
                    "%.1f%% of the AC variance tracks attitude. This is a recording of the phone moving through the Earth's field, and the rest of the census is about that.",
                explained * 100)
        }
        return MotionCoupling(
            varianceExplained: explained,
            rotationRangeRadPerS: rotationRange,
            accelerationRangeG: accelerationRange, verdict: verdict)
    }

    // MARK: - maths

    struct Peak {
        let frequency: Double
        let prominenceDB: Double
        let bins: [Int]
    }

    /// The prominence a peak needs to be worth naming, given how many bins were searched.
    ///
    /// Computed, not chosen. The power in one bin of a Gaussian-noise spectrum is exponentially
    /// distributed, so the largest of `N` bins sits about `ln(N)` above the mean by chance alone —
    /// and the local floor here is a MEDIAN, which is `ln 2` of the mean, adding another 1.6 dB.
    /// For a family-wise false-alarm rate `alpha` across `N` bins the bar is `ln(N/alpha) / ln 2`.
    ///
    /// The first version used a flat 4 dB and a pure-noise record produced eight "unidentified
    /// lines" and a "suspected" band. At 1024 bins this returns **12.2 dB**, and the same record
    /// produces nothing. A detector whose threshold does not know how many places it looked is not
    /// a detector.
    static func prominenceThresholdDB(binCount: Int, alpha: Double = 0.01) -> Double {
        guard binCount > 1, alpha > 0, alpha < 1 else { return 12 }
        let expected: Double = log(Double(binCount) / alpha) / log(2.0)
        return 10 * log10(expected)
    }

    /// Pick the lines that are not at any named frequency.
    ///
    /// Three guards, and the first two were added because a noiseless test record reported **eight**
    /// anonymous lines for one pure tone: a windowed sinusoid has a leakage skirt, and every bin in
    /// that skirt clears a prominence threshold when the "floor" it is measured against is also
    /// leakage. A skirt is one source, not eight.
    ///
    /// 1. A candidate must be a **local maximum**, so skirt bins cannot nominate themselves.
    /// 2. A candidate within `separationBins` of an accepted peak is that peak, not a new one.
    /// 3. An accepted peak **claims its skirt**, so the energy in the leakage is booked to the line
    ///    that produced it rather than left in the broadband floor.
    static func anonymousPeaks(
        power: [Double], freqs: [Double], claimed: inout [Bool],
        resolution: Double, limit: Int,
        thresholdDB: Double? = nil, separationBins: Int = 6
    ) -> [Peak] {
        // A stricter bar than the band test uses, deliberately. Naming a `U-nn` line asserts that
        // something is there and invites someone to go chase it; leaving a weak line in the floor
        // costs nothing, because the floor is still displayed. The asymmetry is in the alpha.
        let bar = thresholdDB ?? prominenceThresholdDB(binCount: power.count, alpha: 0.001)
        var found: [Peak] = []
        let order = power.indices.filter { !claimed[$0] && freqs[$0] > 0.1 }
            .sorted { power[$0] > power[$1] }
        for index in order {
            guard found.count < limit, !claimed[index] else { continue }
            let low = max(0, index - 2)
            let high = min(power.count - 1, index + 2)
            guard let neighbourhood = (low...high).map({ power[$0] }).max(),
                power[index] >= neighbourhood
            else { continue }
            let separationHz = Double(separationBins) * resolution
            guard !found.contains(where: { abs($0.frequency - freqs[index]) < separationHz }) else { continue }
            let floor = localFloor(power, at: index, exclude: separationBins, span: 60)
            guard floor > 0, power[index] > 0 else { continue }
            let prominenceDB = 10 * log10(power[index] / floor)
            guard prominenceDB >= bar else { continue }
            let skirt = (index - separationBins)...(index + separationBins)
            let bins = skirt.filter { power.indices.contains($0) && !claimed[$0] }
            bins.forEach { claimed[$0] = true }
            found.append(Peak(frequency: freqs[index], prominenceDB: prominenceDB, bins: bins))
        }
        return found.sorted { $0.frequency < $1.frequency }
    }

    static func localFloor(_ power: [Double], at index: Int, exclude: Int, span: Int) -> Double {
        let low = max(0, index - span)
        let high = min(power.count - 1, index + span)
        let neighbours = (low...high).filter { abs($0 - index) > exclude }.map { power[$0] }
        guard !neighbours.isEmpty else { return 0 }
        let sorted = neighbours.sorted()
        return sorted[sorted.count / 2]
    }

    static func prominence(
        _ power: [Double], freqs: [Double], centre: Double,
        resolution: Double
    ) -> Double? {
        guard let index = freqs.indices.min(by: { abs(freqs[$0] - centre) < abs(freqs[$1] - centre) }),
            abs(freqs[index] - centre) < max(resolution, 0.5)
        else { return nil }
        let floor = localFloor(power, at: index, exclude: 3, span: 40)
        guard floor > 0, power[index] > 0 else { return nil }
        return 10 * log10(power[index] / floor)
    }

    /// Power in a band in the first half of the record versus the second, in dB. Positive means it
    /// grew. A component that appears or vanishes mid-run is a different kind of thing from one
    /// that is simply present.
    static func halfSplitDB(_ signal: [Double], rate: Double, centre: Double, halfWidth: Double) -> Double? {
        guard signal.count >= 256 else { return nil }
        let half = signal.count / 2
        let first = bandPower(Array(signal[0..<half]), rate: rate, centre: centre, halfWidth: halfWidth)
        let second = bandPower(Array(signal[half...]), rate: rate, centre: centre, halfWidth: halfWidth)
        // A component that is genuinely absent from one half is the most interesting case there is,
        // and returning nil would hide it. Floor both halves at a small fraction of the record's
        // total power so the ratio stays finite and the arrival still reads as a large positive dB.
        let epsilon = 1e-12 * max(1.0, first + second)
        return 10 * log10(max(second, epsilon) / max(first, epsilon))
    }

    static func bandPower(_ signal: [Double], rate: Double, centre: Double, halfWidth: Double) -> Double {
        let (freqs, power) = linearSpectrum(signal, sampleRateHz: rate)
        return freqs.indices.filter { abs(freqs[$0] - centre) <= max(halfWidth, rate / Double(signal.count)) }
            .reduce(0.0) { $0 + power[$1] }
    }

    /// Hann-windowed magnitude-squared spectrum, in LINEAR power. `SignalProcessor.powerSpectrum`
    /// returns dB, which cannot be summed into a budget. Delegates to `FFT` so there is one
    /// spectrum implementation in the app rather than two that can disagree.
    static func linearSpectrum(_ signal: [Double], sampleRateHz rate: Double) -> ([Double], [Double]) {
        let result = FFT.spectrum(signal, sampleRateHz: rate)
        return (result.freqs, result.power)
    }

    static func varianceExplained(y: [Double], predictors: [[Double]], ridge: Double = 1e-6) -> Double {
        let n = ([y.count] + predictors.map(\.count)).min() ?? 0
        guard n > predictors.count + 8, !predictors.isEmpty else { return 0 }
        let target = standardise(Array(y.prefix(n)))
        // Drop constant predictors rather than failing on them. A phone rotating about one axis
        // leaves two quaternion components dead flat, and an earlier version let those veto the
        // whole fit — R² = 0 for a record that was entirely orientation-driven. A predictor that
        // carries no information should be ignored, not fatal.
        let columns = predictors.map { standardise(Array($0.prefix(n))) }
            .filter { $0.contains(where: { $0 != 0 }) }
        guard !columns.isEmpty else { return 0 }
        let k = columns.count

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: k + 1), count: k)
        for row in 0..<k {
            for column in 0..<k {
                matrix[row][column] =
                    dot(columns[row], columns[column]) / Double(n)
                    + (row == column ? ridge : 0)
            }
            matrix[row][k] = dot(columns[row], target) / Double(n)
        }
        guard let beta = solve(&matrix, size: k) else { return 0 }

        var residual = 0.0
        for index in 0..<n {
            var predicted = 0.0
            for column in 0..<k { predicted += beta[column] * columns[column][index] }
            let error = target[index] - predicted
            residual += error * error
        }
        let r2 = 1 - residual / Double(n)  // target variance is 1
        let adjusted = 1 - (1 - r2) * Double(n - 1) / Double(n - k - 1)
        return min(1, max(0, adjusted))
    }

    /// Gauss-Jordan on an augmented `size × (size+1)` matrix. Returns nil if it is singular.
    private static func solve(_ matrix: inout [[Double]], size: Int) -> [Double]? {
        for pivot in 0..<size {
            var best = pivot
            for row in (pivot + 1)..<size where abs(matrix[row][pivot]) > abs(matrix[best][pivot]) {
                best = row
            }
            guard abs(matrix[best][pivot]) > 1e-12 else { return nil }
            matrix.swapAt(pivot, best)
            let divisor = matrix[pivot][pivot]
            for column in pivot...size { matrix[pivot][column] /= divisor }
            for row in 0..<size where row != pivot {
                let factor = matrix[row][pivot]
                guard factor != 0 else { continue }
                for column in pivot...size { matrix[row][column] -= factor * matrix[pivot][column] }
            }
        }
        return (0..<size).map { matrix[$0][size] }
    }

    private static func standardise(_ x: [Double]) -> [Double] {
        let mean = x.reduce(0, +) / Double(x.count)
        let sd = sqrt(x.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count))
        return sd > 0 ? x.map { ($0 - mean) / sd } : x.map { _ in 0 }
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
    }
    private static func detrend(_ signal: [Double]) -> [Double] {
        SignalProcessor().detrended(signal)
    }
    private static func rms(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : sqrt(x.reduce(0.0) { $0 + $1 * $1 } / Double(x.count))
    }
}
