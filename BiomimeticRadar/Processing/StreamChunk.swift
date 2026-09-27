// swift-format-ignore-file
// serve.py, bands.py and dev_check.py read this file with regular expressions; keep its layout.
import CryptoKit
import Foundation

/// One slice of an always-on stream, as it travels from the phone to the Mac.
///
/// The always-on mode does not stream samples one at a time. It cuts the sensor stream into chunks
/// of a few seconds to a few minutes, writes each one to a spool file on the phone, and hands the
/// file to a background `URLSession` upload. "Live" and "economy" are the same mechanism with a
/// different chunk length — the latency of the web view IS the chunk length, and nothing else
/// changes. That is deliberate: one code path, one file format, one thing to get right, and a
/// chunk that failed to upload is still on disk when the app comes back.
///
/// **The wire format is one self-describing file**, so a re-upload after a relaunch needs nothing
/// but the file:
///
///     line 1      JSON `Header` (one line, no newlines inside)
///     line 2      the CSV column header — IDENTICAL to `raw.csv` in an export
///     line 3…     one row per sample, same encoder as the export
///
/// …the whole thing raw-DEFLATE compressed (`NSData.compressed(using: .zlib)` produces a raw
/// deflate stream with no zlib/gzip container; Python reads it with `zlib.decompressobj(-15)`).
/// The server stores the decompressed CSV as-is, which is why `analysis/fieldlab/session.py` can
/// read a stretch of stream with the same reader it uses for an export.
enum StreamChunk {
    static let formatVersion = "fieldlab-stream/1"
    static let contentType = "application/x-fieldlab-chunk"
    /// The `raw.csv` column set. `ExportManager` encodes through `rows(_:)` below so the export and
    /// the stream cannot drift apart — `analysis/session.py` reads exactly these names.
    static let csvHeader = "monotonic_s,wall_clock,mx_uT,my_uT,mz_uT,magnitude_uT,ax_g,ay_g,az_g,gx_rads,gy_rads,gz_rads,qx,qy,qz,qw,orientation,latitude,longitude"

    struct Header: Codable, Sendable, Equatable {
        var format = StreamChunk.formatVersion
        /// Stable per install; the server keys its store on it.
        var deviceID: String
        /// Operator-chosen label ("kitchen-iphone"). Display only — the store is keyed on `deviceID`.
        var deviceName: String
        /// One per press of Start. A new stream ID is a new sequence of `seq`.
        var streamID: String
        /// 0, 1, 2 … within a stream. The server uses (deviceID, streamID, seq) to make a retried
        /// upload idempotent, and reports any seq it never received as a gap.
        var seq: Int
        var startedAt: Date
        var endedAt: Date
        var firstMonotonic: Double
        var lastMonotonic: Double
        var sampleCount: Int
        var requestedRateHz: Double
        /// Median-interval rate measured over THIS chunk, not the request.
        var achievedRateHz: Double
        /// Non-nil when the phone's own emitter was running. Everything downstream reads this; a
        /// chunk recorded with it measures **this phone**, not the world — and it now carries the
        /// carrier and code as well as the stamp, so the Mac can build the matched reference for a
        /// positive control rather than assuming the defaults.
        var emitter: EmitterStamp?
        /// Covariates sampled once per chunk: battery, thermal, barometric pressure, free disk.
        /// Optional so an older chunk (and the pinned fixture) still decodes.
        var aux: EnvironmentReading?
        var deviceModel: String
        var systemVersion: String
        var appVersion: String
        /// SHA-256 of the CSV body (header row + sample rows), so a server can verify it got the
        /// bytes the phone meant to send.
        var sha256: String
    }

    /// The per-chunk covariates. Declared here, with the wire format, rather than beside the code
    /// that reads the sensors — the schema is the contract with the Mac, and the Mac's reader must
    /// compile without UIKit. `EnvironmentProbe` fills it in.
    ///
    /// Every field is optional or has an explicit "unknown": a phone with no barometer reports
    /// `nil` pressure, never `0`, because zero kilopascals is a claim and absence is not.
    struct EnvironmentReading: Codable, Sendable, Equatable {
        var batteryLevel: Double?
        var batteryState: String = "unknown"
        var lowPowerMode: Bool = false
        var thermalState: String = "unknown"
        var pressureKPa: Double?
        var relativeAltitudeM: Double?
        var freeDiskBytes: Int?
    }

    /// What the phone was emitting while this chunk was recorded, if anything.
    ///
    /// A *string* stamp was enough while the analysis lived on the phone, which already knew the
    /// protocol. It is not enough now that the Mac does the detecting: to matched-filter a positive
    /// control the receiver has to know the carrier, the code and the chip length that were played.
    struct EmitterStamp: Codable, Sendable, Equatable {
        /// Always `EmitterSchedule.stamp` ("EMITTER-ON") — the field a reader greps for.
        var stamp: String
        var transducer: String
        var carrierHz: Double
        var code: [Double]
        var chipSeconds: Double
        var amplitude: Double
    }

    /// ISO-8601 with fractional seconds, for the CSV rows and the header alike — a chunk boundary
    /// to the nearest second would misplace a 10 s chunk by up to 10% against a lightning time.
    static func makeISO() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let iso = makeISO()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(iso.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let iso = makeISO()
        decoder.dateDecodingStrategy = .custom { dec in
            let text = try dec.singleValueContainer().decode(String.self)
            if let d = iso.date(from: text) { return d }
            if let d = ISO8601DateFormatter().date(from: text) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }

    /// The rows of a raw CSV, without the header. One encoder for export and stream.
    static func rows(_ samples: [SensorSample]) -> [String] {
        let iso = makeISO()
        return samples.map { s in
            [f(s.monotonicTime), iso.string(from: s.wallTime), f(s.magnetic.x), f(s.magnetic.y), f(s.magnetic.z), f(s.magnetic.magnitude),
             f(s.acceleration.x), f(s.acceleration.y), f(s.acceleration.z), f(s.rotationRate.x), f(s.rotationRate.y), f(s.rotationRate.z),
             f(s.attitude.x), f(s.attitude.y), f(s.attitude.z), f(s.attitude.w), s.orientation,
             s.latitude.map(f) ?? "", s.longitude.map(f) ?? ""].joined(separator: ",")
        }
    }

    static func csv(_ samples: [SensorSample]) -> String {
        ([csvHeader] + rows(samples)).joined(separator: "\n") + "\n"
    }

    /// Median-interval rate, the same estimator the analysis uses — never the request.
    static func achievedRate(_ samples: [SensorSample]) -> Double {
        guard samples.count > 2 else { return 0 }
        var intervals = zip(samples.dropFirst(), samples).map { $0.monotonicTime - $1.monotonicTime }.filter { $0 > 0 }
        guard !intervals.isEmpty else { return 0 }
        intervals.sort()
        return 1 / intervals[intervals.count / 2]
    }

    struct Encoded: Sendable {
        let header: Header
        /// The deflated file body — header line + CSV.
        let body: Data
        let uncompressedBytes: Int
    }

    enum EncodeError: Error { case empty, compression }

    /// Build the wire file for one chunk.
    static func encode(samples: [SensorSample], deviceID: String, deviceName: String, streamID: String, seq: Int,
                       requestedRateHz: Double, emitter: EmitterStamp?, deviceModel: String, systemVersion: String,
                       appVersion: String, aux: EnvironmentReading? = nil) throws -> Encoded {
        guard let first = samples.first, let last = samples.last else { throw EncodeError.empty }
        let csvText = csv(samples)
        let csvData = Data(csvText.utf8)
        let digest = SHA256.hash(data: csvData).map { String(format: "%02x", $0) }.joined()
        let header = Header(deviceID: deviceID, deviceName: deviceName, streamID: streamID, seq: seq,
                            startedAt: first.wallTime, endedAt: last.wallTime,
                            firstMonotonic: first.monotonicTime, lastMonotonic: last.monotonicTime,
                            sampleCount: samples.count, requestedRateHz: requestedRateHz,
                            achievedRateHz: achievedRate(samples), emitter: emitter, aux: aux,
                            deviceModel: deviceModel, systemVersion: systemVersion, appVersion: appVersion,
                            sha256: digest)
        var file = try makeJSONEncoder().encode(header)
        file.append(0x0A)
        file.append(csvData)
        let compressed = try deflate(file)
        return Encoded(header: header, body: compressed, uncompressedBytes: file.count)
    }

    /// Raw DEFLATE (RFC 1951), no container. Python: `zlib.decompressobj(-15).decompress(body)`.
    static func deflate(_ data: Data) throws -> Data {
        do { return try (data as NSData).compressed(using: .zlib) as Data }
        catch { throw EncodeError.compression }
    }

    static func inflate(_ data: Data) throws -> Data {
        do { return try (data as NSData).decompressed(using: .zlib) as Data }
        catch { throw EncodeError.compression }
    }

    /// Split a decoded file back into its header and CSV. Used by the tests and by nothing on
    /// the phone — the server is the reader.
    static func decode(_ file: Data) throws -> (Header, String) {
        guard let newline = file.firstIndex(of: 0x0A) else { throw EncodeError.empty }
        let header = try makeJSONDecoder().decode(Header.self, from: file[file.startIndex..<newline])
        let csvText = String(decoding: file[(newline + 1)...], as: UTF8.self)
        return (header, csvText)
    }

    static func f(_ value: Double) -> String { String(format: "%.10g", value) }
}
