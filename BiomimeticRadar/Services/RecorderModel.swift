import Combine
import Foundation
import UIKit

/// The whole iPhone app, in one small object.
///
/// **The phone is a sensor now.** On 2026-08-23 the app was cut back from six tabs of analysis
/// (spectrum, census, coupling, geometry, blinded experiment decks, results) to a single job:
/// acquire cleanly, and get the raw samples onto the Mac without losing any. Everything that
/// *interprets* the data — filtering, band attribution, cross-band coupling, lock-in, nulls —
/// happens in `serve.py`'s web viewer and `analysis/`, where it can be iterated on in seconds
/// instead of through a device build.
///
/// What that buys, concretely: the analysis can change without touching the phone; the phone has
/// far less that can break during a multi-hour run; and the raw record is identical either way,
/// because the wire format was already the export format.
///
/// This replaces the old `AppModel`, which is in git history at commit `94529ba` along with the
/// six views it drove. The analysis code it called is **not** deleted — `SignalProcessor`,
/// `SignalCensus`, `CrossBandCoupling`, `LightningCoupling` and the rest are still in
/// `Processing/`, still built and tested by the SwiftPM core (`swift test`), and are the reference
/// for the Python ports. They are simply no longer compiled into the app.
@MainActor
final class RecorderModel: ObservableObject {
    let sensor = SensorManager()
    let stream: StreamController
    let selfEmitter = SelfEmitter()

    /// The phone's own coded emitter — the one experiment feature kept, because it is the only
    /// positive control this rig has: without it, nothing can ever prove the Mac-side detector
    /// works end to end. Off by default; every chunk recorded while it runs is stamped `EMITTER-ON`
    /// with its carrier and code, and the Mac refuses to read such a chunk as evidence of anything
    /// external.
    @Published var emitter = EmitterSchedule()

    /// Live preflight over the last few seconds: is a magnet on the phone, is the phone still.
    @Published private(set) var preflight = GateReport()
    @Published private(set) var previewing = false

    private var preflightTimer: Timer?

    init() {
        stream = StreamController(sensor: sensor)
        stream.emitterStamp = { [weak self] in
            guard let self, self.emitter.isPhoneEmitting else { return nil }
            return StreamChunk.EmitterStamp(
                stamp: EmitterSchedule.stamp,
                transducer: self.emitter.transducer.rawValue,
                carrierHz: self.emitter.carrierHz,
                code: self.emitter.code,
                chipSeconds: self.emitter.chipSeconds,
                amplitude: self.emitter.amplitude)
        }
    }

    var preflightBlocks: Bool { preflight.blocks }

    // MARK: - preview (so the gates and the live numbers have something to read)

    /// A lightweight live view of the sensor when not streaming, so the operator can see the field
    /// and check the gates before committing to a run. Shares the sensor with the stream — starting
    /// or stopping one never disturbs the other.
    func startPreview() {
        guard !previewing else { return }
        previewing = true
        _ = sensor.start(
            sampleRate: stream.settings.sampleRateHz, includeLocation: false,
            attitude: true, owner: .preview)
        preflightTimer?.invalidate()
        preflightTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPreflight() }
        }
    }

    func stopPreview() {
        guard previewing else { return }
        previewing = false
        preflightTimer?.invalidate()
        preflightTimer = nil
        sensor.stop(owner: .preview)
    }

    func refreshPreflight() {
        let recent = sensor.recentSamples
        guard recent.count >= 8 else {
            preflight = GateReport()
            return
        }
        preflight = QualityGates.preflight(samples: Array(recent.suffix(200)))
    }

    // MARK: - streaming

    func startStreaming() {
        // The emitter, if the operator turned it on, plays for as long as the stream runs.
        if emitter.isPhoneEmitting {
            selfEmitter.start(emitter, duration: .greatestFiniteMagnitude)
        }
        stream.start()
        // The preview timer keeps the gates live during the run; the sensor is already held.
        if !previewing { startPreview() }
    }

    func stopStreaming() {
        selfEmitter.stop()
        stream.stop()
    }
}
