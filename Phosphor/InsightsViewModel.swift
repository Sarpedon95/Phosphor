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
    private var inflight: Task<Void?, Never>?

    func load() async {
        if let inflight {
            _ = await inflight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performLoad()
        }
        inflight = task
        _ = await task.value
        inflight = nil
    }

    private func performLoad() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let recent = ImmichAPI.shared.searchFiltered(size: 1000)
            async let stats = ImmichAPI.shared.fetchServerStatistics()
            async let people = ImmichAPI.shared.fetchPeople()
            let (assets, serverStats, peopleList) = try await (recent, stats, people)
            aggregate(assets, totalUsage: serverStats.storageUsed, allPeople: peopleList)
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    // MARK: - Aggregation (single pass over assets)

    private func aggregate(_ assets: [ImmichAsset], totalUsage: Int64, allPeople: [Person]) {
        let calendar = Calendar.current
        let now = Date()
        let earliest24m = calendar.date(byAdding: .month, value: -24, to: now) ?? .distantPast
        let earliest364d = calendar.date(byAdding: .day, value: -364, to: now) ?? .distantPast
        let rawExts: Set<String> = ["cr2", "arw", "nef", "dng", "rw2", "raf", "orf"]

        var monthCounts: [String: (date: Date, count: Int)] = [:]
        var breakdown = StorageBreakdown()
        var sampleTotal: Int64 = 0
        var locationCounts: [String: Int] = [:]
        var cameraCounts: [String: Int] = [:]
        var personCounts: [String: Int] = [:]
        var heatBuckets: [Date: Int] = [:]
        heatBuckets.reserveCapacity(365)

        for asset in assets {
            let date = asset.localDateTime

            if date >= earliest24m {
                let comps = calendar.dateComponents([.year, .month], from: date)
                if let monthDate = calendar.date(from: comps) {
                    let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
                    monthCounts[key] = (monthDate, (monthCounts[key]?.count ?? 0) + 1)
                }
            }

            let size = asset.fileSizeInByte ?? 0
            sampleTotal += size
            let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
            if asset.isVideo { breakdown.videos += size }
            else if rawExts.contains(ext) { breakdown.raw += size }
            else if asset.type == .image { breakdown.photos += size }
            else { breakdown.other += size }

            if let city = asset.exifInfo?.city, !city.isEmpty {
                locationCounts[city, default: 0] += 1
            }

            let make = asset.exifInfo?.make ?? ""
            let model = asset.exifInfo?.model ?? ""
            let cam = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
            if !cam.isEmpty { cameraCounts[cam, default: 0] += 1 }

            for person in asset.people ?? [] {
                personCounts[person.id, default: 0] += 1
            }

            if date >= earliest364d && date <= now {
                heatBuckets[calendar.startOfDay(for: date), default: 0] += 1
            }
        }

        photosByMonth = monthCounts.map { MonthStat(id: $0.key, month: $0.value.date, count: $0.value.count) }
            .sorted { $0.month < $1.month }

        if sampleTotal > 0 && totalUsage > 0 {
            let scale = Double(totalUsage) / Double(sampleTotal)
            breakdown.photos = Int64(Double(breakdown.photos) * scale)
            breakdown.videos = Int64(Double(breakdown.videos) * scale)
            breakdown.raw   = Int64(Double(breakdown.raw)   * scale)
            breakdown.other = Int64(Double(breakdown.other) * scale)
        }
        storageBreakdown = breakdown

        topLocations = locationCounts
            .map { LocationStat(city: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }.prefix(5).map { $0 }

        topCameras = cameraCounts
            .map { CameraStat(makeModel: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }.prefix(8).map { $0 }

        topPeople = Array(allPeople
            .filter { !$0.name.isEmpty }
            .compactMap { p -> PersonStat? in
                guard let c = personCounts[p.id], c > 0 else { return nil }
                return PersonStat(id: p.id, person: p, count: c)
            }
            .sorted { $0.count > $1.count }.prefix(5))

        heatmapData = heatBuckets
    }
}
