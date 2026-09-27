import Foundation
import SwiftUI

@MainActor
final class ExperimentViewModel: ObservableObject {
    @Published var condition: ProtocolCondition = .noiseFloor
    @Published var placementNote = ""
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var achievedHz = 0.0
    @Published var heartRate: Double?
    @Published var latestMag = (0.0, 0.0, 0.0)
    @Published var accelMagnitude = 1.0
    @Published var gyroMagnitude = 0.0
    @Published var ppgPoints: [PPGPoint] = []
    @Published var samples: [SensorSample] = []
    @Published var beatTimes: [Double] = []
    @Published var report: AnalysisReport?
    @Published var status = "Ready for noise-floor calibration"
    @Published var exportedURL: URL?
    @Published var showShare = false
    @AppStorage("completedNoiseCalibration") var completedNoiseCalibration = false

    var settings = AnalysisSettings()
    private let sensor = SensorRecorder()
    private let ppg = CameraPPGRecorder()
    private var sessionID = ""
    private var startedAt: Double?
    private var timer: Timer?
    private var sampleTimes: [Double] = []
    private var latestPPG: Double?
    private var pendingBeat = false
    private let timestampFormatter = ISO8601DateFormatter()

    init() {
        sensor.onFrame = { [weak self] frame in Task { @MainActor in self?.consume(frame) } }
        sensor.onError = { [weak self] message in Task { @MainActor in self?.status = message } }
        ppg.onPoint = { [weak self] time, value, beat in Task { @MainActor in self?.consumePPG(time: time, value: value, beat: beat) } }
        ppg.onStatus = { [weak self] message in Task { @MainActor in self?.status = message } }
    }

    var magneticMagnitude: Double { sqrt(latestMag.0 * latestMag.0 + latestMag.1 * latestMag.1 + latestMag.2 * latestMag.2) }
    var motionGood: Bool { abs(accelMagnitude - 1) < settings.accelMotionThreshold && gyroMagnitude < settings.gyroMotionThreshold }

    func start(useCameraPPG: Bool) {
        guard !isRecording else { return }
        sessionID = UUID().uuidString.lowercased()
        samples.removeAll(keepingCapacity: true)
        sampleTimes.removeAll(keepingCapacity: true)
        beatTimes.removeAll()
        ppgPoints.removeAll()
        report = nil
        exportedURL = nil
        isRecording = true
        startedAt = nil
        elapsed = 0
        status = "Recording · keep the phone completely stationary"
        sensor.start()
        if useCameraPPG { ppg.requestAndStart() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startedAt else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - start
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        sensor.stop()
        ppg.stop()
        timer?.invalidate()
        isRecording = false
        if condition == .noiseFloor && elapsed >= 60 { completedNoiseCalibration = true }
        status = "Stopped · running falsification-first analysis"
        // Off the main actor: a thousand surrogates per null model keeps the UI responsive only here.
        let (session, recorded, beats, settings) = (sessionID, samples, beatTimes, settings)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SignalAnalysis.analyze(samples: recorded, beatTimes: beats, settings: settings)
            }.value
            guard session == sessionID, !isRecording else { return }  // a new recording started meanwhile
            report = result
            status = result?.conclusion ?? "Not enough valid beats for analysis"
        }
    }

    func markBeat() {
        let t = sampleTimes.last ?? ProcessInfo.processInfo.systemUptime
        beatTimes.append(t)
        pendingBeat = true
        updateHeartRate()
    }

    func importBeatTimes(text: String) {
        let parsed = text.split { $0 == "," || $0 == "\n" || $0 == " " }.compactMap { Double($0) }
        if let first = samples.first?.monotonicTime, let last = samples.last?.monotonicTime, (parsed.max() ?? .infinity) < last - first + 1
        {
            beatTimes = parsed.map { first + $0 }.sorted()
            status = "Imported \(parsed.count) session-relative beat timestamps"
        } else {
            beatTimes = parsed.sorted()
            status = "Imported \(parsed.count) monotonic beat timestamps"
        }
    }

    func export() {
        do {
            exportedURL = try SessionExporter.export(
                samples: samples, beats: beatTimes, condition: condition, note: placementNote, achievedHz: achievedHz, settings: settings)
            showShare = true
            status = "Lossless CSV + JSON session exported"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }

    private func consume(_ f: MotionFrame) {
        if startedAt == nil { startedAt = f.timestamp }
        sampleTimes.append(f.timestamp)
        if sampleTimes.count > 250 { sampleTimes.removeFirst(sampleTimes.count - 250) }
        if let first = sampleTimes.first, let last = sampleTimes.last, last > first {
            achievedHz = Double(sampleTimes.count - 1) / (last - first)
        }
        latestMag = f.mag
        accelMagnitude = sqrt(f.accel.0 * f.accel.0 + f.accel.1 * f.accel.1 + f.accel.2 * f.accel.2)
        gyroMagnitude = sqrt(f.gyro.0 * f.gyro.0 + f.gyro.1 * f.gyro.1 + f.gyro.2 * f.gyro.2)
        let beat = pendingBeat
        pendingBeat = false
        samples.append(
            SensorSample(
                id: samples.count, sessionID: sessionID, monotonicTime: f.timestamp,
                wallClockISO8601: timestampFormatter.string(from: Date()),
                magX: f.mag.0, magY: f.mag.1, magZ: f.mag.2, calibratedMagX: f.calibratedMag?.0, calibratedMagY: f.calibratedMag?.1,
                calibratedMagZ: f.calibratedMag?.2, accelX: f.accel.0, accelY: f.accel.1, accelZ: f.accel.2, gyroX: f.gyro.0,
                gyroY: f.gyro.1, gyroZ: f.gyro.2, attitudeX: f.attitude?.0, attitudeY: f.attitude?.1, attitudeZ: f.attitude?.2,
                attitudeW: f.attitude?.3, ppg: latestPPG, beatMarker: beat, motionQuality: motionGood, condition: condition.rawValue,
                distanceCM: condition.distanceCM, placementNote: placementNote))
    }

    private func consumePPG(time: Double, value: Double, beat: Bool) {
        latestPPG = value
        ppgPoints.append(PPGPoint(id: ppgPoints.count, monotonicTime: time, value: value, isBeat: beat))
        if ppgPoints.count > 300 { ppgPoints.removeFirst() }
        if beat {
            beatTimes.append(time)
            pendingBeat = true
            updateHeartRate()
        }
    }

    private func updateHeartRate() {
        guard beatTimes.count >= 3 else { return }
        let recent = Array(beatTimes.suffix(8))
        let intervals = zip(recent.dropFirst(), recent).map(-)
        heartRate = 60 / SignalAnalysis.median(intervals)
    }
}
