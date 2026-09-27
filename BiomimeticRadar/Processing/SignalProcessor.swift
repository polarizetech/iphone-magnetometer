import Foundation

struct SignalProcessor: Sendable {
    func analyze(
        samples: [SensorSample], protocol plan: ExperimentProtocol,
        shuffleCount: Int = 200, emitterRunning: Bool = false,
        startedAt: Date? = nil, endedAt: Date? = nil,
        hasPassingPositiveControl: Bool? = nil,
        impliedCoilFieldNt: Double? = nil, alpha: Double = 0.05
    ) -> AnalysisResult {
        guard samples.count >= 8 else {
            var empty = AnalysisResult()
            empty.warnings = ["At least eight samples are required for analysis."]
            return empty
        }

        let times = samples.map(\.monotonicTime)
        let rate = estimatedSampleRate(times: times, fallback: plan.sampleRateHz)
        let raw = channel(plan.representation, from: samples)
        let passband = self.passband(for: plan, sampleRate: rate)
        func condition(_ x: [Double]) -> [Double] {
            var working = x
            if plan.processing.detrend { working = detrended(working) }
            if plan.processing.bandpass {
                working = bandpass(working, sampleRate: rate, lowHz: passband.low, highHz: passband.high)
            }
            if plan.processing.notch, plan.processing.notchHz < rate / 2 {
                working = notch(working, sampleRate: rate, frequency: plan.processing.notchHz)
            }
            return working
        }

        // Real timestamps, not an assumed uniform clock. Core Motion's delivery jitters and the
        // jitter lands directly on the reference phase. Every reference below — lock-in, coded
        // reference, phase trace — is evaluated at these instants when the correction is on.
        let referenceTimes: [Double]? =
            plan.processing.timestampCorrection
            ? times.map { $0 - (times.first ?? 0) } : nil
        let reference =
            referenceTimes.map {
                codedReference(times: $0, carrierHz: plan.targetFrequencyHz, code: plan.code, chipDuration: plan.chipDurationSeconds)
            }
            ?? codedReference(
                count: raw.count, sampleRate: rate, carrierHz: plan.targetFrequencyHz,
                code: plan.code, chipDuration: plan.chipDurationSeconds)

        // The channels the DETECTOR runs on. `.vector` is the three axes, each conditioned on its
        // own; everything else is one channel.
        let axisNames = ["x", "y", "z"]
        let detectorChannels: [[Double]] =
            plan.representation == .vector
            ? [samples.map(\.magnetic.x), samples.map(\.magnetic.y), samples.map(\.magnetic.z)].map(condition)
            : [condition(raw)]

        var axes: [AxisResult] = []
        var vector: VectorResult?
        let lock: LockInResult
        let matched: MatchedFilterResult
        let working: [Double]  // the primary conditioned channel for the trace reports
        if plan.representation == .vector {
            let locks = detectorChannels.map { ch in
                plan.processing.lockIn
                    ? lockIn(signal: ch, sampleRate: rate, frequency: plan.targetFrequencyHz, times: referenceTimes) : LockInResult()
            }
            let combined = combineLockIns(locks, n: raw.count)
            let vectorMatched: (combined: MatchedFilterResult, perAxis: [MatchedFilterResult]) =
                plan.processing.matchedFilter
                ? matchedFilterVector(
                    signals: detectorChannels, reference: reference,
                    shuffleCount: plan.processing.shuffleTesting ? shuffleCount : 1)
                : (combined: MatchedFilterResult(), perAxis: [MatchedFilterResult](repeating: MatchedFilterResult(), count: 3))
            for (index, name) in axisNames.enumerated() {
                axes.append(
                    AxisResult(
                        axis: name, lockIn: locks[index],
                        matchedPeakCorrelation: vectorMatched.perAxis[index].peakCorrelation,
                        matchedPValue: vectorMatched.perAxis[index].pValue))
            }
            let dominant = locks.indices.max { locks[$0].amplitude < locks[$1].amplitude } ?? 0
            vector = combined
            vector?.dominantAxis = axisNames[dominant]
            var primary = locks[dominant]
            primary.amplitude = combined.amplitude
            primary.pValue = combined.pValue
            primary.confidence = max(0, min(1, 1 - combined.pValue))
            lock = primary
            matched = vectorMatched.combined
            working = detectorChannels[dominant]
        } else {
            working = detectorChannels[0]
            lock =
                plan.processing.lockIn
                ? lockIn(signal: working, sampleRate: rate, frequency: plan.targetFrequencyHz, times: referenceTimes)
                : LockInResult()
            matched =
                plan.processing.matchedFilter
                ? matchedFilter(
                    signal: working, reference: reference,
                    shuffleCount: plan.processing.shuffleTesting ? shuffleCount : 1)
                : MatchedFilterResult()
        }
        let baseline = baselineReport(signal: raw, times: times, sampleRate: rate)
        let spectrum = powerSpectrum(signal: detrended(raw), sampleRate: rate, maxBins: 512)
        let extracted =
            plan.processing.lockIn
            ? lockInTrace(signal: working, sampleRate: rate, frequency: plan.targetFrequencyHz, times: referenceTimes)
            : []
        let rawRMS = rms(detrended(raw))
        let processedNoise = max(1e-12, standardDeviation(extracted.map(\.value)))
        let gain = 20 * log10(max(1e-12, rawRMS) / processedNoise)

        let harmonics =
            plan.processing.harmonicAnalysis
            ? harmonicReport(working, sampleRate: rate, fundamental: plan.targetFrequencyHz, times: referenceTimes)
            : nil
        let phaseTrack =
            plan.processing.phaseTracking
            ? phaseTrace(working, sampleRate: rate, frequency: plan.targetFrequencyHz, times: referenceTimes)
            : []
        let averaging =
            plan.processing.coherentAveraging
            ? coherentAveragingReport(
                working, sampleRate: rate,
                periodSeconds: plan.chipDurationSeconds * Double(max(1, plan.code.count)))
            : nil

        var pValues: [Double] = []
        if plan.processing.matchedFilter { pValues.append(matched.pValue) }
        if plan.processing.lockIn { pValues.append(lock.pValue) }
        let corrected = benjaminiHochberg(pValues)

        var warnings: [String] = []
        if rate < plan.targetFrequencyHz * 2.5 { warnings.append("Achieved sample rate is too low for the target frequency.") }
        if plan.processing.notch, plan.processing.notchHz >= rate / 2 {
            warnings.append("Requested notch exceeds Nyquist and was skipped.")
        }
        if samples.count < Int(plan.durationSeconds * rate * 0.8) {
            warnings.append("Acquisition contains fewer samples than preregistered.")
        }
        if plan.processing.bandpass, !plan.processing.autoBandwidthFromCode {
            let needed = codeBandwidthHz(plan)
            let have = plan.processing.highCutoffHz - plan.processing.lowCutoffHz
            if have < needed {
                warnings.append(
                    String(
                        format:
                            "The passband is %.2f Hz wide but this code needs %.2f Hz (chips of %.3f s spread the carrier by ±1/Tc). The filter is removing the code the matched filter is looking for.",
                        have, needed, plan.chipDurationSeconds))
            }
        }
        if let phase = phaseTrack.last, phaseTrack.count > 4 {
            let drift = abs(phase.value - (phaseTrack.first?.value ?? 0))
            if drift < 0.01 {
                warnings.append(
                    "Lock-in phase did not drift at all over the run. An external source almost always drifts against the phone's clock; a source that does not is usually the phone."
                )
            }
        }
        if emitterRunning {
            warnings.append("\(EmitterSchedule.stamp): \(EmitterSchedule.firewall)")
        }

        // The gates. Run over the whole record; a failing one caps the tier below.
        let gates = QualityGates.postRecord(
            samples: samples, plan: plan,
            startedAt: startedAt ?? samples.first?.wallTime ?? Date(),
            endedAt: endedAt ?? samples.last?.wallTime, achievedRate: rate,
            hasPassingPositiveControl: hasPassingPositiveControl)
        for g in gates.failing { warnings.append("GATE — \(g.gate.title): \(g.reason)") }

        // Tesla-referenced sensitivity. The floor is measured at the target band; the MDF is what
        // the dwell could have distinguished from it at `alpha`.
        let dwell = max(1e-3, rate > 0 ? Double(raw.count) / rate : plan.durationSeconds)
        let asdNt = bandNoiseASDNanotesla(detrended(raw), sampleRate: rate, target: plan.targetFrequencyHz)
        let z = normalQuantile(1 - alpha)
        let calibration = Calibration(
            noiseFloorNtPerRootHz: asdNt,
            minimumDetectableFieldNt: asdNt > 0 ? z * asdNt * sqrt(2 / dwell) : 0,
            alpha: alpha, dwellSeconds: dwell, impliedCoilFieldNt: impliedCoilFieldNt)

        // Tier is COMPUTED, not switched on. `preregistered` no longer promotes a result by itself,
        // and a failing gate caps it at `exploratory` however clean the detection looks.
        let significant = corrected.first.map { $0 < 0.05 } ?? false
        let controlsPass = significant && matched.peakCorrelation > matched.nullUpper95
        var tier: ResultTier = .exploratory
        if plan.preregistered && plan.blinded && !gates.blocks { tier = .preregistered }
        if controlsPass && !emitterRunning && !gates.blocks { tier = .significant }
        if controlsPass && emitterRunning { tier = .exploratory }
        if gates.blocks { tier = .exploratory }

        return AnalysisResult(
            lockIn: lock, matched: matched, baseline: baseline, spectrum: spectrum,
            rawTrace: zip(times, raw).map { TracePoint(time: $0 - (times.first ?? 0), value: $1) },
            extractedTrace: extracted, correctedPValues: corrected, processingGainDB: gain,
            resultTier: tier, passedNullControls: controlsPass, warnings: warnings,
            harmonics: harmonics, phaseTrace: phaseTrack, averaging: averaging,
            emitterWasRunning: emitterRunning, representation: plan.representation,
            axes: axes, vector: vector, gates: gates, calibration: calibration
        )
    }

    /// The chosen channel. `earthZ` needs the IMU attitude and falls back to |B| without it.
    func channel(_ representation: Representation, from samples: [SensorSample]) -> [Double] {
        switch representation {
        // `.vector` is three channels; for a single display channel use |B|
        case .magnitude, .vector: return samples.map(\.magnetic.magnitude)
        case .axisX: return samples.map(\.magnetic.x)
        case .axisY: return samples.map(\.magnetic.y)
        case .axisZ: return samples.map(\.magnetic.z)
        case .earthZ: return samples.map { $0.attitude.rotate($0.magnetic).z }
        case .derivative:
            let magnitude = samples.map(\.magnetic.magnitude)
            guard magnitude.count > 1 else { return magnitude }
            var out = [0.0]
            for index in 1..<magnitude.count { out.append(magnitude[index] - magnitude[index - 1]) }
            return out
        }
    }

    /// Lock in at 2f and 3f beside f. A coded carrier driven through a linear path has little
    /// harmonic content; a mechanical, switching or clipping source usually has a lot, so this is a
    /// cheap discriminator between a signal and an artefact that happens to be at the right rate.
    func harmonicReport(
        _ signal: [Double], sampleRate: Double, fundamental: Double,
        times: [Double]?
    ) -> HarmonicReport {
        let base = lockIn(signal: signal, sampleRate: sampleRate, frequency: fundamental, times: times)
        var ratios: [Double] = []
        for order in 2...3 {
            let frequency = fundamental * Double(order)
            guard frequency < sampleRate / 2 else {
                ratios.append(.nan)
                continue
            }
            let harmonic = lockIn(signal: signal, sampleRate: sampleRate, frequency: frequency, times: times)
            ratios.append(20 * log10(max(1e-15, harmonic.amplitude) / max(1e-15, base.amplitude)))
        }
        return HarmonicReport(
            fundamentalAmplitude: base.amplitude,
            secondHarmonicDB: ratios.first ?? .nan,
            thirdHarmonicDB: ratios.count > 1 ? ratios[1] : .nan)
    }

    /// Lock-in phase over successive windows, unwrapped. A source that shares the phone's clock
    /// shows a phase that does not move at all — which is the single cheapest way to tell the
    /// app's own emitter (or an aliased artefact locked to the sample clock) from the world.
    ///
    /// Every window's phase is measured against the SAME global time origin (`times`, or
    /// `index / rate` without them). Measuring each window against its own start, as this once
    /// did, puts a sawtooth into the trace whose slope is the rounding of the window length —
    /// a drift that is entirely the analysis and would be read as the source.
    func phaseTrace(
        _ signal: [Double], sampleRate: Double, frequency: Double,
        times: [Double]? = nil
    ) -> [TracePoint] {
        let window = max(16, Int(sampleRate / max(0.01, frequency) * 8))
        guard signal.count >= window * 2 else { return [] }
        let instants = (times?.count == signal.count) ? times! : (0..<signal.count).map { Double($0) / sampleRate }
        var out: [TracePoint] = []
        var previous = 0.0
        var offset = 0.0
        for end in stride(from: window, through: signal.count, by: window) {
            let chunk = Array(signal[(end - window)..<end])
            let chunkTimes = Array(instants[(end - window)..<end])
            var phase = lockIn(signal: chunk, sampleRate: sampleRate, frequency: frequency, times: chunkTimes).phaseRadians
            if !out.isEmpty {
                while phase + offset - previous > .pi { offset -= 2 * .pi }
                while phase + offset - previous < -.pi { offset += 2 * .pi }
            }
            phase += offset
            previous = phase
            out.append(TracePoint(time: instants[end - 1], value: phase))
        }
        return out
    }

    /// Average successive code periods and report the √N the averaging ACTUALLY achieved against
    /// the √N it should have.
    ///
    /// The first version compared the RMS of the FIRST epoch to the RMS of the mean epoch and
    /// reported **30.5 dB against a 15.3 dB ceiling** on a real export — an impossible number,
    /// because √34 is 15.3 dB and nothing averages better than independent noise. It was
    /// measuring the bandpass filter's start-up transient (the first epoch is the loudest) and
    /// drift, not noise averaging. So now:
    ///
    /// * **noise per epoch** is the median epoch RMS after the first epoch (filter settling);
    /// * **noise after averaging** is the RMS of the **±average** — epochs summed with alternating
    ///   sign, which cancels anything phase-locked to the code period and leaves exactly the noise
    ///   that survives averaging (the standard plus-minus reference of evoked-response work);
    /// * anything above the ideal by more than 1 dB is **flagged as a diagnostic error**, because
    ///   it cannot be averaging — and the note is written from the numbers, not chosen from two
    ///   strings.
    func coherentAveragingReport(
        _ signal: [Double], sampleRate: Double,
        periodSeconds: Double
    ) -> AveragingReport {
        let periodSamples = Int(periodSeconds * sampleRate)
        guard periodSamples > 8, signal.count >= periodSamples * 3 else {
            return AveragingReport(
                epochs: 0, idealGainDB: 0, achievedGainDB: 0,
                note: "Too few complete code periods to average.")
        }
        let epochs = signal.count / periodSamples
        // Drop the first epoch: the one-pole bandpass starts from the first sample and the
        // settling transient lives there. That is what produced the impossible 30 dB.
        let used = epochs - 1
        var mean = [Double](repeating: 0, count: periodSamples)
        var plusMinus = [Double](repeating: 0, count: periodSamples)
        var epochs2D: [[Double]] = []
        for epoch in 1..<epochs {
            let slice = Array(signal[(epoch * periodSamples)..<((epoch + 1) * periodSamples)])
            let sign: Double = (epoch - 1) % 2 == 0 ? 1 : -1
            for index in 0..<periodSamples {
                mean[index] += slice[index]
                plusMinus[index] += sign * slice[index]
            }
            epochs2D.append(slice)
        }
        for index in 0..<periodSamples {
            mean[index] /= Double(used)
            plusMinus[index] /= Double(used)
        }
        // NOISE per single epoch is the pooled RMS of each epoch's deviation from the mean epoch —
        // signal-locked content is removed, so this is noise only. NOISE after averaging is the RMS
        // of the ±average (alternating-sign sum), which cancels anything phase-locked and leaves the
        // noise that survived. Their ratio is the ACTUAL reduction; for independent noise it is √N,
        // for drift-correlated noise less, and it cannot exceed √N by construction — which is why
        // the old 30-against-15 was a sign the metric was wrong, not a discovery.
        var deviationSq = 0.0
        for slice in epochs2D {
            for index in 0..<periodSamples {
                let d = slice[index] - mean[index]
                deviationSq += d * d
            }
        }
        let single = sqrt(deviationSq / Double(max(1, used * periodSamples)))
        let residualNoise = rms(plusMinus)
        let ideal = 10 * log10(Double(used))
        let achieved = 20 * log10(max(1e-15, single) / max(1e-15, residualNoise))
        let averagedRMS = rms(mean)
        let exceeds = achieved > ideal + 1.0
        let note: String
        if exceeds {
            note = String(
                format:
                    "DIAGNOSTIC ERROR: achieved %.1f dB exceeds the √N ceiling of %.1f dB over %d epochs. Noise cannot average better than √N; the metric is seeing drift, a transient or a non-stationary record, not averaging. Do not quote it.",
                achieved, ideal, used)
        } else if achieved < ideal - 3.0 {
            note = String(
                format:
                    "Achieved %.1f dB of a possible %.1f dB over %d epochs: the out-of-band residual did not average down as independent noise would. The noise is correlated across code periods (drift, 1/f), so longer runs buy less than √N.",
                achieved, ideal, used)
        } else {
            note = String(
                format:
                    "Achieved %.1f dB of a possible %.1f dB over %d epochs (±average residual %.4g against a median epoch RMS of %.4g): the noise averaged down close to √N. The averaged epoch's RMS is %.4g — compare it to the residual to see whether anything phase-locked survived.",
                achieved, ideal, used, residualNoise, single, averagedRMS)
        }
        // The REPORTED achieved gain is hard-capped at the √N ceiling: independent noise cannot
        // average better than that, so a figure above it is always an artefact, never a result.
        // The raw number is kept in `uncappedAchievedGainDB`, and `exceedsIdeal` flags a real
        // excess (more than 1 dB) as a diagnostic error rather than rounding noise.
        return AveragingReport(
            epochs: used, idealGainDB: ideal, achievedGainDB: min(achieved, ideal),
            note: note, residualNoiseRMS: residualNoise, medianEpochRMS: single,
            averagedEpochRMS: averagedRMS, exceedsIdeal: exceeds,
            uncappedAchievedGainDB: achieved)
    }

    /// Bandwidth a phase-reversal code needs: the main lobe is `carrier ± 1/Tc`.
    func codeBandwidthHz(_ plan: ExperimentProtocol) -> Double {
        plan.chipDurationSeconds > 0 ? 2 / plan.chipDurationSeconds : 0
    }

    /// The passband actually used, derived from the code unless the operator set it by hand.
    func passband(for plan: ExperimentProtocol, sampleRate: Double) -> (low: Double, high: Double) {
        guard plan.processing.autoBandwidthFromCode, plan.chipDurationSeconds > 0 else {
            return (plan.processing.lowCutoffHz, plan.processing.highCutoffHz)
        }
        let half = 1 / plan.chipDurationSeconds
        let low = max(0.05, plan.targetFrequencyHz - half)
        let high = min(sampleRate / 2 * 0.95, plan.targetFrequencyHz + half)
        return (low, high)
    }

    func estimatedSampleRate(times: [Double], fallback: Double) -> Double {
        let differences = zip(times.dropFirst(), times).map(-).filter { $0 > 0 }
        guard !differences.isEmpty else { return fallback }
        let sorted = differences.sorted()
        return 1 / sorted[sorted.count / 2]
    }

    func detrended(_ signal: [Double]) -> [Double] {
        guard signal.count > 1 else { return signal }
        let n = Double(signal.count)
        let sx = n * (n - 1) / 2
        let sxx = (n - 1) * n * (2 * n - 1) / 6
        let sy = signal.reduce(0, +)
        let sxy = signal.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        let denominator = n * sxx - sx * sx
        let slope = denominator == 0 ? 0 : (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n
        return signal.enumerated().map { $0.element - intercept - slope * Double($0.offset) }
    }

    func bandpass(_ signal: [Double], sampleRate: Double, lowHz: Double, highHz: Double) -> [Double] {
        guard lowHz > 0, highHz > lowHz, highHz < sampleRate / 2 else { return signal }
        return lowPass(
            highPass(signal, sampleRate: sampleRate, cutoff: lowHz),
            sampleRate: sampleRate, cutoff: highHz)
    }

    private func lowPass(_ x: [Double], sampleRate: Double, cutoff: Double) -> [Double] {
        guard let first = x.first else { return [] }
        let dt = 1 / sampleRate
        let rc = 1 / (2 * Double.pi * cutoff)
        let alpha = dt / (rc + dt)
        var output = [first]
        for value in x.dropFirst() { output.append(output.last! + alpha * (value - output.last!)) }
        return output
    }

    private func highPass(_ x: [Double], sampleRate: Double, cutoff: Double) -> [Double] {
        guard let first = x.first else { return [] }
        let dt = 1 / sampleRate
        let rc = 1 / (2 * Double.pi * cutoff)
        let alpha = rc / (rc + dt)
        var output = [first]
        for index in 1..<x.count { output.append(alpha * (output[index - 1] + x[index] - x[index - 1])) }
        return output
    }

    func notch(_ signal: [Double], sampleRate: Double, frequency: Double, q: Double = 25) -> [Double] {
        guard frequency > 0, frequency < sampleRate / 2 else { return signal }
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = 1 / a0
        let b1 = -2 * cos(w0) / a0
        let b2 = 1 / a0
        let a1 = -2 * cos(w0) / a0
        let a2 = (1 - alpha) / a0
        var y = Array(repeating: 0.0, count: signal.count)
        for n in signal.indices {
            y[n] = b0 * signal[n]
            if n >= 1 { y[n] += b1 * signal[n - 1] - a1 * y[n - 1] }
            if n >= 2 { y[n] += b2 * signal[n - 2] - a2 * y[n - 2] }
        }
        return y
    }

    /// Coherent detection at `frequency`.
    ///
    /// `times` are seconds from the first sample. Passing them uses the REAL sample instants rather
    /// than assuming `index / rate`; Core Motion jitters, and jitter on the reference is phase noise
    /// that no amount of integration removes.
    ///
    /// The returned `pValue` is an F-test of the response bin against the residual, not the ad-hoc
    /// `1 − exp(...)` confidence this used to feed into the Benjamini–Hochberg correction beside a
    /// genuine permutation p-value. Two numbers on different scales cannot be FDR-corrected together.
    func lockIn(
        signal: [Double], sampleRate: Double, frequency: Double,
        times: [Double]? = nil
    ) -> LockInResult {
        guard !signal.isEmpty, frequency > 0, frequency < sampleRate / 2 else { return LockInResult() }
        let n = signal.count
        func instant(_ index: Int) -> Double {
            if let times, times.count == n { return times[index] }
            return Double(index) / sampleRate
        }

        var i = 0.0
        var q = 0.0
        for index in 0..<n {
            let phase: Double = 2 * Double.pi * frequency * instant(index)
            i += signal[index] * cos(phase)
            q += signal[index] * sin(phase)
        }
        i *= 2 / Double(n)
        q *= 2 / Double(n)
        let amplitude = hypot(i, q)

        var residual = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let phase: Double = 2 * Double.pi * frequency * instant(index)
            residual[index] = signal[index] - i * cos(phase) - q * sin(phase)
        }
        let noise = max(1e-12, rms(residual))
        let snr = 20 * log10(max(1e-12, amplitude) / noise)

        // F(2, n−3): two degrees of freedom in the fitted sinusoid against the residual.
        let explained = amplitude * amplitude * Double(n) / 4
        let residualPower = residual.reduce(0.0) { $0 + $1 * $1 }
        let degrees = Double(max(1, n - 3))
        let f = residualPower > 0 ? (explained / 2) / (residualPower / degrees) : 0
        let p = fTestPValue(f: f, d1: 2, d2: degrees)
        return LockInResult(
            inPhase: i, quadrature: q, amplitude: amplitude,
            phaseRadians: atan2(q, i), snrDB: snr,
            confidence: max(0, min(1, 1 - p)), pValue: p)
    }

    /// Three per-axis lock-ins combined coherently: vector amplitude, pooled F-test, direction.
    ///
    /// Each axis's fit explains `A²n/4` with two parameters against its own residual. Pooling the
    /// three gives six numerator degrees of freedom; with thousands of samples the F(6, 3(n−3))
    /// tail is the χ²(6) tail at `6f`, which has a closed form. Nothing here is averaged across
    /// axes before fitting — that would be the |B| mistake in a different coat.
    func combineLockIns(_ locks: [LockInResult], n: Int) -> VectorResult {
        guard !locks.isEmpty, n > 3 else { return VectorResult() }
        let amplitude = sqrt(locks.reduce(0.0) { $0 + $1.amplitude * $1.amplitude })
        let degrees = Double(n - 3)
        var explained = 0.0
        var residual = 0.0
        for lock in locks {
            explained += lock.amplitude * lock.amplitude * Double(n) / 4
            // residual power from the axis's SNR: noise RMS = amplitude / 10^(snr/20)
            let noise = lock.amplitude > 0 ? lock.amplitude / pow(10, lock.snrDB / 20) : 0
            residual += noise * noise * Double(n)
        }
        let k = Double(locks.count)
        let f = residual > 0 ? (explained / (2 * k)) / (residual / (k * degrees)) : 0
        let p = chiSquareUpperTail(x: 2 * k * f, evenDegrees: Int(2 * k))
        let direction = Vector3(
            x: locks.count > 0 ? (locks[0].inPhase >= 0 ? 1 : -1) * locks[0].amplitude : 0,
            y: locks.count > 1 ? (locks[1].inPhase >= 0 ? 1 : -1) * locks[1].amplitude : 0,
            z: locks.count > 2 ? (locks[2].inPhase >= 0 ? 1 : -1) * locks[2].amplitude : 0)
        let norm = max(1e-15, direction.magnitude)
        return VectorResult(
            amplitude: amplitude, pValue: p, dominantAxis: "x",
            direction: Vector3(x: direction.x / norm, y: direction.y / norm, z: direction.z / norm))
    }

    /// Upper tail of χ²(k) for EVEN k, closed form: e^{−x/2} Σ_{i<k/2} (x/2)^i / i!.
    func chiSquareUpperTail(x: Double, evenDegrees k: Int) -> Double {
        guard x > 0, k >= 2, k % 2 == 0 else { return 1 }
        let half = x / 2
        var term = 1.0
        var sum = 1.0
        for i in 1..<(k / 2) {
            term *= half / Double(i)
            sum += term
        }
        return max(0, min(1, exp(-half) * sum))
    }

    /// The matched filter over several channels at once.
    ///
    /// At every lag the statistic is √(Σ r_axis²) — each axis correlated against the SAME reference,
    /// combined after. The null is the same block-shuffle of the reference, applied identically to
    /// every axis, with the maximum of the combined statistic taken across the lag search per
    /// shuffle — the family-wise construction the scalar filter already used. Returns the combined
    /// result and each axis's own peak and p against the same null.
    func matchedFilterVector(
        signals: [[Double]], reference: [Double], shuffleCount: Int = 200,
        seed: UInt64 = 0xF13D1AB
    ) -> (combined: MatchedFilterResult, perAxis: [MatchedFilterResult]) {
        guard let first = signals.first, first.count >= 4, reference.count == first.count,
            signals.allSatisfy({ $0.count == first.count })
        else {
            return (MatchedFilterResult(), signals.map { _ in MatchedFilterResult() })
        }
        let maxLag = min(first.count / 3, 1_000)
        func combinedAt(_ ref: [Double], lag: Int) -> (Double, [Double]) {
            var sum = 0.0
            var per: [Double] = []
            for signal in signals {
                let (a, b) = aligned(signal, ref, lag: lag)
                let r = normalizedCorrelation(a, b)
                per.append(r)
                sum += r * r
            }
            return (sqrt(sum), per)
        }
        var trace: [TracePoint] = []
        var perAxisTraces = signals.map { _ in [TracePoint]() }
        for lag in -maxLag...maxLag {
            let (c, per) = combinedAt(reference, lag: lag)
            trace.append(TracePoint(time: Double(lag), value: c))
            for (i, r) in per.enumerated() { perAxisTraces[i].append(TracePoint(time: Double(lag), value: r)) }
        }
        let best = trace.max { $0.value < $1.value } ?? TracePoint(time: 0, value: 0)
        var rng = SeededGenerator(seed: seed)
        var nulls: [Double] = []
        var axisNulls = signals.map { _ in [Double]() }
        let block = max(4, first.count / 31)
        let nullLagStep = max(1, maxLag / 30)
        for _ in 0..<max(1, shuffleCount) {
            var blocks = stride(from: 0, to: reference.count, by: block).map {
                Array(reference[$0..<min(reference.count, $0 + block)])
            }
            blocks.shuffle(using: &rng)
            let shuffled = Array(Array(blocks.joined()).prefix(reference.count))
            var nullMaximum = 0.0
            var axisMax = signals.map { _ in 0.0 }
            for lag in stride(from: -maxLag, through: maxLag, by: nullLagStep) {
                let (c, per) = combinedAt(shuffled, lag: lag)
                nullMaximum = max(nullMaximum, c)
                for (i, r) in per.enumerated() { axisMax[i] = max(axisMax[i], abs(r)) }
            }
            nulls.append(nullMaximum)
            for i in axisMax.indices { axisNulls[i].append(axisMax[i]) }
        }
        nulls.sort()
        let exceedances = nulls.filter { $0 >= best.value }.count
        let p = Double(exceedances + 1) / Double(nulls.count + 1)
        let upper = nulls[min(nulls.count - 1, Int(Double(nulls.count - 1) * 0.95))]
        let combined = MatchedFilterResult(
            bestLagSamples: Int(best.time), peakCorrelation: best.value,
            pValue: p, falseAlarmProbability: p,
            nullMean: mean(nulls), nullUpper95: upper,
            correlationTrace: trace, nullDistribution: nulls)
        var perAxis: [MatchedFilterResult] = []
        for i in signals.indices {
            let axisBest = perAxisTraces[i].max { abs($0.value) < abs($1.value) } ?? TracePoint(time: 0, value: 0)
            let sortedNull = axisNulls[i].sorted()
            let ex = sortedNull.filter { $0 >= abs(axisBest.value) }.count
            perAxis.append(
                MatchedFilterResult(
                    bestLagSamples: Int(axisBest.time), peakCorrelation: axisBest.value,
                    pValue: Double(ex + 1) / Double(sortedNull.count + 1),
                    falseAlarmProbability: Double(ex + 1) / Double(sortedNull.count + 1),
                    nullMean: mean(sortedNull),
                    nullUpper95: sortedNull[min(sortedNull.count - 1, Int(Double(sortedNull.count - 1) * 0.95))],
                    correlationTrace: [], nullDistribution: []))
        }
        return (combined, perAxis)
    }

    /// Upper-tail p of an F(2, d2) statistic. For d1 = 2 this is exact and closed-form:
    /// `P(F > f) = (1 + 2f/d2)^(−d2/2)`, which is why the lock-in fits exactly two parameters.
    func fTestPValue(f: Double, d1: Double, d2: Double) -> Double {
        guard f > 0, d2 > 0 else { return 1 }
        guard d1 == 2 else { return 1 }
        return pow(1 + 2 * f / d2, -d2 / 2)
    }

    func lockInTrace(
        signal: [Double], sampleRate: Double, frequency: Double,
        times: [Double]? = nil
    ) -> [TracePoint] {
        let window = max(4, Int(sampleRate / max(0.01, frequency) * 2))
        guard signal.count >= window else { return [] }
        let instants = (times?.count == signal.count) ? times! : (0..<signal.count).map { Double($0) / sampleRate }
        return stride(from: window, through: signal.count, by: max(1, window / 4)).map { end in
            let chunk = Array(signal[(end - window)..<end])
            let chunkTimes = Array(instants[(end - window)..<end])
            return TracePoint(
                time: instants[end - 1],
                value: lockIn(signal: chunk, sampleRate: sampleRate, frequency: frequency, times: chunkTimes).amplitude)
        }
    }

    func codedReference(
        count: Int, sampleRate: Double, carrierHz: Double,
        code: [Double], chipDuration: Double
    ) -> [Double] {
        codedReference(
            times: (0..<count).map { Double($0) / sampleRate }, carrierHz: carrierHz,
            code: code, chipDuration: chipDuration)
    }

    /// The coded reference evaluated at the REAL sample instants (seconds from the first sample).
    ///
    /// Both the carrier phase and the chip boundaries come from `times`, so a clock that runs at
    /// 101.42 Hz when 100 was requested — every session so far — does not stretch the reference
    /// by 1.4% against the signal. Over 60 s that stretch is 4.5 carrier cycles of phase slip,
    /// enough to null a lock-in; the audit of the first two exports found exactly that.
    func codedReference(times: [Double], carrierHz: Double, code: [Double], chipDuration: Double) -> [Double] {
        guard !code.isEmpty, chipDuration > 0 else { return Array(repeating: 0, count: times.count) }
        return times.map { time in
            let chip = Int(time / chipDuration) % code.count
            return code[chip] * sin(2 * .pi * carrierHz * time)
        }
    }

    func matchedFilter(
        signal: [Double], reference: [Double], shuffleCount: Int = 200,
        seed: UInt64 = 0xF13D1AB
    ) -> MatchedFilterResult {
        guard signal.count >= 4, reference.count == signal.count else { return MatchedFilterResult() }
        let maxLag = min(signal.count / 3, 1_000)
        let trace = (-maxLag...maxLag).map { lag -> TracePoint in
            let (a, b) = aligned(signal, reference, lag: lag)
            return TracePoint(time: Double(lag), value: normalizedCorrelation(a, b))
        }
        let best = trace.max { abs($0.value) < abs($1.value) } ?? TracePoint(time: 0, value: 0)
        var rng = SeededGenerator(seed: seed)
        var nulls: [Double] = []
        let block = max(4, signal.count / 31)
        let nullLagStep = max(1, maxLag / 30)
        for _ in 0..<max(1, shuffleCount) {
            var blocks = stride(from: 0, to: reference.count, by: block).map {
                Array(reference[$0..<min(reference.count, $0 + block)])
            }
            blocks.shuffle(using: &rng)
            let shuffled = Array(blocks.joined()).prefix(reference.count)
            var nullMaximum = 0.0
            for lag in stride(from: -maxLag, through: maxLag, by: nullLagStep) {
                let (a, b) = aligned(signal, Array(shuffled), lag: lag)
                nullMaximum = max(nullMaximum, abs(normalizedCorrelation(a, b)))
            }
            nulls.append(nullMaximum)
        }
        nulls.sort()
        let exceedances = nulls.filter { $0 >= abs(best.value) }.count
        let p = Double(exceedances + 1) / Double(nulls.count + 1)
        let upper = nulls[min(nulls.count - 1, Int(Double(nulls.count - 1) * 0.95))]
        return MatchedFilterResult(
            bestLagSamples: Int(best.time), peakCorrelation: best.value,
            pValue: p, falseAlarmProbability: p,
            nullMean: mean(nulls), nullUpper95: upper,
            correlationTrace: trace, nullDistribution: nulls)
    }

    private func aligned(_ a: [Double], _ b: [Double], lag: Int) -> ([Double], [Double]) {
        if lag >= 0 { return (Array(a.dropFirst(lag)), Array(b.dropLast(lag))) }
        return (Array(a.dropLast(-lag)), Array(b.dropFirst(-lag)))
    }

    func normalizedCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let am = mean(a)
        let bm = mean(b)
        var numerator = 0.0
        var da = 0.0
        var db = 0.0
        for (x, y) in zip(a, b) {
            numerator += (x - am) * (y - bm)
            da += pow(x - am, 2)
            db += pow(y - bm, 2)
        }
        return numerator / max(1e-15, sqrt(da * db))
    }

    func powerSpectrum(signal: [Double], sampleRate: Double, maxBins: Int) -> [SpectrumPoint] {
        let n = min(signal.count, 2048)
        guard n >= 8 else { return [] }
        let input = Array(signal.prefix(n))
        let bins = min(n / 2, maxBins)
        return (0..<bins).map { k in
            var real = 0.0
            var imag = 0.0
            for index in 0..<n {
                let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(n - 1))
                let phase = 2 * .pi * Double(k * index) / Double(n)
                real += input[index] * window * cos(phase)
                imag -= input[index] * window * sin(phase)
            }
            return SpectrumPoint(
                frequency: Double(k) * sampleRate / Double(n),
                power: 10 * log10(max(1e-20, (real * real + imag * imag) / Double(n * n))))
        }
    }

    func baselineReport(signal: [Double], times: [Double], sampleRate: Double) -> BaselineReport {
        guard !signal.isEmpty else { return BaselineReport() }
        let trend = signal.count > 1 ? (signal.last! - signal.first!) / max(1e-9, (times.last ?? 0) - (times.first ?? 0)) : 0
        let spectrum = powerSpectrum(signal: detrended(signal), sampleRate: sampleRate, maxBins: 512)
        let dominant = spectrum.dropFirst().max(by: { $0.power < $1.power })?.frequency ?? 0
        return BaselineReport(
            mean: mean(signal), variance: variance(signal), rmsNoise: rms(detrended(signal)),
            driftPerSecond: trend, dominantFrequency: dominant,
            allanDeviation: allanDeviation(signal))
    }

    func allanDeviation(_ signal: [Double]) -> Double {
        guard signal.count >= 4 else { return 0 }
        let pairs: [Double] = stride(from: 0, to: signal.count - 1, by: 2).map { index -> Double in
            let a: Double = signal[index]
            let b: Double = signal[index + 1]
            return (a + b) / 2
        }
        guard pairs.count > 1 else { return 0 }
        let squared: [Double] = zip(pairs.dropFirst(), pairs).map { later, earlier -> Double in
            let d: Double = later - earlier
            return d * d
        }
        return sqrt(squared.reduce(0, +) / (2 * Double(squared.count)))
    }

    func benjaminiHochberg(_ pValues: [Double]) -> [Double] {
        guard !pValues.isEmpty else { return [] }
        let indexed = pValues.enumerated().sorted { $0.element < $1.element }
        var adjusted = Array(repeating: 1.0, count: pValues.count)
        var running = 1.0
        for rankIndex in stride(from: indexed.count - 1, through: 0, by: -1) {
            let item = indexed[rankIndex]
            running = min(running, item.element * Double(indexed.count) / Double(rankIndex + 1))
            adjusted[item.offset] = min(1, running)
        }
        return adjusted
    }

    /// Amplitude spectral density of the noise at `target`, in nanotesla/√Hz.
    ///
    /// A Welch PSD of the µT signal, then the MEDIAN in a ±2 Hz window around the target with the
    /// ±0.25 Hz right at the target excluded — so a real line at the target does not raise its own
    /// floor. `√PSD` is the amplitude density in µT/√Hz; ×1000 for nT. This is the same estimator
    /// `tools/eeg-bridge` settled on after finding a broadband RMS overstates the at-frequency noise
    /// by 20–90×.
    func bandNoiseASDNanotesla(
        _ signal: [Double], sampleRate: Double, target: Double,
        halfWidthHz: Double = 2, excludeHz: Double = 0.25
    ) -> Double {
        guard signal.count >= 64, sampleRate > 0, target > 0, target < sampleRate / 2 else { return 0 }
        var seg = 2048
        while seg > signal.count { seg /= 2 }
        guard seg >= 32 else { return 0 }
        let half = seg / 2
        var wsum = 0.0
        let window = (0..<seg).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(seg - 1)) }
        for w in window { wsum += w * w }
        var psd = [Double](repeating: 0, count: half + 1)
        var segments = 0
        var start = 0
        while start + seg <= signal.count {
            let chunk = detrended(Array(signal[start..<(start + seg)]))
            for k in 0...half {
                var re = 0.0
                var im = 0.0
                for i in 0..<seg {
                    let ang = 2 * Double.pi * Double(k * i) / Double(seg)
                    re += chunk[i] * window[i] * cos(ang)
                    im -= chunk[i] * window[i] * sin(ang)
                }
                var p = (re * re + im * im) / (sampleRate * wsum)
                if k > 0 && k < half { p *= 2 }
                psd[k] += p
            }
            segments += 1
            start += max(1, half)
        }
        guard segments > 0 else { return 0 }
        var ring: [Double] = []
        for k in 0...half {
            let f = Double(k) * sampleRate / Double(seg)
            let d = abs(f - target)
            if d <= halfWidthHz && d > excludeHz { ring.append(psd[k] / Double(segments)) }
        }
        guard !ring.isEmpty else { return 0 }
        ring.sort()
        return sqrt(ring[ring.count / 2]) * 1000
    }

    /// Inverse normal CDF (Acklam's rational approximation), for the one-sided z at a given alpha.
    func normalQuantile(_ p: Double) -> Double {
        let p = min(1 - 1e-9, max(1e-9, p))
        let a = [
            -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01,
            2.506628277459239e+00,
        ]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [
            -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00,
            2.938163982698783e+00,
        ]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let plow = 0.02425
        let phigh = 1 - 0.02425
        if p < plow {
            let q = sqrt(-2 * log(p))
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p <= phigh {
            let q = p - 0.5
            let r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
                / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        }
        let q = sqrt(-2 * log(1 - p))
        return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
            / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    }

    private func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
    private func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return x.reduce(0) { $0 + pow($1 - m, 2) } / Double(x.count - 1)
    }
    private func rms(_ x: [Double]) -> Double { x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(x.count)) }
    private func standardDeviation(_ x: [Double]) -> Double { sqrt(variance(x)) }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
