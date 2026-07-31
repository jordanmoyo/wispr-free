import AVFoundation
import XCTest
@testable import WisprCore

final class MeetingAudioWriterTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString).m4a")
    }

    /// One second of 440 Hz tone at 16 kHz, the rate the writer expects.
    private func tone(seconds: Double = 1.0) -> [Float] {
        let count = Int(16_000 * seconds)
        return (0..<count).map { sin(2 * .pi * 440 * Double($0) / 16_000) }.map(Float.init)
    }

    func testRoundTripPreservesRoughDurationAndSignal() async throws {
        let url = tempURL()
        let writer = try MeetingAudioWriter(url: url)
        writer.append(tone(seconds: 2))
        await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let decoded = try AudioFileImporter.loadSamples(url: url)
        // AAC adds priming/padding, so allow generous slack on length.
        XCTAssertGreaterThan(decoded.count, 16_000 * 2 - 4_000)
        XCTAssertLessThan(decoded.count, 16_000 * 2 + 8_000)
        // The tone must survive: peak amplitude well above the silence floor.
        let peak = decoded.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
    }

    func testAppendAccumulatesSampleCount() throws {
        let writer = try MeetingAudioWriter(url: tempURL())
        writer.append([Float](repeating: 0, count: 1_600))
        writer.append([Float](repeating: 0, count: 2_400))
        XCTAssertEqual(writer.sampleCount, 4_000)
    }

    func testManySmallAppendsProduceOneValidFile() async throws {
        let url = tempURL()
        let writer = try MeetingAudioWriter(url: url)
        let chunk = [Float](repeating: 0.25, count: 1_024)
        // 200 * 1_024 == 204_800, an exact multiple of AudioFileImporter's
        // internal read-chunk size (8_192) — deliberately exercises that
        // boundary from the writer side now that AudioFileImporter bounds
        // reads by remaining frames instead of inferring EOF from a short read.
        for _ in 0..<200 { writer.append(chunk) }   // ~13 s in 1024-frame chunks
        await writer.finish()
        let decoded = try AudioFileImporter.loadSamples(url: url)
        XCTAssertGreaterThan(decoded.count, 200 * 1_024 - 8_000)
    }

    func testFinishIsIdempotent() async throws {
        let url = tempURL()
        let writer = try MeetingAudioWriter(url: url)
        writer.append(tone(seconds: 0.5))
        await writer.finish()
        await writer.finish()   // must not crash or corrupt
        XCTAssertNoThrow(try AudioFileImporter.loadSamples(url: url))
    }

    func testEmptyWriterStillProducesReadableOrAbsentFile() async throws {
        let url = tempURL()
        let writer = try MeetingAudioWriter(url: url)
        await writer.finish()
        // Zero samples ever appended: finish() removes the file rather than
        // leaving a zero-frame AAC container that throws on decode.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAppendAfterFinishIsIgnored() async throws {
        let url = tempURL()
        let writer = try MeetingAudioWriter(url: url)
        writer.append(tone(seconds: 0.5))
        await writer.finish()
        writer.append(tone(seconds: 0.5))   // must be a no-op, not a crash
        XCTAssertEqual(writer.sampleCount, 8_000)
    }

    func testInitFailsForUnwritablePath() {
        XCTAssertThrowsError(
            try MeetingAudioWriter(url: URL(fileURLWithPath: "/dev/null/nope.m4a")))
    }
}
