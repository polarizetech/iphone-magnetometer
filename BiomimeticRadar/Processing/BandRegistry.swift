// swift-format-ignore-file
// serve.py, bands.py and dev_check.py read this file with regular expressions; keep its layout.
import Foundation

/// The named frequency bands this instrument knows about, and what is known to actually be
/// transmitting in them.
///
/// **Nothing here is deleted, filtered or notched out.** Mains, drift and the sensor's own noise
/// are the loudest things in a phone magnetometer record, and the standard move — notch them and
/// move on — assumes they carry nothing. That assumption is untested here, and it forecloses the
/// question this project is most interested in: whether something quiet is *riding on* something
/// loud. So every band gets a **policy** the operator sets, not a filter the code applies:
///
/// * `.watch` — analysed on its own terms, and offered to the cross-band coupling test.
/// * `.carrier` — treated as a possible host: its amplitude envelope is examined for modulation by
///   the watched slow bands. This is the "is something nested in the mains" setting.
/// * `.context` — reported in the census, excluded from coupling tests. The default for bands whose
///   physics is understood and uninteresting.
/// * `.excluded` — subtracted from the analysis band. Nothing is `.excluded` by default.
///
/// **ELF first.** The bands a human body and the planet share are 0.1–40 Hz, and they are ordered
/// first here on purpose: that is where the project's question lives, and where this hardware has
/// any chance at all.
struct BandRegistry: Sendable {

    enum Policy: String, Codable, Sendable, CaseIterable, Identifiable {
        case watch, carrier, context, excluded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .watch: "Watch"
            case .carrier: "Carrier"
            case .context: "Context"
            case .excluded: "Exclude"
            }
        }
        var explanation: String {
            switch self {
            case .watch: "Analysed on its own terms and offered to the coupling test as a modulator."
            case .carrier: "Treated as a possible host — its envelope is checked for modulation by the watched bands."
            case .context: "Reported in the census, kept out of the coupling tests."
            case .excluded: "Removed from the analysis band. Nothing is excluded by default."
            }
        }
    }

    enum Family: String, Codable, Sendable {
        case natural, anthropogenic, physiological, instrument
    }

    struct Band: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let label: String
        let lowHz: Double
        let highHz: Double
        let family: Family
        /// What is known to produce energy here.
        let origin: String
        /// Typical amplitude at the ground or at the body, with its tier stated in the string.
        let expectedAmplitude: String
        /// Default policy. Deliberately never `.excluded`.
        let defaultPolicy: Policy
        /// Lower sorts first. ELF bands are 0–19; everything else is 20+.
        let rank: Int

        var centreHz: Double { (lowHz + highHz) / 2 }
        var widthHz: Double { highHz - lowHz }
        func contains(_ frequency: Double) -> Bool { frequency >= lowHz && frequency <= highHz }
    }

    // MARK: - the catalogue

    /// ELF and ULF first — 0.001 to 40 Hz, where the planet's cavity, geomagnetic pulsations and
    /// every physiological rhythm all live. Then the anthropogenic and instrument bands.
    static let bands: [Band] = [
        // ---- natural ELF/ULF ------------------------------------------------------------------
        Band(id: "pc5", label: "Pc5 geomagnetic pulsation", lowHz: 0.0017, highHz: 0.0067,
             family: .natural,
             origin: "Magnetospheric field-line resonance. IAGA Pc5, 150–600 s period.",
             expectedAmplitude: "[C] tens of nT during storms — the largest natural ULF signal there is.",
             defaultPolicy: .watch, rank: 0),
        Band(id: "pc3-4", label: "Pc3–Pc4 pulsation", lowHz: 0.0067, highHz: 0.1,
             family: .natural,
             origin: "Upstream waves at the bow shock, transmitted through the magnetosphere.",
             expectedAmplitude: "[C] ~0.1–10 nT, strongly Kp-dependent.",
             defaultPolicy: .watch, rank: 1),
        Band(id: "pc1", label: "Pc1 'pearl' pulsation", lowHz: 0.2, highHz: 5.0,
             family: .natural,
             origin: "EMIC waves in the magnetosphere, ducted to the ground. IAGA Pc1, 0.2–5 Hz.",
             expectedAmplitude: "[C] ~0.1–1 nT during and after storms — the closest natural in-band candidate this rig has.",
             defaultPolicy: .watch, rank: 2),
        Band(id: "schumann-1", label: "Schumann 1 · 7.83 Hz", lowHz: 7.2, highHz: 8.5,
             family: .natural,
             origin: "First mode of the Earth-ionosphere cavity, driven by global lightning.",
             expectedAmplitude: "[C] ~1 pT. Five orders below a phone magnetometer floor — see research/ SCH-0001.",
             defaultPolicy: .watch, rank: 3),
        Band(id: "schumann-2", label: "Schumann 2 · 14.3 Hz", lowHz: 13.5, highHz: 15.2,
             family: .natural, origin: "Second cavity mode.",
             expectedAmplitude: "[C] ~0.5 pT.", defaultPolicy: .watch, rank: 4),
        Band(id: "schumann-3", label: "Schumann 3 · 20.8 Hz", lowHz: 19.8, highHz: 21.8,
             family: .natural, origin: "Third cavity mode.",
             expectedAmplitude: "[C] ~0.3 pT.", defaultPolicy: .watch, rank: 5),
        Band(id: "schumann-4", label: "Schumann 4 · 27.3 Hz", lowHz: 26.2, highHz: 28.4,
             family: .natural, origin: "Fourth cavity mode.",
             expectedAmplitude: "[C] ~0.2 pT.", defaultPolicy: .context, rank: 6),
        Band(id: "schumann-5", label: "Schumann 5 · 33.8 Hz", lowHz: 32.6, highHz: 35.0,
             family: .natural, origin: "Fifth cavity mode.",
             expectedAmplitude: "[C] ~0.15 pT.", defaultPolicy: .context, rank: 7),

        // ---- physiological ELF ----------------------------------------------------------------
        Band(id: "respiration", label: "Respiration", lowHz: 0.1, highHz: 0.5,
             family: .physiological,
             origin: "Breathing. Reaches a magnetometer through chest movement and posture, not through a field.",
             expectedAmplitude: "[C] no direct magnetic signature; it moves the sensor.",
             defaultPolicy: .watch, rank: 8),
        Band(id: "cardiac", label: "Cardiac", lowHz: 0.7, highHz: 3.0,
             family: .physiological,
             origin: "Heart rate and its first harmonics. A magnetocardiogram is real and measurable — at centimetres.",
             expectedAmplitude: "[B] ~50 pT at 5 cm from the chest; 0.125 pT at 1 m; gone by the next room (1/r²).",
             defaultPolicy: .watch, rank: 9),
        Band(id: "human-alpha", label: "Human alpha / ELF band", lowHz: 8.0, highHz: 13.0,
             family: .physiological,
             origin: "Cortical alpha is real; its MAGNETIC signature is MEG-scale.",
             expectedAmplitude: "[A] ~100 fT at the scalp. Eight orders below this sensor. Named because it is the question, not because it is reachable here.",
             defaultPolicy: .watch, rank: 10),

        // ---- anthropogenic --------------------------------------------------------------------
        Band(id: "mains-60", label: "Mains 60 Hz", lowHz: 59.0, highHz: 61.0,
             family: .anthropogenic,
             origin: "North American grid. The single strongest artificial magnetic signal in any building.",
             expectedAmplitude: "[A] 0.01–10 µT depending on distance to wiring. The only in-world signal this rig can reliably lock onto.",
             defaultPolicy: .carrier, rank: 20),
        Band(id: "mains-50", label: "Mains 50 Hz", lowHz: 49.0, highHz: 51.0,
             family: .anthropogenic, origin: "European/Asian grid.",
             expectedAmplitude: "[A] 0.01–10 µT near wiring.",
             defaultPolicy: .carrier, rank: 21),
        Band(id: "mains-harmonic", label: "Mains harmonics (2f, 3f)", lowHz: 99.0, highHz: 181.0,
             family: .anthropogenic,
             origin: "Non-linear loads — switching supplies, dimmers, motors — distort the grid waveform.",
             expectedAmplitude: "[B] typically 1–20% of the fundamental.",
             defaultPolicy: .context, rank: 22),
        Band(id: "traction", label: "Rail traction / DC motors", lowHz: 12.0, highHz: 25.0,
             family: .anthropogenic,
             origin: "16.7 Hz rail traction supply in parts of Europe; brushed-motor commutation elsewhere.",
             expectedAmplitude: "[C] site-specific and sometimes very large. Sits INSIDE the Schumann 2–3 range.",
             defaultPolicy: .context, rank: 23),

        // ---- instrument -----------------------------------------------------------------------
        Band(id: "drift", label: "Sensor drift and thermal wander", lowHz: 0.0, highHz: 0.1,
             family: .instrument,
             origin: "Magnetometer offset drift with temperature, plus slow changes in the local field.",
             expectedAmplitude: "[C] up to a few hundred nT over minutes. Overlaps Pc3–Pc5 completely.",
             defaultPolicy: .context, rank: 30),
    ]

    static func band(_ id: String) -> Band? { bands.first { $0.id == id } }

    /// The ELF/ULF subset, which is what this project is actually pointed at.
    static var elf: [Band] { bands.filter { $0.rank < 20 } }

    /// Default policies. Nothing is excluded — the operator has to choose that.
    static var defaultPolicies: [String: Policy] {
        Dictionary(uniqueKeysWithValues: bands.map { ($0.id, $0.defaultPolicy) })
    }

    // MARK: - what a sample rate can actually see

    enum Visibility: String, Codable, Sendable {
        /// Entirely below Nyquist: the band appears where it really is.
        case direct
        /// Above Nyquist: it still appears, folded somewhere else, and will be mistaken for something.
        case folded
        /// Straddles Nyquist: part direct, part folded, and the two overlap. The worst case.
        case straddling
        /// The band is wider than the sampled spectrum, or wraps across a Nyquist boundary, so it
        /// folds onto MORE THAN ONE stretch of the spectrum and cannot be assigned a location.
        case smeared
    }

    struct BandVisibility: Codable, Sendable, Equatable, Identifiable {
        var id: String { bandID }
        let bandID: String
        let visibility: Visibility
        /// Where the band's centre actually lands in the sampled spectrum.
        let apparentCentreHz: Double
        /// Distance from the apparent centre to the experiment's target frequency.
        let hzFromTarget: Double
        let note: String
    }

    /// Where each band lands after sampling at `rate`, and how close that is to the target.
    ///
    /// This is the function that catches the default configuration's problem: at 50 Hz, the 60 Hz
    /// mains band folds to 10 Hz and lands 1.7 Hz from an 8.3 Hz target. A band is not removed by
    /// being above Nyquist; it is disguised.
    static func visibility(of band: Band, sampleRateHz rate: Double, targetHz: Double) -> BandVisibility {
        let nyquist = rate / 2
        let apparent = SignalCensus.aliasOf(band.centreHz, sampleRateHz: rate)
        let distance = abs(apparent - targetHz)

        // A band only folds to ONE place if it stays inside a single Nyquist zone. The mains
        // harmonic band (99–181 Hz) crosses two of them at 50 Hz sampling and therefore lands on
        // several stretches of the spectrum at once — it cannot be given a location, and pretending
        // otherwise made it claim 0–22.5 Hz and swallow everything else. Found by a test.
        let lowZone = Int(band.lowHz / nyquist)
        let highZone = Int(band.highHz / nyquist)
        if band.widthHz >= nyquist || lowZone != highZone {
            return BandVisibility(
                bandID: band.id, visibility: .smeared, apparentCentreHz: apparent,
                hzFromTarget: distance,
                note: String(format: "Cannot be located at this sample rate. The band spans %.1f–%.1f Hz, which crosses a Nyquist boundary (%.1f Hz), so it folds onto several stretches of the sampled spectrum at once. It is not assigned any bins — and that means any part of this record could carry it.",
                             band.lowHz, band.highHz, nyquist))
        }

        let kind: Visibility
        if band.highHz <= nyquist { kind = .direct }
        else if band.lowHz >= nyquist { kind = .folded }
        else { kind = .straddling }

        var note: String
        switch kind {
        case .direct:
            note = "Below Nyquist — this band appears where it actually is."
        case .folded:
            note = String(format: "Folds to %.2f Hz at this sample rate. It has not gone away; it is wearing a different frequency.", apparent)
        case .straddling:
            note = String(format: "Straddles Nyquist (%.1f Hz). Part of the band appears directly and part folds back on top of it — the two are unseparable in this record.", nyquist)
        case .smeared:
            note = ""
        }
        if kind != .direct && distance < 2 {
            note += String(format: " ⚠️ It lands %.2f Hz from the %.2f Hz target.", distance, targetHz)
        }
        return BandVisibility(bandID: band.id, visibility: kind, apparentCentreHz: apparent,
                              hzFromTarget: distance, note: note)
    }

    /// The sample rate, from a candidate list, that keeps every anthropogenic band furthest from the
    /// target. Returned as advice with its reasoning, never applied automatically.
    static func recommendedRate(targetHz: Double,
                                candidates: [Double] = [25, 30, 40, 50, 64, 75, 100]) -> (rate: Double, reason: String) {
        var best = candidates.first ?? 100
        var bestScore = -Double.infinity
        for rate in candidates {
            guard rate > targetHz * 2.5 else { continue }
            var worst = Double.infinity
            for band in bands where band.family == .anthropogenic {
                let apparent = SignalCensus.aliasOf(band.centreHz, sampleRateHz: rate)
                worst = min(worst, abs(apparent - targetHz))
            }
            if worst > bestScore { bestScore = worst; best = rate }
        }
        let reason = String(format: "At %.0f Hz the nearest anthropogenic band lands %.1f Hz from the %.2f Hz target. Higher rates also widen the bandwidth available to short transients.",
                            best, bestScore, targetHz)
        return (best, reason)
    }
}
