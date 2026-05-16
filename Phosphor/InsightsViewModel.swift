import Foundation

struct MonthStat: Identifiable, Hashable {
    let id: String
    let month: Date
    let count: Int
}

struct StorageBreakdown: Hashable {
    var photos: Int64 = 0
    var videos: Int64 = 0
    var raw: Int64 = 0
    var other: Int64 = 0

    var total: Int64 { photos + videos + raw + other }
}

struct LocationStat: Identifiable, Hashable {
    let id = UUID()
    let city: String
    let count: Int
}

struct CameraStat: Identifiable, Hashable {
    let id = UUID()
    let makeModel: String
    let count: Int
}

struct PersonStat: Identifiable, Hashable {
    let id: String
    let person: Person
    let count: Int
}

@MainActor
final class InsightsViewModel: ObservableObject {

    @Published private(set) var isLoading = false
    @Published private(set) var photosByMonth: [MonthStat] = []
    @Published private(set) var storageBreakdown = StorageBreakdown()
    @Published private(set) var topLocations: [LocationStat] = []
    @Published private(set) var topCameras: [CameraStat] = []
    @Published private(set) var topPeople: [PersonStat] = []
    @Published private(set) var heatmapData: [Date: Int] = [:]
    @Published var error: ImmichError?

    /// Re-entrancy guard for concurrent `load()` calls — the view can appear
    /// multiple times (push/pop, scenePhase) and we don't want two parallel
    /// 1000-asset fetches racing each other.
    private var inflight: Task<Void, Never>?

    func load() async {
        if let inflight {
            await inflight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performLoad()
        }
        inflight = task
        await task.value
        inflight = nil
    }

    private func performLoad() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // Pull a generous sample for client-side aggregation. Insights is
            // approximate by design; the user is reading trends, not exact totals.
            async let recent = ImmichAPI.shared.searchFiltered(size: 1000)
            async let stats = ImmichAPI.shared.fetchServerStatistics()
            async let people = ImmichAPI.shared.fetchPeople()
            let (assets, serverStats, peopleList) = try await (recent, stats, people)

            aggregateMonths(assets)
            aggregateStorage(assets, totalUsage: serverStats.storageUsed)
            aggregateLocations(assets)
            aggregateCameras(assets)
            aggregatePeople(assets, allPeople: peopleList)
            aggregateHeatmap(assets)
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    // MARK: - Aggregation

    private func aggregateMonths(_ assets: [ImmichAsset]) {
        let calendar = Calendar.current
        var counts: [String: (date: Date, count: Int)] = [:]
        let now = Date()
        let earliest = calendar.date(byAdding: .month, value: -24, to: now) ?? .distantPast
        for asset in assets where asset.localDateTime >= earliest {
            let comps = calendar.dateComponents([.year, .month], from: asset.localDateTime)
            guard let date = calendar.date(from: comps) else { continue }
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            let prev = counts[key]?.count ?? 0
            counts[key] = (date, prev + 1)
        }
        photosByMonth = counts.map { key, value in
            MonthStat(id: key, month: value.date, count: value.count)
        }
        .sorted { $0.month < $1.month }
    }

    private func aggregateStorage(_ assets: [ImmichAsset], totalUsage: Int64) {
        var breakdown = StorageBreakdown()
        var sampleTotal: Int64 = 0
        let rawExts: Set<String> = ["cr2", "arw", "nef", "dng", "rw2", "raf", "orf"]
        for asset in assets {
            let size = asset.fileSizeInByte ?? 0
            sampleTotal += size
            let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
            if asset.isVideo {
                breakdown.videos += size
            } else if rawExts.contains(ext) {
                breakdown.raw += size
            } else if asset.type == .image {
                breakdown.photos += size
            } else {
                breakdown.other += size
            }
        }
        // Scale the sample proportions onto the server's reported total so
        // the chart matches reality even when the sample is < library size.
        if sampleTotal > 0 && totalUsage > 0 {
            let scale = Double(totalUsage) / Double(sampleTotal)
            breakdown.photos = Int64(Double(breakdown.photos) * scale)
            breakdown.videos = Int64(Double(breakdown.videos) * scale)
            breakdown.raw = Int64(Double(breakdown.raw) * scale)
            breakdown.other = Int64(Double(breakdown.other) * scale)
        }
        storageBreakdown = breakdown
    }

    private func aggregateLocations(_ assets: [ImmichAsset]) {
        var counts: [String: Int] = [:]
        for asset in assets {
            if let city = asset.exifInfo?.city, !city.isEmpty {
                counts[city, default: 0] += 1
            }
        }
        topLocations = counts
            .map { LocationStat(city: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    private func aggregateCameras(_ assets: [ImmichAsset]) {
        var counts: [String: Int] = [:]
        for asset in assets {
            let make = asset.exifInfo?.make ?? ""
            let model = asset.exifInfo?.model ?? ""
            let combined = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
            guard !combined.isEmpty else { continue }
            counts[combined, default: 0] += 1
        }
        topCameras = counts
            .map { CameraStat(makeModel: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
    }

    private func aggregatePeople(_ assets: [ImmichAsset], allPeople: [Person]) {
        var counts: [String: Int] = [:]
        for asset in assets {
            for person in asset.people ?? [] {
                counts[person.id, default: 0] += 1
            }
        }
        let stats = allPeople
            .filter { !$0.name.isEmpty }
            .compactMap { person -> PersonStat? in
                guard let count = counts[person.id], count > 0 else { return nil }
                return PersonStat(id: person.id, person: person, count: count)
            }
            .sorted { $0.count > $1.count }
            .prefix(5)
        topPeople = Array(stats)
    }

    /// Heatmap is intentionally a rolling 365-day window — that's all the
    /// `HeatmapGrid` (52 weeks × 7 days) can display. Even with multi-year
    /// libraries this bounds memory to at most ~365 dictionary entries.
    private func aggregateHeatmap(_ assets: [ImmichAsset]) {
        let calendar = Calendar.current
        let now = Date()
        let earliest = calendar.date(byAdding: .day, value: -364, to: now) ?? .distantPast
        var buckets: [Date: Int] = [:]
        buckets.reserveCapacity(365)
        for asset in assets where asset.localDateTime >= earliest && asset.localDateTime <= now {
            let day = calendar.startOfDay(for: asset.localDateTime)
            buckets[day, default: 0] += 1
        }
        heatmapData = buckets
    }
}
