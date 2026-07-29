/// Fixed-capacity FIFO of Float samples that keeps only the newest
/// `capacity` samples appended to it.
///
/// Not thread-safe: callers (namely `Recorder`, via `sampleQueue`) are
/// responsible for synchronizing access.
public struct RingBuffer {
    private var storage: [Float] = []
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Appends `samples`, trimming from the front so at most `capacity`
    /// samples (oldest -> newest) remain.
    public mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Current contents, oldest -> newest.
    public func snapshot() -> [Float] {
        storage
    }

    public mutating func clear() {
        storage.removeAll()
    }

    public var count: Int { storage.count }
}
