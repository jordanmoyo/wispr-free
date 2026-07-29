import XCTest
@testable import WisprCore

final class RingBufferTests: XCTestCase {
    func testAppendUnderCapacityMatchesInput() {
        var ring = RingBuffer(capacity: 8)
        let input: [Float] = [1, 2, 3, 4]
        ring.append(input)
        XCTAssertEqual(ring.snapshot(), input)
        XCTAssertEqual(ring.count, 4)
    }

    func testOverfillKeepsNewestInOrder() {
        var ring = RingBuffer(capacity: 8)
        ring.append([1, 2, 3, 4, 5])
        ring.append([6, 7, 8, 9, 10])
        XCTAssertEqual(ring.snapshot(), [3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.count, 8)
    }

    func testChunkLargerThanCapacityKeepsLastCapacity() {
        var ring = RingBuffer(capacity: 8)
        let input = (1...20).map(Float.init)
        ring.append(input)
        XCTAssertEqual(ring.snapshot(), (13...20).map(Float.init))
        XCTAssertEqual(ring.count, 8)
    }

    func testClearEmptiesBuffer() {
        var ring = RingBuffer(capacity: 8)
        ring.append([1, 2, 3])
        ring.clear()
        XCTAssertEqual(ring.snapshot(), [])
        XCTAssertEqual(ring.count, 0)
    }

    func testCountTracksAcrossAppends() {
        var ring = RingBuffer(capacity: 8)
        XCTAssertEqual(ring.count, 0)
        ring.append([1, 2])
        XCTAssertEqual(ring.count, 2)
        ring.append([3, 4, 5])
        XCTAssertEqual(ring.count, 5)
    }
}
