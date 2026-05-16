import Foundation

/// Chunks an in-memory upload payload and meters its emission to a target
/// kilobytes-per-second rate. `nextChunk()` returns 256 KB at a time, sleeping
/// between chunks so the bytes-per-second cap is honoured.
///
/// `kbps == 0` means unlimited (no sleep). Values below 64 KB/s are clamped up
/// to 64 KB/s — below that the sleep fragmentation gets so coarse that the
/// effective throughput diverges from the requested cap.
actor ThrottledUploadStream {

    static let chunkSize = 256 * 1024
    static let minimumKBps = 64

    private let data: Data
    private let kbps: Int
    private var offset = 0
    private let startedAt = Date()

    /// Total bytes emitted across all `nextChunk()` returns so far. Read by
    /// `BackupManager` to populate `bytesUploadedInLastSecond`.
    private(set) var bytesEmitted = 0

    init(data: Data, kbps: Int) {
        self.data = data
        if kbps <= 0 {
            self.kbps = 0
        } else {
            self.kbps = max(kbps, Self.minimumKBps)
        }
    }

    var isFinished: Bool { offset >= data.count }
    var totalBytes: Int { data.count }

    /// Returns the next chunk, sleeping first if we've outrun the target rate.
    /// Returns `nil` when the source is exhausted.
    func nextChunk() async -> Data? {
        guard offset < data.count else { return nil }

        if kbps > 0 {
            // Bytes that should have been emitted by now, given the target.
            let elapsed = Date().timeIntervalSince(startedAt)
            let allowance = Int(elapsed * Double(kbps) * 1024)
            if bytesEmitted >= allowance {
                // We're ahead — sleep just enough to bring us back to the curve.
                let deficitBytes = bytesEmitted - allowance
                let extraSeconds = Double(deficitBytes) / Double(max(1, kbps) * 1024)
                // Cap any single sleep at 2 s to keep cancellation responsive.
                let nanos = UInt64(min(extraSeconds, 2.0) * 1_000_000_000)
                if nanos > 0 {
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }

        if Task.isCancelled { return nil }

        let end = min(offset + Self.chunkSize, data.count)
        let chunk = data.subdata(in: offset..<end)
        offset = end
        bytesEmitted += chunk.count
        return chunk
    }
}
