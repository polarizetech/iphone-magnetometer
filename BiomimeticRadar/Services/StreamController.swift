import Combine
import CoreLocation
import Foundation
import UIKit

/// The always-on mode: keep the magnetometer running, cut the stream into chunks, spool each chunk
/// to disk, and let `StreamUploader` carry it to the Mac over the tailnet.
///
/// What it does NOT do: analyse anything. The phone's job in this mode is to be a sensor that does
/// not stop and does not lose data. Every number comes out on the Mac, where `serve.py` stores the
/// chunks, the web view draws them, and `analysis/` reads them with the same loader it uses for an
/// export.
///
/// **Staying alive in the background.** Core Motion stops delivering to a backgrounded app within
/// seconds — unless a Core Location session is running with `allowsBackgroundLocationUpdates`, in
/// which case the callbacks continue for as long as the app is in the background (Apple Developer
/// Forums thread 88480; verified behaviour, not documented behaviour). `BackgroundKeepAlive` holds
/// that session at the coarsest accuracy. The blue location pill in the status bar is the price and
/// it is the honest one: the phone IS recording, and iOS says so.
///
/// **Durability** follows `tools/eeg-bridge/DURABILITY.md` in spirit: samples go to a spool file as
/// each chunk closes, never buffered for an end-of-run write; a file is deleted only on the server's
/// acknowledgement; nothing is auto-cleaned; a chunk the server never received is reported as a gap
/// by sequence number rather than silently absent.
@MainActor
final class StreamController: ObservableObject {
    struct Settings: Codable, Equatable {
        /// Where `serve.py` is reachable from the phone. Set it in the Stream settings.
        var serverURL = "https://your-mac.your-tailnet.ts.net/biomimetic-radar"
        var deviceName = "iphone"
        /// Chunk length IS the live view's latency. 10 s is "live"; 300 s is "economy".
        var chunkSeconds = 10.0
        var sampleRateHz = 100.0
        /// Device-motion (gyro) for attitude. The gyro is the power cost; the magnetometer alone is cheap.
        var attitude = true
        var includeLocation = false
        var wifiOnly = true
        /// Pause (keep the sensor, stop nothing else) below this battery fraction when unplugged.
        var pauseBelowBattery = 0.15
        var resumeAboveBattery = 0.25
    }

    enum State: String { case idle, running, pausedLowBattery, pausedThermal }

    @Published var settings: Settings { didSet { persist() } }
    @Published private(set) var state: State = .idle
    @Published private(set) var streamID: String?
    @Published private(set) var seq = 0
    @Published private(set) var buffered = 0
    @Published private(set) var totalSamples = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastChunkAt: Date?
    @Published private(set) var spoolFiles = 0
    @Published private(set) var spoolBytes = 0
    @Published private(set) var message = "Not streaming"
    @Published private(set) var keepAliveStatus = "off"
    @Published private(set) var sensorNote: String?
    @Published private(set) var serverMissing: [Int] = []
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// Set when the app last terminated with a stream running — iOS does not let us restart sensors
    /// from the background, so all we can do is say so and resume the uploads.
    @Published private(set) var wasInterrupted = false

    let deviceID: String
    let uploader = StreamUploader.shared
    /// The emitter stamp to write into each chunk header. `RecorderModel` supplies it.
    var emitterStamp: (() -> StreamChunk.EmitterStamp?)?

    private let sensor: SensorManager
    private let keepAlive = BackgroundKeepAlive()
    /// Battery, thermal, barometric pressure and free disk — sampled once per chunk.
    let environment = EnvironmentProbe()
    private var tap: UUID?
    private var buffer: [SensorSample] = []
    private var chunkTimer: Timer?
    private var sweepTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let encodeQueue = DispatchQueue(label: "FieldLab.StreamEncode", qos: .utility)
    private static let settingsKey = "fieldlab.stream.settings"
    private static let deviceIDKey = "fieldlab.stream.deviceID"
    private static let runningKey = "fieldlab.stream.wasRunning"

    var isRunning: Bool { state != .idle }
    var endpointChunk: URL? { endpoint("api/stream/chunk") }

    init(sensor: SensorManager) {
        self.sensor = sensor
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
        if let id = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = id
        } else {
            let id = (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString).prefix(8).lowercased()
            deviceID = String(id)
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        wasInterrupted = defaults.bool(forKey: Self.runningKey)
        uploader.allowsCellular = !settings.wifiOnly
        // Each ack frees a slot (`StreamUploader.maxInFlight`), so the backlog keeps moving when no
        // stream is running and the 30 s sweep timer is off.
        uploader.onAcknowledged = { [weak self] file, ack in
            self?.acknowledged(file, ack)
            self?.sweep()
        }
        uploader.onReady = { [weak self] in self?.sweep() }
        uploader.onFailed = { [weak self] _, reason in self?.message = "Upload failed: \(reason) — will retry" }
        keepAlive.onStatus = { [weak self] text in self?.keepAliveStatus = text }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        refreshSpool()
        // Leftovers from a previous run go first, whatever the state of the sensor: `onReady` sweeps
        // as soon as the uploader knows what the system is still carrying.
    }

    // MARK: - control

    func start() {
        guard state == .idle else { return }
        guard endpointChunk != nil else {
            message = "Server URL is not a valid URL"
            return
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        streamID = id
        seq = 0
        buffer.removeAll()
        buffered = 0
        totalSamples = 0
        ingested = 0
        startedAt = Date()
        lastChunkAt = nil
        serverMissing = []
        sensorNote = sensor.start(
            sampleRate: settings.sampleRateHz, includeLocation: settings.includeLocation,
            attitude: settings.attitude, owner: .stream)
        if let error = sensor.errorMessage, !sensor.isRunning {
            message = error
            return
        }
        tap = sensor.addTap { [weak self] sample in self?.ingest(sample) }
        keepAlive.start()
        environment.start()
        state = .running
        wasInterrupted = false
        UserDefaults.standard.set(true, forKey: Self.runningKey)
        message = "Streaming to \(settings.serverURL)"
        scheduleTimers()
        observeDeviceState()
        sendHello()
    }

    func stop() {
        guard state != .idle else { return }
        cut(reason: "stop")
        if let tap { sensor.removeTap(tap) }
        tap = nil
        sensor.stop(owner: .stream)
        keepAlive.stop()
        environment.stop()
        chunkTimer?.invalidate()
        chunkTimer = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        state = .idle
        UserDefaults.standard.set(false, forKey: Self.runningKey)
        message = "Stopped — \(spoolFiles) chunk(s) still to upload" + (spoolFiles == 0 ? "" : "; they go when the network allows")
        sweep()
    }

    /// Re-send everything in the spool that is not already in flight. Safe to call any time.
    func sweep() {
        refreshSpool()
        guard let endpoint = endpointChunk else { return }
        for file in StreamSpool.files() {
            uploader.enqueue(file: file, to: endpoint)
        }
    }

    func applyNetworkPolicy() {
        uploader.allowsCellular = !settings.wifiOnly
    }

    /// Operator action, never automatic: drop every spool file. Exists because a stream pointed at a
    /// server that will never exist should not hold storage forever — and it says what it discards.
    func discardSpool() -> Int {
        let files = StreamSpool.files()
        files.forEach(StreamSpool.remove)
        refreshSpool()
        message = "Discarded \(files.count) unsent chunk(s) on operator request"
        return files.count
    }

    // MARK: - the stream itself

    private var ingested = 0
    private func ingest(_ sample: SensorSample) {
        guard state == .running else { return }
        buffer.append(sample)
        ingested += 1
        // Publish at ~4 Hz, not per sample — the UI does not need 100 redraws a second.
        if ingested % 25 == 0 {
            buffered = buffer.count
            totalSamples = ingested
        }
        // A timer that did not fire (a suspended process) must not grow an unbounded chunk.
        if Double(buffer.count) >= settings.sampleRateHz * max(settings.chunkSeconds, 1) * 3 { cut(reason: "overflow") }
    }

    private func cut(reason: String) {
        guard !buffer.isEmpty, let streamID else { return }
        let samples = buffer
        buffer.removeAll(keepingCapacity: true)
        buffered = 0
        let thisSeq = seq
        seq += 1
        // The rate the sensor was actually set to, not the picker's value: they differed silently
        // for 14 minutes on 2026-09-16 (setting 64 Hz, sensor 100 Hz), and the chunks said 64.
        let applied = sensor.configuredRateHz > 0 ? sensor.configuredRateHz : settings.sampleRateHz
        let args = (
            deviceID: deviceID, deviceName: settings.deviceName, rate: applied,
            emitter: emitterStamp?(), model: Self.deviceModel, system: UIDevice.current.systemVersion,
            app: Self.appVersion, aux: environment.read()
        )
        encodeQueue.async { [weak self] in
            do {
                let encoded = try StreamChunk.encode(
                    samples: samples, deviceID: args.deviceID, deviceName: args.deviceName,
                    streamID: streamID, seq: thisSeq, requestedRateHz: args.rate,
                    emitter: args.emitter, deviceModel: args.model,
                    systemVersion: args.system, appVersion: args.app,
                    aux: args.aux)
                let url = try StreamSpool.write(encoded.body, streamID: streamID, seq: thisSeq)
                Task { @MainActor in
                    guard let self else { return }
                    self.lastChunkAt = Date()
                    self.refreshSpool()
                    if let endpoint = self.endpointChunk { self.uploader.enqueue(file: url, to: endpoint) }
                }
            } catch {
                Task { @MainActor in self?.message = "Chunk \(thisSeq) could not be written: \(error.localizedDescription)" }
            }
        }
    }

    private func acknowledged(_ file: URL, _ ack: StreamAck?) {
        StreamSpool.remove(file)
        refreshSpool()
        if let missing = ack?.missing { serverMissing = missing }
        if state == .running { message = "Streaming · server ack \(ack?.seq.map(String.init) ?? "")" }
    }

    private func refreshSpool() {
        spoolFiles = StreamSpool.files().count
        spoolBytes = StreamSpool.totalBytes()
    }

    private func scheduleTimers() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: max(1, settings.chunkSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cut(reason: "timer") }
        }
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    // MARK: - battery and thermal

    private func observeDeviceState() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkPower() }
            })
        observers.append(
            center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkPower() }
            })
        observers.append(
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkPower() }
            })
        checkPower()
    }

    private func checkPower() {
        batteryLevel = UIDevice.current.batteryLevel
        thermalState = ProcessInfo.processInfo.thermalState
        let unplugged = UIDevice.current.batteryState == .unplugged
        switch state {
        case .running:
            if thermalState == .critical {
                pause(.pausedThermal, "Paused: thermal state critical")
            } else if unplugged, batteryLevel >= 0, Double(batteryLevel) < settings.pauseBelowBattery {
                pause(.pausedLowBattery, String(format: "Paused: battery %.0f%% and unplugged", batteryLevel * 100))
            }
        case .pausedLowBattery:
            if !unplugged || Double(batteryLevel) >= settings.resumeAboveBattery { resume() }
        case .pausedThermal:
            if thermalState != .critical { resume() }
        case .idle: break
        }
    }

    private func pause(_ newState: State, _ why: String) {
        cut(reason: "pause")
        state = newState
        message = why
        // The sensor keeps running so the hold on the hardware (and the keep-alive) is not lost;
        // samples are simply not buffered while paused. That is a recorded gap, not a silent one.
    }

    private func resume() {
        state = .running
        message = "Resumed"
    }

    // MARK: - hello

    private func sendHello() {
        guard let url = endpoint("api/stream/hello") else { return }
        struct Hello: Encodable {
            let deviceID: String, deviceName: String, streamID: String, startedAt: Date
            let settings: Settings, deviceModel: String, systemVersion: String, appVersion: String
            let emitter: StreamChunk.EmitterStamp?
            let keepAlive: String
            let aux: StreamChunk.EnvironmentReading
        }
        let hello = Hello(
            deviceID: deviceID, deviceName: settings.deviceName, streamID: streamID ?? "", startedAt: startedAt ?? Date(),
            settings: settings, deviceModel: Self.deviceModel, systemVersion: UIDevice.current.systemVersion,
            appVersion: Self.appVersion, emitter: emitterStamp?(), keepAlive: keepAliveStatus,
            aux: environment.read())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(hello) else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if let error {
                    self?.message = "Server not reachable (\(error.localizedDescription)) — chunks will spool until it is"
                } else if !(200..<300).contains(code) {
                    self?.message = "Server answered HTTP \(code) to hello"
                } else {
                    self?.message = "Server reached · streaming"
                }
            }
        }.resume()
    }

    // MARK: - helpers

    private func endpoint(_ path: String) -> URL? {
        var base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "0") (\(info?["CFBundleVersion"] ?? "0"))"
    }
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

/// Holds a coarse Core Location session so Core Motion keeps delivering in the background.
///
/// Coarsest accuracy and a large distance filter: the position is not the point, the *session* is.
/// `allowsBackgroundLocationUpdates` traps at runtime unless `UIBackgroundModes` contains
/// `location` — `project.yml` declares it; do not remove one without the other.
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var running = false
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        running = true
        report()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        running = false
        onStatus?("off")
    }

    private func report() {
        let auth: String
        switch manager.authorizationStatus {
        case .authorizedAlways: auth = "location always"
        case .authorizedWhenInUse: auth = "location when-in-use"
        case .denied, .restricted: auth = "location DENIED — background will stop within seconds"
        default: auth = "location not yet authorised"
        }
        onStatus?(running ? "keep-alive on · \(auth)" : "off")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { report() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onStatus?("keep-alive error: \(error.localizedDescription)")
    }
}

/// Settings are saved as one JSON blob. The synthesized decoder fails the whole blob when a key is
/// missing, so adding a field silently reset every installed phone to defaults, server URL included.
/// Each field falls back to its default on its own instead. Defined in an extension so the memberwise
/// and default initializers stay synthesized.
extension StreamController.Settings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? serverURL
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? deviceName
        chunkSeconds = try c.decodeIfPresent(Double.self, forKey: .chunkSeconds) ?? chunkSeconds
        sampleRateHz = try c.decodeIfPresent(Double.self, forKey: .sampleRateHz) ?? sampleRateHz
        attitude = try c.decodeIfPresent(Bool.self, forKey: .attitude) ?? attitude
        includeLocation = try c.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? includeLocation
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? wifiOnly
        pauseBelowBattery = try c.decodeIfPresent(Double.self, forKey: .pauseBelowBattery) ?? pauseBelowBattery
        resumeAboveBattery = try c.decodeIfPresent(Double.self, forKey: .resumeAboveBattery) ?? resumeAboveBattery
    }
}
