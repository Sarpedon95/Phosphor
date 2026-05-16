import Foundation

struct BlurResult: Identifiable, Codable, Hashable {
    let id: String          // == assetId
    let assetId: String
    let blurScore: Double
    let isBlurry: Bool
    let scannedAt: Date

    init(assetId: String, blurScore: Double, scannedAt: Date = Date()) {
        self.id = assetId
        self.assetId = assetId
        self.blurScore = blurScore
        self.isBlurry = blurScore > 0.65
        self.scannedAt = scannedAt
    }
}

/// Library blur scan. Processes assets in batches of 10 via `TaskGroup` so we
/// never have more than 10 thumbnails downloading + analyzing at once.
/// Results persist to App Group `UserDefaults` so a re-open shows the last
/// scan without rescanning.
@MainActor
final class BlurDetectionEngine: ObservableObject {
    static let shared = BlurDetectionEngine()

    @Published private(set) var results: [BlurResult] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0

    private static let storageKey = "blur_scan_results"
    private let defaults: UserDefaults = .phosphor
    private let batchSize = 10

    private init() {
        loadCachedResults()
    }

    func scan(assets: [ImmichAsset]) async {
        guard !isScanning, !assets.isEmpty else { return }
        isScanning = true
        progress = 0
        defer { isScanning = false }

        var accumulated: [BlurResult] = []
        let total = assets.count
        var completed = 0

        // Chunk into batches; each batch runs ≤10 concurrent analyses.
        for batch in stride(from: 0, to: assets.count, by: batchSize) {
            if Task.isCancelled { break }
            let slice = Array(assets[batch..<min(batch + batchSize, assets.count)])
            let batchResults = await withTaskGroup(
                of: BlurResult?.self, returning: [BlurResult].self
            ) { group in
                for asset in slice {
                    group.addTask {
                        guard let thumb = await ImageLoader.shared.thumbnail(
                            for: asset.id, size: .thumbnail
                        ) else { return nil }
                        let score = await PhotoIntelligenceEngine.shared.detectBlur(image: thumb)
                        return BlurResult(assetId: asset.id, blurScore: score)
                    }
                }
                var out: [BlurResult] = []
                for await result in group {
                    if let result { out.append(result) }
                }
                return out
            }
            accumulated.append(contentsOf: batchResults)
            completed += slice.count
            progress = Double(completed) / Double(total)
        }

        results = accumulated.sorted { $0.blurScore > $1.blurScore }
        persist()
    }

    func remove(assetId: String) {
        results.removeAll { $0.assetId == assetId }
        persist()
    }

    func clearResults() {
        results = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Persistence

    private func loadCachedResults() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([BlurResult].self, from: data)
        else { return }
        results = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(results) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
