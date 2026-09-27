import Foundation

enum ProtocolCondition: String, Codable, CaseIterable, Identifiable {
    case noiseFloor = "Noise floor calibration"
    case sternum5 = "Sternum · 5 cm"
    case sternum75 = "Sternum · 7.5 cm"
    case sternum15 = "Sternum · 15 cm"
    case sternum30 = "Sternum · 30 cm"
    case background = "Room / background control"

    var id: String { rawValue }
    var distanceCM: Double? {
        switch self {
        case .sternum5: 5
        case .sternum75: 7.5
        case .sternum15: 15
        case .sternum30: 30
        default: nil
        }
    }
    var instruction: String {
        switch self {
        case .noiseFloor: "Phone stationary on a non-metallic stand for 10+ minutes. Keep people and moving metal away."
        case .background: "Use the same stand and room, with the participant away from the phone."
        default: "Keep the phone fixed at the marked distance. Do not move it or perform a figure-eight during acquisition."
        }
    }
}

struct SensorSample: Codable, Identifiable {
    let id: Int
    let sessionID: String
    let monotonicTime: TimeInterval
    let wallClockISO8601: String
    let magX: Double
    let magY: Double
    let magZ: Double
    let calibratedMagX: Double?
    let calibratedMagY: Double?
    let calibratedMagZ: Double?
    let accelX: Double
    let accelY: Double
    let accelZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double
    let attitudeX: Double?
    let attitudeY: Double?
    let attitudeZ: Double?
    let attitudeW: Double?
    let ppg: Double?
    let beatMarker: Bool
    let motionQuality: Bool
    let condition: String
    let distanceCM: Double?
    let placementNote: String

    var magMagnitude: Double { sqrt(magX * magX + magY * magY + magZ * magZ) }
    var accelMagnitude: Double { sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ) }
    var gyroMagnitude: Double { sqrt(gyroX * gyroX + gyroY * gyroY + gyroZ * gyroZ) }
}

struct PPGPoint: Codable, Identifiable {
    let id: Int
    let monotonicTime: TimeInterval
    let value: Double
    let isBeat: Bool
}

struct AnalysisSettings: Codable {
    var preWindow = 0.5
    var postWindow = 0.5
    var baselineStart = -0.45
    var baselineEnd = -0.15
    var responseStart = -0.1
    var responseEnd = 0.35
    var accelMotionThreshold = 0.08
    var gyroMotionThreshold = 0.08
    var surrogateCount = 1_000
    var bootstrapCount = 1_000
    var lagSearchMS = 500
    var seed: UInt64 = 0xCA4D10
}

struct SessionManifest: Codable {
    let schemaVersion: String
    let sessionID: String
    let createdAt: String
    let deviceModel: String
    let condition: ProtocolCondition
    let nominalDistanceCM: Double?
    let placementNote: String
    let requestedMagnetometerHz: Double
    let achievedMagnetometerHz: Double
    let sampleCount: Int
    let beatCount: Int
    let beatTimes: [Double]
    let analysisSettings: AnalysisSettings
    let files: [String]
    let interpretationWarning: String
}

struct AxisResult: Identifiable {
    let id: String
    let axis: String
    let times: [Double]
    let mean: [Double]
    let lowerCI: [Double]
    let upperCI: [Double]
    let rms: Double
    let empiricalP: Double
    let shuffledP: Double
    let circularP: Double
    let oddEvenCorrelation: Double
    let halfCorrelation: Double
}

struct AnalysisReport {
    let axisResults: [AxisResult]
    let validBeats: Int
    let rejectedBeats: Int
    let heldOutCorrelation: Double
    let motionContaminated: Bool
    let conclusion: String
}
