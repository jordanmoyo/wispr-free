import XCTest
@testable import WisprCore

/// A transcriber that returns scripted segments per call, so the chunking
/// and stitching logic can be tested without a model.
private final class ScriptedTranscriber: MeetingSegmentTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[MeetingTranscriptSegment]]
    private(set) var calls: [Int] = []          // sample count per call
    private(set) var languages: [String?] = []  // language argument per call
    var errorOnCall: Int?
    var errorToThrow: Error = WisprError.modelNotLoaded

    init(scripts: [[MeetingTranscriptSegment]]) { self.scripts = scripts }

    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        let (script, shouldFail, error) = record(sampleCount: samples.count, language: language)
        if shouldFail { throw error }
        return script
    }

    /// Locked body of `transcribeSegments`, kept in an ordinary synchronous
    /// method: taking an `NSLock` directly inside an `async func` is an error
    /// in the Swift 6 language mode. Same shape as
    /// `MeetingAudioWriter.finishSync()`.
    private func record(sampleCount: Int,
                        language: String?) -> ([MeetingTranscriptSegment], Bool, Error) {
        lock.lock()
        defer { lock.unlock() }
        let index = calls.count
        calls.append(sampleCount)
        languages.append(language)
        let script = index < scripts.count ? scripts[index] : []
        return (script, errorOnCall == index, errorToThrow)
    }
}

final class MeetingTranscriberTests: XCTestCase {
    private func seg(_ text: String, _ start: TimeInterval,
                     _ end: TimeInterval) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: .others, start: start, end: end, text: text)
    }

    // MARK: chunkRanges

    func testShortAudioIsOneChunk() {
        let ranges = MeetingTranscriber.chunkRanges(sampleCount: 16_000 * 60)
        XCTAssertEqual(ranges, [0..<(16_000 * 60)])
    }

    func testEmptyAudioIsNoChunks() {
        XCTAssertTrue(MeetingTranscriber.chunkRanges(sampleCount: 0).isEmpty)
    }

    func testLongAudioSplitsWithOverlap() {
        // 25 minutes at 10-minute chunks with 2 s overlap.
        let total = 16_000 * 60 * 25
        let ranges = MeetingTranscriber.chunkRanges(sampleCount: total)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
        // Each chunk after the first starts 2 s before the previous ended.
        XCTAssertEqual(ranges[1].lowerBound, ranges[0].upperBound - 16_000 * 2)
        XCTAssertEqual(ranges[2].lowerBound, ranges[1].upperBound - 16_000 * 2)
    }

    func testChunksCoverEverythingWithNoGaps() {
        let total = 16_000 * 60 * 47
        let ranges = MeetingTranscriber.chunkRanges(sampleCount: total)
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(next.lowerBound, previous.upperBound)
        }
    }

    func testChunkRangesClampsOverlapGreaterThanOrEqualToChunk() {
        // overlapSeconds >= chunkSeconds would make `start` fail to advance
        // each iteration without clamping — an infinite-loop hazard for a
        // public function with defaulted parameters.
        let total = Int(16_000.0 * 25)
        let ranges = MeetingTranscriber.chunkRanges(
            sampleCount: total, chunkSeconds: 10, overlapSeconds: 10)
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThan(next.lowerBound, previous.upperBound)
        }
    }

    func testChunkRangesDropsDegenerateTrailingChunkOnExactMultiple() {
        // An input landing exactly on a chunk boundary would otherwise
        // produce a final chunk only 2 * overlap long — almost entirely a
        // re-transcription of the previous chunk's tail. It should be folded
        // into the previous chunk instead of emitted separately.
        let rate = 16_000.0
        let chunk = Int(10 * rate)
        let total = chunk * 2
        let ranges = MeetingTranscriber.chunkRanges(
            sampleCount: total, chunkSeconds: 10, overlapSeconds: 2)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
    }

    // MARK: offsetSegments

    func testOffsetShiftsBothEnds() {
        let shifted = MeetingTranscriber.offsetSegments([seg("a", 1, 2)], by: 600)
        XCTAssertEqual(shifted[0].start, 601)
        XCTAssertEqual(shifted[0].end, 602)
        XCTAssertEqual(shifted[0].text, "a")
    }

    func testOffsetByZeroIsIdentity() {
        let original = [seg("a", 1, 2)]
        XCTAssertEqual(MeetingTranscriber.offsetSegments(original, by: 0).map(\.start),
                       original.map(\.start))
    }

    // MARK: dedupeOverlap

    func testDedupeDropsIdenticalSeamRepeat() {
        let segments = [seg("hello there", 0, 2), seg("Hello there.", 1.9, 3.9)]
        let deduped = MeetingTranscriber.dedupeOverlap(segments)
        XCTAssertEqual(deduped.count, 1)
    }

    func testDedupeKeepsDifferentTextInOverlap() {
        let segments = [seg("hello there", 0, 2), seg("something else", 1.9, 3.9)]
        XCTAssertEqual(MeetingTranscriber.dedupeOverlap(segments).count, 2)
    }

    func testDedupeKeepsIdenticalTextFarApart() {
        // A genuinely repeated phrase minutes later must survive.
        let segments = [seg("yes", 0, 1), seg("yes", 600, 601)]
        XCTAssertEqual(MeetingTranscriber.dedupeOverlap(segments).count, 2)
    }

    func testDedupeOfEmptyIsEmpty() {
        XCTAssertTrue(MeetingTranscriber.dedupeOverlap([]).isEmpty)
    }

    // MARK: transcribe

    func testTranscribeSingleChunkPassesThrough() async throws {
        let stub = ScriptedTranscriber(scripts: [[seg("hi", 0, 1)]])
        let result = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 30), using: stub, progress: nil)
        XCTAssertEqual(result.map(\.text), ["hi"])
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testTranscribeStitchesChunksWithOffsets() async throws {
        // 25 min → 3 chunks. Second and third segments must be shifted.
        let stub = ScriptedTranscriber(scripts: [
            [seg("one", 0, 1)], [seg("two", 0, 1)], [seg("three", 0, 1)],
        ])
        let result = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 60 * 25),
            using: stub, progress: nil)
        XCTAssertEqual(result.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(result[0].start, 0, accuracy: 0.01)
        XCTAssertGreaterThan(result[1].start, 500)
        XCTAssertGreaterThan(result[2].start, result[1].start)
        // Meetings always auto-detect: every chunk, including chunks after
        // the first, must be called with language: nil — never a pinned
        // language, which would silently translate/mis-detect a meeting.
        XCTAssertEqual(stub.languages, [nil, nil, nil])
    }

    func testTranscribeSkipsFailedChunk() async throws {
        let stub = ScriptedTranscriber(scripts: [
            [seg("one", 0, 1)], [seg("two", 0, 1)], [seg("three", 0, 1)],
        ])
        stub.errorOnCall = 1
        let result = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 60 * 25),
            using: stub, progress: nil)
        XCTAssertEqual(result.map(\.text), ["one", "three"])
    }

    func testTranscribeKeepsBackToBackRepeatWithinSingleChunk() async throws {
        // Real speech: "No." said twice in quick succession, both inside the
        // SAME chunk. This must never be collapsed — dedupe only exists to
        // remove a chunk seam's re-transcribed overlap, not to police
        // genuine repeated words anywhere in the meeting.
        let stub = ScriptedTranscriber(scripts: [
            [seg("No.", 10, 10.4), seg("No.", 10.5, 10.9)],
        ])
        let result = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 30), using: stub, progress: nil)
        XCTAssertEqual(result.map(\.text), ["No.", "No."])
    }

    func testTranscribeDedupesIdenticalRepeatAcrossSeam() async throws {
        // 11 minutes -> 2 chunks (chunk = 600 s, overlap = 2 s), so chunk 2
        // starts at 598 s. The same word transcribed by both chunks near the
        // seam (chunk 1 tail at ~598.5 s, chunk 2 head at ~598.3 s once
        // offset) is exactly the seam-repeat dedupe exists to remove.
        let stub = ScriptedTranscriber(scripts: [
            [seg("no", 598.5, 599.0)],
            [seg("no", 0.3, 0.8)],
        ])
        let result = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 60 * 11), using: stub, progress: nil)
        XCTAssertEqual(result.map(\.text), ["no"])
    }

    func testTranscribeThrowsWhenEveryChunkFails() async {
        let stub = ScriptedTranscriber(scripts: [[]])
        stub.errorOnCall = 0
        do {
            _ = try await MeetingTranscriber.transcribe(
                samples: [Float](repeating: 0, count: 16_000 * 30), using: stub, progress: nil)
            XCTFail("expected throw")
        } catch {
            // Any error is acceptable; the point is it does not report success.
        }
    }

    func testTranscribeThrowsTheRealUnderlyingErrorNotAHardcodedOne() async {
        // The aggregate failure must surface what actually went wrong, not a
        // hardcoded .modelNotLoaded regardless of cause — a disk-read
        // failure shouldn't be misreported as a missing model.
        let stub = ScriptedTranscriber(scripts: [[]])
        stub.errorOnCall = 0
        stub.errorToThrow = WisprError.audioFileTooLong
        do {
            _ = try await MeetingTranscriber.transcribe(
                samples: [Float](repeating: 0, count: 16_000 * 30), using: stub, progress: nil)
            XCTFail("expected throw")
        } catch let error as WisprError {
            XCTAssertEqual(error, .audioFileTooLong)
        } catch {
            XCTFail("expected WisprError.audioFileTooLong, got \(error)")
        }
    }

    func testTranscribeEmptySamplesReturnsEmpty() async throws {
        let stub = ScriptedTranscriber(scripts: [])
        let result = try await MeetingTranscriber.transcribe(
            samples: [], using: stub, progress: nil)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testTranscribeReportsMonotonicProgressEndingAtOne() async throws {
        let stub = ScriptedTranscriber(scripts: [[], [], []])
        let seen = Locked<[Double]>([])
        _ = try await MeetingTranscriber.transcribe(
            samples: [Float](repeating: 0, count: 16_000 * 60 * 25),
            using: stub, progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last!, 1.0, accuracy: 0.001)
        XCTAssertEqual(values, values.sorted())
    }
}
