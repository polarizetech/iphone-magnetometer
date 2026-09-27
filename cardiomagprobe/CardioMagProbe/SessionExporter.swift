import Foundation
import UIKit

enum SessionExporter {
    static func export(
        samples: [SensorSample], beats: [Double], condition: ProtocolCondition, note: String, achievedHz: Double, settings: AnalysisSettings
    ) throws -> URL {
        guard let first = samples.first else { throw CocoaError(.fileNoSuchFile) }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("CardioMag-\(first.sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csvURL = folder.appendingPathComponent("samples.csv")
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var csv =
            "session_id,monotonic_timestamp,wall_clock_iso8601,mag_x_uT,mag_y_uT,mag_z_uT,mag_magnitude_uT,cal_mag_x_uT,cal_mag_y_uT,cal_mag_z_uT,accel_x_g,accel_y_g,accel_z_g,gyro_x_rad_s,gyro_y_rad_s,gyro_z_rad_s,attitude_x,attitude_y,attitude_z,attitude_w,ppg,beat_marker,motion_quality,condition,distance_cm,placement_note\n"
        func value(_ x: Double?) -> String { x.map { String($0) } ?? "" }
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for s in samples {
            csv +=
                [
                    s.sessionID, String(s.monotonicTime), s.wallClockISO8601, String(s.magX), String(s.magY), String(s.magZ),
                    String(s.magMagnitude), value(s.calibratedMagX), value(s.calibratedMagY), value(s.calibratedMagZ), String(s.accelX),
                    String(s.accelY), String(s.accelZ), String(s.gyroX), String(s.gyroY), String(s.gyroZ), value(s.attitudeX),
                    value(s.attitudeY), value(s.attitudeZ), value(s.attitudeW), value(s.ppg), s.beatMarker ? "1" : "0",
                    s.motionQuality ? "1" : "0", quote(s.condition), value(s.distanceCM), quote(s.placementNote),
                ].joined(separator: ",") + "\n"
        }
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        let manifest = SessionManifest(
            schemaVersion: "1.0.0", sessionID: first.sessionID, createdAt: first.wallClockISO8601, deviceModel: UIDevice.current.model,
            condition: condition, nominalDistanceCM: condition.distanceCM, placementNote: note, requestedMagnetometerHz: 50,
            achievedMagnetometerHz: achievedHz, sampleCount: samples.count, beatCount: beats.count, beatTimes: beats,
            analysisSettings: settings, files: ["samples.csv", "manifest.json"],
            interpretationWarning: "A heartbeat-locked component does not by itself establish direct magnetocardiography.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return folder
    }
}
