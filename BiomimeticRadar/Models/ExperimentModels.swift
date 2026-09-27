import CryptoKit
import Foundation

// Vector3, Quaternion and SensorSample live in `SensorModels.swift` — the lean set the STREAMING
// app needs. Everything in this file is analysis-side and is excluded from the app target.

enum ExperimentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case baseline = "Baseline"
    case knownFrequency = "Known frequency"
    case matchedCode = "Matched code"
    case multiRepresentation = "Multi-representation"
    case geometry = "Geometry"
    case lightning = "Lightning / Q-burst"
    case controlledMotion = "Controlled motion"
    var id: String { rawValue }
}

enum GroundingCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case barefoot, shoes, dirt, wetSoil = "wet soil", drySoil = "dry soil", sand
    case wetSand = "wet sand", concrete, indoorFloor = "indoor floor"
    case electricallyGrounded = "electrically grounded", insulated, unknown
    var id: String { rawValue }
}

enum MotionCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case stationary, periodicRotation = "periodic rotation", periodicTranslation = "periodic translation"
    case walking, breathingSynchronized = "breathing synchronized", unknown
    var id: String { rawValue }
}

enum TrialState: String, Codable, CaseIterable, Sendable { case transmitterOn, transmitterOff, sham }
enum ResultTier: String, Codable, Sendable { case exploratory, preregistered, significant, replicated }

/// Which channel the analysis runs on.
///
/// The protocol used to declare seven representations in a string array and analyse `magnitude`
/// regardless. A control that does nothing is worse than one that is absent, so this is a real
/// choice with a real effect — and `magnitude` remains the default for a stated reason: the
/// magnitude of a vector is rotation-invariant, so it is the one channel that does not turn a
/// rotating phone into a signal.
enum Representation: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The default since the first exports were audited. Each axis is filtered, locked-in and
    /// matched on its own and the three are combined COHERENTLY afterwards (vector amplitude,
    /// a 6-degree-of-freedom F-test, a 3-axis matched statistic). The norm |B| throws away exactly
    /// what lock-in and phase tracking exist to use — polarity and phase — and, when the coded
    /// field is not small against the standing field, projects rather than measures it.
    case vector = "Per-axis vector (X·Y·Z, coherent)"
    case magnitude = "Magnitude |B|"
    case axisX = "Axis X"
    case axisY = "Axis Y"
    case axisZ = "Axis Z"
    case earthZ = "Earth-frame Z"
    case derivative = "Derivative d|B|/dt"
    var id: String { rawValue }

    var note: String {
        switch self {
        case .vector:
            "Each axis analysed on its own terms, then combined coherently. Keeps polarity and phase. Sensitive to rotation — the motion gate exists for that. The default."
        case .magnitude:
            "Rotation-invariant, so a turning phone does not write signal into it — and it discards polarity and phase, which is why it is no longer the default. Kept for display and comparison."
        case .axisX, .axisY, .axisZ: "A single device axis. Sensitive to direction — and therefore to every rotation of the phone."
        case .earthZ:
            "The field rotated into the Earth frame using the IMU attitude. A genuine external vector should be steady here while a device-fixed artefact is not."
        case .derivative: "Rate of change. Suppresses drift and emphasises transients; multiplies high-frequency noise by frequency."
        }
    }
}

struct ProcessingOptions: Codable, Sendable, Equatable {
    /// Run the lock-in against the REAL sample timestamps rather than assuming a uniform clock.
    /// Core Motion's delivery jitters, and jitter on the reference is phase noise no integration
    /// removes. On by default; off exists so the cost can be measured rather than asserted.
    var timestampCorrection = true
    var detrend = true
    var bandpass = true
    var notch = false
    var lockIn = true
    var matchedFilter = true
    /// Lock in at 2f and 3f as well, and report the harmonic ratios. A coded carrier from a linear
    /// source has little; a mechanical or switching artefact usually has a lot.
    var harmonicAnalysis = true
    /// Report the lock-in phase over successive windows. A real external carrier drifts slowly in
    /// phase; a source sharing the phone's own clock does not drift at all.
    var phaseTracking = true
    /// Average successive code periods and report the √N the average actually achieved.
    var coherentAveraging = true
    var shuffleTesting = true
    /// Derive the passband from the CODE rather than from the two cutoffs below.
    ///
    /// A phase-reversal code with chip duration `Tc` spreads its energy over roughly `carrier ± 1/Tc`.
    /// The shipped cutoffs were 7.8–8.8 Hz — a 1 Hz window around an 8.3 Hz carrier whose 0.25 s
    /// chips need ±4 Hz. The filter was removing the code the matched filter then went looking for,
    /// and a test that fed the analysis a perfect noiseless copy of its own reference is what found
    /// it. On by default; turn it off to set the band by hand and the warning below still fires.
    var autoBandwidthFromCode = true
    var lowCutoffHz = 7.8
    var highCutoffHz = 8.8
    var notchHz = 60.0

    /// Removed rather than left as controls that did nothing:
    /// `vectorNormalization` (now `ExperimentProtocol.representation`), `crossCorrelation` (the
    /// matched filter IS the cross-correlation), `orientationMatching` (now the Signals tab's
    /// motion coupling, measured against attitude), `statistics` (Benjamini–Hochberg always runs).
    static let removedControls = [
        "vectorNormalization", "crossCorrelation",
        "orientationMatching", "statistics",
    ]
}

struct ExperimentProtocol: Codable, Sendable, Equatable {
    var id = UUID()
    var name = "8.3 Hz coded recovery"
    var mode: ExperimentMode = .matchedCode
    var targetFrequencyHz = 8.3
    /// 100 Hz, not 50.
    ///
    /// At 50 Hz, 60 Hz mains folds to exactly 10.00 Hz — inside the 8–13 Hz human alpha band and
    /// 1.7 Hz from this target. At 100 Hz it folds to 40 Hz, clear of every ELF band in the
    /// registry. The census will still warn if a fold lands somewhere it matters, because the
    /// operator can change this.
    var sampleRateHz = 100.0
    var durationSeconds = 60.0
    var code = [1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0]
    var chipDurationSeconds = 0.25
    var blinded = true
    var preregistered = true
    var analysisWindowStart = 0.0
    var analysisWindowEnd = 60.0
    var minimumTrialsBeforeReveal = 10
    var representation: Representation = .vector
    var processing = ProcessingOptions()
    /// Band policies for the census and the coupling tests. Nothing is excluded by default.
    var bandPolicies: [String: BandRegistry.Policy] = BandRegistry.defaultPolicies
}

/// NWS publishes every forecast value against an ISO-8601 interval (`2026-08-22T12:00:00+00:00/PT3H`).
/// Deciding which block "now" falls in is the whole difference between a forecast for this hour and
/// one for tomorrow, so the parser lives in the testable core rather than inside the networking layer.
enum ISOInterval {
    static func parse(_ validTime: String) -> (start: Date, end: Date)? {
        let parts = validTime.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let start = formatter.date(from: String(parts[0])) else { return nil }
        return (start, start.addingTimeInterval(duration(String(parts[1]))))
    }

    /// Minimal reader for the `PnDTnH` forms NWS actually emits. `M` is months before a `T` and
    /// minutes after it — getting that backwards silently shifts a forecast by weeks.
    static func duration(_ text: String) -> TimeInterval {
        guard text.hasPrefix("P") else { return 0 }
        var seconds = 0.0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character == "T" {
                inTime = true
                continue
            }
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            let value = Double(number) ?? 0
            number = ""
            switch character {
            case "D": seconds += value * 86_400
            case "H": seconds += value * 3_600
            case "M": seconds += inTime ? value * 60 : value * 2_592_000
            case "S": seconds += value
            case "W": seconds += value * 604_800
            case "Y": seconds += value * 31_536_000
            default: break
            }
        }
        return seconds
    }
}

/// Where a context value came from. `observed` and `forecast` never merge into one number, and
/// `unavailable` is a stated outcome rather than a missing key.
enum ContextTier: String, Codable, Sendable { case observed, forecast, unavailable }

struct KpReading: Codable, Sendable, Equatable {
    let timeTag: String
    let kp: Double
    let kp24hMax: Double
    let gScale: Int
    /// NOAA G-scale. Same thresholds as `geostorm-trends/lib/providers/gfz-kp.js::gScale`.
    static func gScale(_ kp: Double) -> Int {
        kp >= 9 ? 5 : kp >= 8 ? 4 : kp >= 7 ? 3 : kp >= 6 ? 2 : kp >= 5 ? 1 : 0
    }
    var tier: ContextTier { .observed }
}

struct ThunderOutlook: Codable, Sendable, Equatable {
    let office: String
    let gridX: Int
    let gridY: Int
    /// Percent for the block covering now. `nil` means the grid published none for this hour —
    /// which is not the same as zero, and is rendered differently.
    let probabilityPercent: Double?
    let validTime: String?
    let maximumPercentInForecast: Double?
    let activeThunderAlerts: [String]
    var tier: ContextTier { .forecast }
}

/// Geomagnetic and thunderstorm context captured at record time. Every field is optional and every
/// absence carries a reason in `notes` — a session that could not reach the network must say so
/// rather than look like a quiet day.
struct SpaceWeatherContext: Codable, Sendable, Equatable {
    var fetchedAt: Date?
    var kp: KpReading?
    var thunder: ThunderOutlook?
    var notes: [String] = []
    var isEmpty: Bool { kp == nil && thunder == nil }
    static let sources = [
        "NOAA SWPC planetary K index (1-minute estimate) — public domain.",
        "NOAA/NWS api.weather.gov gridpoint probabilityOfThunder and active alerts — public domain, US-only.",
    ]
}

struct SessionMetadata: Codable, Sendable {
    var experimentID: UUID
    var blindedID: String
    var startedAt: Date
    var endedAt: Date?
    var protocolSnapshot: ExperimentProtocol
    var grounding: GroundingCondition
    var motion: MotionCondition
    var notes: String
    var deviceModel: String
    var systemVersion: String
    var achievedMagnetometerRateHz: Double
    var achievedMotionRateHz: Double
    var codeSHA256: String
    var analysisVersion: String
    var eventTimestamps: [Date]
    /// The whole randomised deck and which entry this session used — present ONLY once the session
    /// is unblinded (revealed, or never blinded). While blinded it is nil in the export and the
    /// mapping lives sealed in `blindSeal`, so the file the analyst reads cannot leak the arm.
    var randomizedTrials: [TrialState]?
    var trialIndex: Int?
    /// Non-nil when the phone was emitting its own coded signal — and, like the deck, withheld while
    /// blinded, because the emitter block names the arm as loudly as the deck does.
    var emitter: EmitterSchedule?
    /// Present while blinded: a SHA-256 commitment to the sealed deck+trial+emitter, so unblinding
    /// later is verifiable (the revealed values must hash to this) and the blind cannot be
    /// rewritten after the fact. The plaintext is never in the export.
    var blindSeal: String?
    var blinded: Bool = false
    /// Context at record time. Never analysed in-app — it is a covariate for the offline join.
    var spaceWeather: SpaceWeatherContext?
}

/// The sealed blind: the arm assignment, kept out of the export and committed to by a hash.
struct BlindSeal: Codable, Sendable, Equatable {
    var randomizedTrials: [TrialState]
    var trialIndex: Int
    var emitter: EmitterSchedule?
    /// The commitment written into the export. SHA-256 over a canonical encoding of the fields
    /// above plus the blinded ID, so the reveal is verifiable and tamper-evident.
    func commitment(blindedID: String) -> String {
        let deck = randomizedTrials.map(\.rawValue).joined(separator: ",")
        let emit = emitter.map { "\($0.source.rawValue):\($0.transducer.rawValue):\($0.amplitude)" } ?? "none"
        let canonical = "\(blindedID)|\(deck)|\(trialIndex)|\(emit)"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SpectrumPoint: Identifiable, Codable, Sendable, Equatable {
    var id: Double { frequency }
    let frequency: Double
    let power: Double
}

struct TracePoint: Identifiable, Codable, Sendable, Equatable {
    var id: Double { time }
    let time: Double
    let value: Double
}

struct LockInResult: Codable, Sendable, Equatable {
    var inPhase: Double = 0
    var quadrature: Double = 0
    var amplitude: Double = 0
    var phaseRadians: Double = 0
    var snrDB: Double = 0
    /// `1 − pValue`, kept for display only. It is NOT an independent number.
    var confidence: Double = 0
    /// Exact F-test p-value for the fitted sinusoid against the residual. This is what goes into
    /// the multiple-comparison correction; the old `1 − confidence` was not a p-value at all.
    var pValue: Double = 1
}

struct HarmonicReport: Codable, Sendable, Equatable {
    var fundamentalAmplitude: Double = 0
    var secondHarmonicDB: Double = .nan
    var thirdHarmonicDB: Double = .nan
}

struct AveragingReport: Codable, Sendable, Equatable {
    var epochs: Int = 0
    var idealGainDB: Double = 0
    /// Clamped to `idealGainDB` when the raw figure exceeded it — see `exceedsIdeal`.
    var achievedGainDB: Double = 0
    var note: String = ""
    /// RMS of the ±average (alternating-sign sum): the noise that survives averaging.
    var residualNoiseRMS: Double = 0
    /// Median single-epoch RMS, first epoch excluded (filter settling).
    var medianEpochRMS: Double = 0
    /// RMS of the plain average — what is left of anything phase-locked plus the residual noise.
    var averagedEpochRMS: Double = 0
    /// True when the raw achieved gain beat √N, which noise cannot do: a diagnostic error, not a result.
    var exceedsIdeal: Bool = false
    var uncappedAchievedGainDB: Double = 0
}

struct MatchedFilterResult: Codable, Sendable, Equatable {
    var bestLagSamples = 0
    var peakCorrelation = 0.0
    var pValue = 1.0
    var falseAlarmProbability = 1.0
    var nullMean = 0.0
    var nullUpper95 = 0.0
    var correlationTrace: [TracePoint] = []
    var nullDistribution: [Double] = []
}

/// Tesla-referenced sensitivity: what this run could actually have detected.
struct Calibration: Codable, Sendable, Equatable {
    /// Amplitude spectral density of the noise AT the target band, nanotesla per √Hz. Measured from
    /// the residual PSD around the target, excluding the target's own bins.
    var noiseFloorNtPerRootHz: Double = 0
    /// The minimum coherent amplitude, in nanotesla, distinguishable from that noise over the dwell
    /// actually recorded, at the stated one-sided alpha. `MDF = z(alpha) · ASD · √(2/T)`.
    var minimumDetectableFieldNt: Double = 0
    /// The one-sided significance the MDF is quoted at.
    var alpha: Double = 0.05
    /// Dwell used, seconds.
    var dwellSeconds: Double = 0
    /// The field the external coil implies at the sensor, nanotesla — nil unless a coil session.
    var impliedCoilFieldNt: Double? = nil
    var hasFloor: Bool { noiseFloorNtPerRootHz > 0 }
}

struct BaselineReport: Codable, Sendable, Equatable {
    var mean = 0.0
    var variance = 0.0
    var rmsNoise = 0.0
    var driftPerSecond = 0.0
    var dominantFrequency = 0.0
    var allanDeviation = 0.0
}

/// One axis of the per-axis analysis: its own lock-in and its own matched-filter peak.
struct AxisResult: Codable, Sendable, Equatable {
    var axis: String
    var lockIn = LockInResult()
    var matchedPeakCorrelation = 0.0
    var matchedPValue = 1.0
}

/// The three axes combined coherently.
struct VectorResult: Codable, Sendable, Equatable {
    /// √(Ax² + Ay² + Az²) in µT — the amplitude of the coded field as a vector.
    var amplitude = 0.0
    /// F-test with six numerator degrees of freedom (three axes × I/Q) against the pooled residual.
    var pValue = 1.0
    var dominantAxis = "x"
    /// Unit direction of the coded field in the device frame, signed by each axis's in-phase part.
    var direction = Vector3.zero
}

struct AnalysisResult: Codable, Sendable, Equatable {
    var lockIn = LockInResult()
    var matched = MatchedFilterResult()
    var baseline = BaselineReport()
    var spectrum: [SpectrumPoint] = []
    var rawTrace: [TracePoint] = []
    var extractedTrace: [TracePoint] = []
    var correctedPValues: [Double] = []
    var processingGainDB = 0.0
    var resultTier: ResultTier = .exploratory
    var passedNullControls = false
    var warnings: [String] = []
    var harmonics: HarmonicReport?
    var phaseTrace: [TracePoint] = []
    var averaging: AveragingReport?
    /// True when the phone was emitting its own coded signal. Caps the tier and is rendered
    /// wherever a result is shown.
    var emitterWasRunning = false
    var representation: Representation = .vector
    /// Per-axis results, present whenever the representation is `.vector`.
    var axes: [AxisResult] = []
    var vector: VectorResult?
    /// The data-integrity gates over this run. A failing (non-informational) gate caps the tier at
    /// `exploratory` no matter how clean the detection looks.
    var gates = GateReport()
    /// Tesla-referenced sensitivity for this run — noise floor and minimum detectable field.
    var calibration = Calibration()
}
