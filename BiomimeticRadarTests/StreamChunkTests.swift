import XCTest
#if canImport(BiomimeticRadar)
    @testable import BiomimeticRadar
#else
    @testable import BiomimeticRadarCore
#endif

/// The wire format between the phone and the Mac. `analysis/dev_check.py` reads the same bytes
/// from the Python side, so these pin the half the phone owns.
final class StreamChunkTests: XCTestCase {
    private func samples(_ n: Int, rate: Double = 100) -> [SensorSample] {
        (0..<n).map { i in
            SensorSample(
                monotonicTime: 1000 + Double(i) / rate, wallTime: Date(timeIntervalSince1970: 1_756_000_000 + Double(i) / rate),
                magnetic: Vector3(x: 21 + sin(Double(i)), y: -4, z: 42))
        }
    }

    private func encode(_ s: [SensorSample], seq: Int = 3) throws -> StreamChunk.Encoded {
        try StreamChunk.encode(
            samples: s, deviceID: "abcd1234", deviceName: "test", streamID: "s1", seq: seq,
            requestedRateHz: 100, emitter: nil, deviceModel: "test", systemVersion: "0", appVersion: "0")
    }

    /// The stream's CSV header is the export's CSV header — `analysis/session.py` reads these names.
    func testCSVHeaderMatchesExportColumns() {
        let expected =
            "monotonic_s,wall_clock,mx_uT,my_uT,mz_uT,magnitude_uT,ax_g,ay_g,az_g,gx_rads,gy_rads,gz_rads,qx,qy,qz,qw,orientation,latitude,longitude"
        XCTAssertEqual(StreamChunk.csvHeader, expected)
        XCTAssertEqual(StreamChunk.csv(samples(2)).split(separator: "\n").count, 3)
    }

    func testRoundTripThroughDeflate() throws {
        let s = samples(500)
        let encoded = try encode(s)
        XCTAssertLessThan(encoded.body.count, encoded.uncompressedBytes / 2, "deflate should at least halve a CSV")
        let file = try StreamChunk.inflate(encoded.body)
        XCTAssertEqual(file.count, encoded.uncompressedBytes)
        let (header, csv) = try StreamChunk.decode(file)
        XCTAssertEqual(header.seq, 3)
        XCTAssertEqual(header.sampleCount, 500)
        XCTAssertEqual(header.achievedRateHz, 100, accuracy: 0.5)
        XCTAssertEqual(header.format, "fieldlab-stream/1")
        XCTAssertTrue(csv.hasPrefix(StreamChunk.csvHeader + "\n"))
        XCTAssertEqual(csv.split(separator: "\n").count, 501)
    }

    /// The header line must be one line — the server splits at the first newline.
    func testHeaderIsOneLine() throws {
        let file = try StreamChunk.inflate(try encode(samples(3)).body)
        let firstNewline = file.firstIndex(of: 0x0A)!
        let headerText = String(decoding: file[..<firstNewline], as: UTF8.self)
        XCTAssertTrue(headerText.hasPrefix("{") && headerText.hasSuffix("}"))
        XCTAssertFalse(headerText.contains("\n"))
    }

    /// The achieved rate is measured from the samples, not copied from the request.
    func testAchievedRateIsMeasured() throws {
        let header = try StreamChunk.decode(try StreamChunk.inflate(try encode(samples(200, rate: 50)).body)).0
        XCTAssertEqual(header.requestedRateHz, 100)
        XCTAssertEqual(header.achievedRateHz, 50, accuracy: 0.5)
    }

    /// Writes the fixture `analysis/fixtures/sample.chunk` when `FIELDLAB_FIXTURE_DIR` is set, so
    /// the Python side decodes bytes the SWIFT side produced — the only parity that matters.
    ///
    ///     FIELDLAB_FIXTURE_DIR=analysis/fixtures swift test --filter StreamChunkTests
    func testWriteFixtureForPython() throws {
        guard let dir = ProcessInfo.processInfo.environment["FIELDLAB_FIXTURE_DIR"] else { return }
        let encoded = try encode(samples(300), seq: 7)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sample.chunk")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try encoded.body.write(to: url)
        let note = URL(fileURLWithPath: dir).appendingPathComponent("sample.chunk.txt")
        try
            "300 samples at 100 Hz, seq 7, stream s1, device abcd1234, sha256 \(encoded.header.sha256). Regenerate with FIELDLAB_FIXTURE_DIR=analysis/fixtures swift test --filter StreamChunkTests\n"
            .write(to: note, atomically: true, encoding: .utf8)
    }

    func testEmptyChunkIsRefused() {
        XCTAssertThrowsError(try encode([]))
    }
}
