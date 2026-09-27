import Foundation
import UIKit

/// Carries spool files to the Mac over a background `URLSession`.
///
/// Why a *background* session and not a plain one: the always-on stream runs while the phone is in
/// a pocket with the screen off. A plain `URLSession` task dies with the process; a background
/// session is owned by the system, survives the app being suspended or killed for memory, and hands
/// the result back through `handleEventsForBackgroundURLSession` on the next launch. The price is
/// that uploads must come from a *file* (`uploadTask(with:fromFile:)`), which is why the stream
/// writes a spool file per chunk rather than holding bytes in memory — and why a chunk that never
/// made it is still on disk, visible in the Stream tab, the next time the app opens.
///
/// The uploader owns no policy about *when* to send. `StreamController` hands it files and sweeps
/// the spool; this class only knows how to move one file and report what the server said.
@MainActor
final class StreamUploader: NSObject, ObservableObject {
    static let shared = StreamUploader()
    static let sessionIdentifier = "com.biomimeticradar.stream.upload"

    @Published private(set) var inFlight: Set<String> = []
    @Published private(set) var sentChunks = 0
    @Published private(set) var sentBytes = 0
    @Published private(set) var failedAttempts = 0
    @Published private(set) var lastAck: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastServerMessage: String?
    /// Whether cellular, expensive and constrained paths are allowed. Set on each request, so a change
    /// applies to the next upload without a new session.
    var allowsCellular = false
    /// At most this many uploads are handed to the system at once; the next sweep sends the rest.
    /// Without it a server that was down had the whole backlog re-queued every 30 s.
    static let maxInFlight = 16

    /// Called on the main actor when the server has acknowledged a spool file (2xx). The spool
    /// deletes the file; the uploader never deletes anything itself.
    var onAcknowledged: ((URL, StreamAck?) -> Void)?
    /// Called when a file's upload failed. The file stays in the spool for the next sweep.
    var onFailed: ((URL, String) -> Void)?
    /// Called once the in-flight set is restored, which is when uploads may start. Set after the
    /// restore finished (a background launch can create the uploader first), it runs at once.
    var onReady: (() -> Void)? {
        didSet { if restored { onReady?() } }
    }

    private var session: URLSession!
    /// Filled on the session's delegate queue and read there on completion, so the body is always
    /// complete before `completed` runs. Two separate main-actor hops could arrive in either order.
    private nonisolated let responseBodies = ResponseBodies()
    private var backgroundCompletion: (() -> Void)?
    /// False until the tasks the system is still carrying are known. A sweep before then would send
    /// every one of them a second time.
    private var restored = false

    private override init() {
        super.init()
        session = makeSession()
        // Rebuild the in-flight set from whatever the system is still carrying for us.
        session.getAllTasks { [weak self] tasks in
            let names = tasks.compactMap(\.taskDescription)
            Task { @MainActor in
                self?.inFlight = Set(names)
                self?.restored = true
                self?.onReady?()
            }
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        // The session allows every path and each request narrows it (`enqueue`). Rebuilding the
        // session to change this created a second session with the same identifier while the first
        // was still finishing, which the system does not allow, and its tasks never reported back.
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Hand one spool file to the system. Idempotent: a file already in flight is not re-sent, and
    /// nothing is sent until the in-flight set is restored or while `maxInFlight` are outstanding.
    func enqueue(file: URL, to endpoint: URL) {
        let name = file.lastPathComponent
        guard restored, !inFlight.contains(name), inFlight.count < Self.maxInFlight else { return }
        var request = URLRequest(url: endpoint)
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        request.httpMethod = "POST"
        request.setValue(StreamChunk.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(StreamChunk.formatVersion, forHTTPHeaderField: "X-FieldLab-Format")
        request.setValue("deflate-raw", forHTTPHeaderField: "X-FieldLab-Compression")
        request.setValue(name, forHTTPHeaderField: "X-FieldLab-File")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = name
        inFlight.insert(name)
        task.resume()
    }

    /// From `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
    }

    // MARK: - delegate plumbing (hops to the main actor)

    fileprivate func completed(task: URLSessionTask, body: Data?, error: Error?) {
        // An empty name resolves to the spool directory itself, and an ack would delete all of it.
        guard let name = task.taskDescription, !name.isEmpty else { return }
        inFlight.remove(name)
        let file = StreamSpool.directory.appendingPathComponent(name)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let error {
            failedAttempts += 1
            lastError = "\(name): \(error.localizedDescription)"
            onFailed?(file, error.localizedDescription)
            return
        }
        let ack = body.flatMap { try? JSONDecoder().decode(StreamAck.self, from: $0) }
        // Only this server's own ack releases a chunk. A proxy or captive portal answering 200 with a
        // page of HTML would otherwise delete the phone's only copy of chunks that never arrived.
        if (200..<300).contains(status), ack?.ok == true {
            sentChunks += 1
            sentBytes += Int(task.countOfBytesSent)
            lastAck = Date()
            lastServerMessage = ack?.message
            lastError = nil
            onAcknowledged?(file, ack)
        } else {
            failedAttempts += 1
            let text = body.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
            let reason = (200..<300).contains(status) ? "HTTP \(status) without a FieldLab ack" : "HTTP \(status)"
            lastError = "\(name): \(reason) \(text)"
            onFailed?(file, reason)
        }
    }

    fileprivate func finishedBackgroundEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

/// What the server says back for one chunk. Every field optional — an older server is not an error.
struct StreamAck: Codable, Sendable {
    var ok: Bool?
    var seq: Int?
    var stored: String?
    var duplicate: Bool?
    var message: String?
    /// Sequence numbers the server has NOT received for this stream, so the phone can show a gap
    /// the moment it exists rather than when someone reads the manifest.
    var missing: [Int]?
}

extension StreamUploader: URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies.append(data, for: dataTask.taskIdentifier)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBodies.take(task.taskIdentifier)
        Task { @MainActor in self.completed(task: task, body: body, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishedBackgroundEvents() }
    }
}

/// Where chunks wait on the phone until the Mac has acknowledged them.
///
/// **`Documents/FieldLab Spool`, and that is deliberate on two counts.** Not `Caches`, because iOS
/// purges Caches under storage pressure and a purged chunk is exactly the silently-lost data the
/// durability rule forbids. And `Documents` rather than `Application Support` because the app
/// declares `UIFileSharingEnabled`, so the spool is visible in the Files app — which is what
/// "export" means now that the app has no export screen. If the Mac is unreachable for a week, the
/// chunks are still there and can be copied off by hand and posted with
/// `analysis/post_chunks.py`. One folder is both the outbox and the escape hatch.
///
/// Files are named `<streamID>-<seq>.chunk` so a directory listing is a manifest, and nothing here
/// is ever deleted except on a server acknowledgement or an explicit operator action.
enum StreamSpool {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FieldLab Spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileName(streamID: String, seq: Int) -> String {
        String(format: "%@-%06d.chunk", streamID, seq)
    }

    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "chunk" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func totalBytes() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Atomic: written to a temp name and renamed, so a crash mid-write never leaves a half chunk
    /// that the next sweep would upload as if it were whole.
    static func write(_ data: Data, streamID: String, seq: Int) throws -> URL {
        let final = directory.appendingPathComponent(fileName(streamID: streamID, seq: seq))
        let temp = directory.appendingPathComponent(final.lastPathComponent + ".partial")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: temp, to: final)
        return final
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// Response bodies by task, touched only from URLSession's serial delegate queue; the lock makes that
/// safe to state to the compiler.
private final class ResponseBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]

    func append(_ data: Data, for task: Int) {
        lock.lock()
        defer { lock.unlock() }
        bodies[task, default: Data()].append(data)
    }

    func take(_ task: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bodies.removeValue(forKey: task)
    }
}
