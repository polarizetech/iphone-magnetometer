import Foundation

/// The value types the recorder needs, and nothing else.
///
/// Split out of `ExperimentModels.swift` on 2026-08-23 when the iPhone app was cut back to a pure
/// recorder/streamer. The app target compiles **only** this file's models: a sample, and the two
/// small vector types it is made of. Everything analysis-side — protocols, results, tiers, session
/// metadata — stays in `ExperimentModels.swift`, which the app no longer builds and the Mac now
/// owns. Keeping the split explicit is what lets the phone stay a sensor.

struct Vector3: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = Vector3(x: 0, y: 0, z: 0)
    var magnitude: Double { sqrt(x * x + y * y + z * z) }
}

struct Quaternion: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double
    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    /// Rotate a device-frame vector into the Earth frame.
    ///
    /// The one implementation in the app: `MotionCompensator` and `SignalProcessor.channel(.earthZ)`
    /// both call this rather than carrying a copy, because two quaternion rotations that disagree
    /// would be a bug nobody could see.
    func rotate(_ vector: Vector3) -> Vector3 {
        let ix = w * vector.x + y * vector.z - z * vector.y
        let iy = w * vector.y + z * vector.x - x * vector.z
        let iz = w * vector.z + x * vector.y - y * vector.x
        let iw = -x * vector.x - y * vector.y - z * vector.z
        return Vector3(
            x: ix * w + iw * -x + iy * -z - iz * -y,
            y: iy * w + iw * -y + iz * -x - ix * -z,
            z: iz * w + iw * -z + ix * -y - iy * -x)
    }
}

struct SensorSample: Codable, Sendable, Identifiable {
    let id: UUID
    let monotonicTime: Double
    let wallTime: Date
    let magnetic: Vector3
    let acceleration: Vector3
    let rotationRate: Vector3
    let attitude: Quaternion
    let orientation: String
    let latitude: Double?
    let longitude: Double?

    init(
        id: UUID = UUID(), monotonicTime: Double, wallTime: Date, magnetic: Vector3,
        acceleration: Vector3 = .zero, rotationRate: Vector3 = .zero,
        attitude: Quaternion = .identity, orientation: String = "unknown",
        latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.id = id
        self.monotonicTime = monotonicTime
        self.wallTime = wallTime
        self.magnetic = magnetic
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
    }
}
