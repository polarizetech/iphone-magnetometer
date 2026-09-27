import CoreLocation
import CoreMotion
import Combine
import Foundation
import UIKit

@MainActor
final class SensorManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var latestSample: SensorSample?
    @Published private(set) var recentSamples: [SensorSample] = []
    @Published private(set) var magnetometerRateHz = 0.0
    @Published private(set) var motionRateHz = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    /// Additional consumers of every sample. The always-on stream is one; nothing else is yet.
    private var taps: [UUID: (SensorSample) -> Void] = [:]
    /// Who has asked for the sensor to be running. The hardware stops only when this empties —
    /// so an experiment ending (`stop(owner: .experiment)`) cannot kill an always-on stream that is
    /// sharing the same magnetometer, and vice versa.
    private(set) var owners: Set<Owner> = []
    /// The rate the hardware is actually configured for. The first owner sets it; a second owner
    /// asking for something else is told so rather than silently re-timing the first one's run.
    private(set) var configuredRateHz = 0.0
    private(set) var attitudeEnabled = true
    private let motion = CMMotionManager()
    private let sensorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FieldLab.SensorQueue"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let location = CLLocationManager()
    private var latestMotion: CMDeviceMotion?
    private var latestLocation: CLLocation?
    /// The owners that asked for GPS. Location runs only while one of them holds the sensor, so
    /// switching "Record GPS" off takes effect at the next start even while the preview keeps running.
    private var locationOwners: Set<Owner> = []
    private var magnetometerTimes: [Double] = []
    private var motionTimes: [Double] = []

    override init() {
        super.init()
        location.delegate = self
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    enum Owner: String, Sendable { case experiment, stream, preview }

    @discardableResult
    func addTap(_ tap: @escaping (SensorSample) -> Void) -> UUID {
        let id = UUID()
        taps[id] = tap
        return id
    }
    func removeTap(_ id: UUID) { taps[id] = nil }

    /// Start, or join, the running acquisition.
    ///
    /// - Returns: `nil` if the hardware is now running at `sampleRate`, or a note explaining that it
    ///   is already running at a different rate for another measurement (and was left alone).
    ///
    /// The preview is a viewer, not a measurement: a measurement asking for a different rate
    /// re-times the hardware instead of inheriting the preview's. Found 2026-09-16, when a stream
    /// set to 64 Hz ran at ~101 Hz for 14 minutes because the preview had started the sensor at
    /// 100 Hz, and the only sign was an orange footnote.
    @discardableResult
    func start(
        sampleRate: Double = 50, includeLocation: Bool = false, attitude: Bool = true,
        owner: Owner = .experiment
    ) -> String? {
        guard motion.isMagnetometerAvailable else {
            errorMessage = "A physical iPhone with a magnetometer is required."
            return errorMessage
        }
        let wanted = max(1, min(100, sampleRate))
        if isRunning {
            owners.insert(owner)
            setLocation(includeLocation, for: owner)
            let rateDiffers = abs(configuredRateHz - wanted) > 0.01
            // Over the preview alone, a measurement's rate AND its attitude choice win. Keeping the
            // preview's gyro left "mag only" streams paying for the gyro they had switched off.
            if owner != .preview && owners.subtracting([owner, .preview]).isEmpty
                && (rateDiffers || attitude != attitudeEnabled)
            {
                motion.stopMagnetometerUpdates()
                motion.stopDeviceMotionUpdates()
                configure(rate: wanted, attitude: attitude)
                return nil
            }
            guard rateDiffers else { return nil }
            return String(
                format: "Sensor already running at %.0f Hz for %@; kept that rate", configuredRateHz,
                owners.subtracting([owner]).map(\.rawValue).joined(separator: ", "))
        }
        errorMessage = nil
        owners = [owner]
        locationOwners = []
        setLocation(includeLocation, for: owner)
        configure(rate: wanted, attitude: attitude)
        return nil
    }

    /// Set the update intervals and (re)start the magnetometer and device-motion updates.
    private func configure(rate: Double, attitude: Bool) {
        configuredRateHz = rate
        attitudeEnabled = attitude
        let interval = 1 / rate
        motion.magnetometerUpdateInterval = interval
        motion.deviceMotionUpdateInterval = interval
        magnetometerTimes.removeAll(keepingCapacity: true)
        motionTimes.removeAll(keepingCapacity: true)
        recentSamples.removeAll(keepingCapacity: true)
        latestMotion = nil
        if motion.isDeviceMotionAvailable && attitude {
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: sensorQueue) { [weak self] value, _ in
                guard let self, let value else { return }
                Task { @MainActor in
                    self.latestMotion = value
                    self.motionTimes.append(value.timestamp)
                    self.motionTimes = Array(self.motionTimes.suffix(100))
                    self.motionRateHz = Self.rate(from: self.motionTimes)
                }
            }
        }
        motion.startMagnetometerUpdates(to: sensorQueue) { [weak self] value, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.errorMessage = error.localizedDescription }
                return
            }
            guard let value else { return }
            Task { @MainActor in self.accept(value) }
        }
        isRunning = true
    }

    /// Release one owner's hold. The hardware stops only when the last owner lets go.
    func stop(owner: Owner = .experiment) {
        owners.remove(owner)
        setLocation(false, for: owner)
        if owners == [.preview] && !attitudeEnabled {
            // The measurement had the gyro off; the preview's gates read attitude, so give it back.
            motion.stopMagnetometerUpdates()
            configure(rate: configuredRateHz, attitude: true)
            return
        }
        guard owners.isEmpty else { return }
        motion.stopMagnetometerUpdates()
        motion.stopDeviceMotionUpdates()
        latestMotion = nil
        isRunning = false
    }

    /// Start or stop GPS for one owner. With no owner wanting it, updates stop and the last fix is
    /// dropped, so no later sample can carry a position.
    private func setLocation(_ wanted: Bool, for owner: Owner) {
        if wanted {
            let first = locationOwners.isEmpty
            locationOwners.insert(owner)
            if first {
                location.requestWhenInUseAuthorization()
                location.startUpdatingLocation()
            }
        } else if locationOwners.remove(owner) != nil, locationOwners.isEmpty {
            location.stopUpdatingLocation()
            latestLocation = nil
        }
    }

    private func accept(_ magnetometer: CMMagnetometerData) {
        let device = latestMotion
        let q = device?.attitude.quaternion
        let coordinate = magnetometer.magneticField
        let sample = SensorSample(
            monotonicTime: magnetometer.timestamp, wallTime: Date(),
            magnetic: Vector3(x: coordinate.x, y: coordinate.y, z: coordinate.z),
            acceleration: Vector3(
                x: device?.userAcceleration.x ?? 0,
                y: device?.userAcceleration.y ?? 0,
                z: device?.userAcceleration.z ?? 0),
            rotationRate: Vector3(
                x: device?.rotationRate.x ?? 0,
                y: device?.rotationRate.y ?? 0,
                z: device?.rotationRate.z ?? 0),
            attitude: Quaternion(x: q?.x ?? 0, y: q?.y ?? 0, z: q?.z ?? 0, w: q?.w ?? 1),
            orientation: UIDevice.current.orientation.fieldLabName,
            latitude: latestLocation?.coordinate.latitude,
            longitude: latestLocation?.coordinate.longitude
        )
        magnetometerTimes.append(magnetometer.timestamp)
        magnetometerTimes = Array(magnetometerTimes.suffix(100))
        magnetometerRateHz = Self.rate(from: magnetometerTimes)
        latestSample = sample
        recentSamples.append(sample)
        recentSamples = Array(recentSamples.suffix(500))
        for tap in taps.values { tap(sample) }
    }

    private static func rate(from times: [Double]) -> Double {
        guard times.count > 2 else { return 0 }
        let duration = times.last! - times.first!
        return duration > 0 ? Double(times.count - 1) / duration : 0
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locationOwners.isEmpty else { return }  // a fix delivered after GPS was switched off
        latestLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Location unavailable: \(error.localizedDescription)"
    }
}

private extension UIDeviceOrientation {
    var fieldLabName: String {
        switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .faceUp: "faceUp"
        case .faceDown: "faceDown"
        default: "unknown"
        }
    }
}
