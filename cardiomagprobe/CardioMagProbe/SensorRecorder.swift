import CoreMotion
import Foundation

struct MotionFrame {
    let timestamp: TimeInterval
    let mag: (Double, Double, Double)
    let calibratedMag: (Double, Double, Double)?
    let accel: (Double, Double, Double)
    let gyro: (Double, Double, Double)
    let attitude: (Double, Double, Double, Double)?
}

final class SensorRecorder {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "CardioMag.CoreMotion"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var accel = (0.0, 0.0, 0.0)
    private var gyro = (0.0, 0.0, 0.0)
    private var calibrated: (Double, Double, Double)?
    private var attitude: (Double, Double, Double, Double)?
    private(set) var requestedHz = 50.0
    var onFrame: ((MotionFrame) -> Void)?
    var onError: ((String) -> Void)?

    var isAvailable: Bool { manager.isMagnetometerAvailable }

    func start(rateHz: Double = 50) {
        requestedHz = rateHz
        let interval = 1 / rateHz
        manager.magnetometerUpdateInterval = interval
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.deviceMotionUpdateInterval = interval

        if manager.isAccelerometerAvailable {
            manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                self?.accel = (a.x, a.y, a.z)
            }
        }
        if manager.isGyroAvailable {
            manager.startGyroUpdates(to: queue) { [weak self] data, _ in
                guard let g = data?.rotationRate else { return }
                self?.gyro = (g.x, g.y, g.z)
            }
        }
        if manager.isDeviceMotionAvailable {
            manager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: queue) { [weak self] data, _ in
                guard let d = data else { return }
                self?.calibrated = (d.magneticField.field.x, d.magneticField.field.y, d.magneticField.field.z)
                let q = d.attitude.quaternion
                self?.attitude = (q.x, q.y, q.z, q.w)
            }
        }
        guard manager.isMagnetometerAvailable else {
            onError?("Raw magnetometer is not available on this device.")
            return
        }
        manager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.onError?(error.localizedDescription)
                return
            }
            guard let d = data else { return }
            self.onFrame?(
                MotionFrame(
                    timestamp: d.timestamp,
                    mag: (d.magneticField.x, d.magneticField.y, d.magneticField.z),
                    calibratedMag: self.calibrated,
                    accel: self.accel,
                    gyro: self.gyro,
                    attitude: self.attitude
                ))
        }
    }

    func stop() {
        manager.stopMagnetometerUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopDeviceMotionUpdates()
    }
}
