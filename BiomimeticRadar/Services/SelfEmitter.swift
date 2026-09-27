import CoreHaptics
import Foundation
import UIKit

/// Drives the phone's own controllable loads with the experiment's coded carrier, so the detector
/// has something it is guaranteed to be able to find.
///
/// **Read `EmitterSchedule`'s documentation before using this.** A session recorded with the
/// emitter running measures this phone and can never support a claim about an external signal. That
/// rule is enforced upstream — `SignalProcessor.analyze` caps the tier and stamps the warnings, and
/// `SessionMetadata.emitter` carries it into the export — not here.
///
/// Nothing in this file is quiet: haptics are audible and palpable, CPU load warms the device (and
/// a warm magnetometer drifts, which the census will show), and brightness modulation is visible.
/// That is deliberate. An operator should always know the phone is talking.
@MainActor
final class SelfEmitter: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"

    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var loadTask: Task<Void, Never>?
    private var brightnessTimer: Timer?
    private var originalBrightness: CGFloat = UIScreen.main.brightness

    static var hapticsAvailable: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    func start(_ schedule: EmitterSchedule, duration: Double) {
        stop()
        guard schedule.isRunning else { return }
        switch schedule.transducer {
        case .none: return
        case .haptics: startHaptics(schedule, duration: duration)
        case .cpuLoad: startLoad(schedule, duration: duration)
        case .screenBrightness: startBrightness(schedule, duration: duration)
        }
        isRunning = true
    }

    func stop() {
        player = nil
        try? engine?.stop()
        engine = nil
        loadTask?.cancel()
        loadTask = nil
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        if isRunning { UIScreen.main.brightness = originalBrightness }
        isRunning = false
        status = "Idle"
    }

    // MARK: - transducers

    /// One transient per carrier cycle at the positive peak, with the code carried as intensity.
    /// A haptic pulse has no polarity, so the code rides as amplitude around a mid level — which is
    /// bipolar again once the analysis detrends.
    private func startHaptics(_ schedule: EmitterSchedule, duration: Double) {
        guard Self.hapticsAvailable else {
            status = "This device has no haptic engine. Use CPU load instead."
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            try engine.start()
            self.engine = engine

            let pulses = schedule.pulses(duration: duration)
            let events = pulses.map { pulse in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(pulse.intensity)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
                    ], relativeTime: pulse.time)
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            player = try engine.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
            status = String(
                format: "Haptics: %d pulses at %.2f Hz for %.0f s", events.count,
                schedule.carrierHz, duration)
        } catch {
            status = "Haptic engine failed: \(error.localizedDescription)"
            isRunning = false
        }
    }

    /// Duty-cycled processor load. The PMIC current follows the duty cycle and the current has a
    /// field. Weakest of the three, and the only one that is silent.
    private func startLoad(_ schedule: EmitterSchedule, duration: Double) {
        status = String(format: "CPU load modulated at %.2f Hz for %.0f s", schedule.carrierHz, duration)
        loadTask = Task.detached(priority: .userInitiated) {
            let start = Date()
            let slice = 1.0 / (schedule.carrierHz * 16)  // 16 steps per carrier cycle
            while !Task.isCancelled, Date().timeIntervalSince(start) < duration {
                let t = Date().timeIntervalSince(start)
                let duty = schedule.unipolarDrive(at: t)
                let busy = slice * duty
                let deadline = Date().addingTimeInterval(busy)
                var accumulator = 0.0
                while Date() < deadline { accumulator += sqrt(accumulator + 1.0) }
                _ = accumulator
                let idle = slice - busy
                if idle > 0 { try? await Task.sleep(nanoseconds: UInt64(idle * 1e9)) }
            }
        }
    }

    /// Backlight current. Visible to the operator, so it cannot be used blind — offered because it
    /// is the one transducer whose emission an operator can see happening.
    private func startBrightness(_ schedule: EmitterSchedule, duration: Double) {
        originalBrightness = UIScreen.main.brightness
        status = String(format: "Backlight modulated at %.2f Hz for %.0f s", schedule.carrierHz, duration)
        let start = Date()
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 1 / (schedule.carrierHz * 8), repeats: true) { [weak self] timer in
            let t = Date().timeIntervalSince(start)
            guard t < duration else {
                timer.invalidate()
                Task { @MainActor in self?.stop() }
                return
            }
            // Held above 0.25 so the screen never goes black, and capped so it never blinds anyone.
            UIScreen.main.brightness = 0.25 + 0.5 * CGFloat(schedule.unipolarDrive(at: t))
        }
    }
}
