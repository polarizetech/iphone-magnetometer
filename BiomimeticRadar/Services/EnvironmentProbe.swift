import CoreMotion
import Foundation
import UIKit

/// Everything else the phone knows that helps explain what the magnetometer did.
///
/// The magnetometer is the measurement. These are the **covariates** — the things that, when a
/// number moves, tell you whether the world moved or the phone did. They are sampled once per
/// chunk rather than per sample, because none of them changes at 100 Hz and putting them in the
/// CSV would change a schema the export, the stream and `analysis/session.py` all share.
///
/// Why each one is here, since a covariate nobody can use is just noise in the metadata:
///
/// * **Thermal state and battery** — a warm magnetometer drifts, and charging current has a field.
///   Both are in `INTERFERENCE.md` as named interference sources; recording them turns "the
///   baseline wandered" into "the baseline wandered while the phone was charging and got warm".
/// * **Barometric pressure** — a genuine weather covariate, and this project cares about
///   thunderstorms. A falling barometer is the cheapest storm indicator the phone has, and it is
///   local in a way an NWS grid forecast is not.
/// * **Relative altitude** — free with the barometer, and it says whether the phone was carried up
///   or down stairs during an always-on run, which is motion the gyro may have missed.
/// * **Low-power mode** — iOS throttles background work in low-power mode, which starves the
///   sensor. When the achieved rate drops, this is the first thing to check.
///
/// Nothing here is a signal source. If one of these ever becomes a *predictor* of something in the
/// magnetic record, that is a finding about the phone, not about the world.
@MainActor
final class EnvironmentProbe {
    private let altimeter = CMAltimeter()
    private var latestPressureKPa: Double?
    private var latestAltitudeM: Double?
    private var altimeterStarted = false
    private(set) var altimeterNote: String?

    /// The reading's *type* lives with the wire format in `StreamChunk.EnvironmentReading`, because
    /// the schema is the contract with the Mac and the Mac's reader must compile without UIKit.
    typealias Reading = StreamChunk.EnvironmentReading

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Start the barometer. Safe to call repeatedly; it reports rather than throws when unavailable.
    func start() {
        guard !altimeterStarted else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            altimeterNote = "No barometer on this device — pressure and relative altitude are absent, not zero."
            return
        }
        if CMAltimeter.authorizationStatus() == .denied || CMAltimeter.authorizationStatus() == .restricted {
            altimeterNote = "Motion & Fitness access is off, so the barometer is unavailable. Settings ▸ Privacy ▸ Motion & Fitness."
            return
        }
        altimeterStarted = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.altimeterNote = "Barometer error: \(error.localizedDescription)"
                return
            }
            guard let data else { return }
            self.latestPressureKPa = data.pressure.doubleValue
            self.latestAltitudeM = data.relativeAltitude.doubleValue
            self.altimeterNote = nil
        }
    }

    func stop() {
        guard altimeterStarted else { return }
        altimeter.stopRelativeAltitudeUpdates()
        altimeterStarted = false
    }

    func read() -> Reading {
        let device = UIDevice.current
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Reading(
            batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
            batteryState: state,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermal,
            pressureKPa: latestPressureKPa,
            relativeAltitudeM: latestAltitudeM,
            freeDiskBytes: Self.freeDiskBytes())
    }

    /// Free space on the volume the spool lives on. A full disk is the one failure that makes a
    /// recorder look like it is working while it keeps nothing — `eeg-bridge`'s DURABILITY.md
    /// calls out exactly this, and it is cheap to just report it every chunk.
    static func freeDiskBytes() -> Int? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }
}
