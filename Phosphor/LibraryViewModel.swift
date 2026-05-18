import Foundation

/// A month/year (or day/year) section of the timeline.
struct TimelineGroup: Identifiable, Hashable {
    let id: String
    let title: String
    var assets: [ImmichAsset]
}

@MainActor
final class LibraryViewModel: ObservableObject {

    @Published private(set) var groupedAssets: [TimelineGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var error: ImmichError?
    @Published var activeFilters: Set<AssetFilter> = []
    @Published var groupBy: GroupByUnit = AppSettings.Defaults.groupByUnit {
        didSet { regroup() }
    }
    @Published var sortOrder: TimelineSortOrder = AppSettings.Defaults.timelineSortOrder {
        didSet { sortCache = nil; regroup() }
    }

    private let pageSize = 100
    private var currentPage = 0
    private var isPaging = false
    private var allAssets: [ImmichAsset] = [] {
        didSet { sortCache = nil; yearCache = nil }
    }

    private var sortCache: (order: TimelineSortOrder, assets: [ImmichAsset])?
    private var yearCache: (years: [Int], counts: [Int: Int], reps: [Int: ImmichAsset])?

    // MARK: - Derived

    /// Timeline groups with `activeFilters` applied. Views render this, not
    /// `groupedAssets` directly.
    var filteredGroupedAssets: [TimelineGroup] {
        guard !activeFilters.isEmpty else { return groupedAssets }
        return groupedAssets.compactMap { group in
            let filtered = group.assets.filter(matches)
            return filtered.isEmpty ? nil : TimelineGroup(
                id: group.id, title: group.title, assets: filtered
            )
        }
    }

    var totalAssetCount: Int { allAssets.count }
    var filteredAssetCount: Int { filteredGroupedAssets.reduce(0) { $0 + $1.assets.count } }

    /// Distinct years present in the loaded timeline, newest first.
    var years: [Int] { buildYearCache().years }

    func representative(forYear year: Int) -> ImmichAsset? { buildYearCache().reps[year] }

    func assetCount(forYear year: Int) -> Int { buildYearCache().counts[year] ?? 0 }

    private func buildYearCache() -> (years: [Int], counts: [Int: Int], reps: [Int: ImmichAsset]) {
        if let cache = yearCache { return cache }
        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        var reps: [Int: ImmichAsset] = [:]
        for asset in allAssets {
            let year = calendar.component(.year, from: asset.localDateTime)
            counts[year, default: 0] += 1
            if reps[year] == nil { reps[year] = asset }
        }
        let years = counts.keys.sorted(by: >)
        let result = (years, counts, reps)
        yearCache = result
        return result
    }

    // MARK: - Loading

    func loadInitial() async {
        currentPage = 0
        allAssets = []
        groupedAssets = []
        hasMore = true
        error = nil
        await loadNextPage()
        let snapshot = allAssets
        Task.detached(priority: .background) {
            await SpotlightIndexer.index(snapshot)
        }
    }

    func loadNextPage() async {
        guard !isPaging, hasMore else { return }
        isPaging = true
        isLoading = true
        defer {
            isPaging = false
            isLoading = false
        }

        let nextPage = currentPage + 1
        do {
            let page = try await ImmichAPI.shared.fetchTimeline(
                page: nextPage, pageSize: pageSize
            )
            currentPage = nextPage
            hasMore = page.count == pageSize
            let known = Set(allAssets.map(\.id))
            allAssets.append(contentsOf: page.filter { !known.contains($0.id) })
            regroup()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func refresh() async {
        currentPage = 0
        hasMore = true
        error = nil
        isPaging = false
        do {
            let page = try await ImmichAPI.shared.fetchTimeline(
                page: 1, pageSize: pageSize
            )
            currentPage = 1
            hasMore = page.count == pageSize
            allAssets = page
            regroup()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    // MARK: - Mutations

    func toggleFavorite(_ asset: ImmichAsset) async {
        guard let loc = locate(asset.id) else { return }
        let original = groupedAssets[loc.g].assets[loc.a]
        applyFavorite(!original.isFavorite, id: asset.id)
        do {
            let updated = try await ImmichAPI.shared.toggleFavorite(asset: original)
            replace(updated)
        } catch let caught {
            replace(original)
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func trashAsset(_ asset: ImmichAsset) async {
        let snapshot = allAssets
        allAssets.removeAll { $0.id == asset.id }
        regroup()
        do {
            try await ImmichAPI.shared.trashAssets(ids: [asset.id])
        } catch let caught {
            allAssets = snapshot
            regroup()
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func applyExternalUpdate(_ asset: ImmichAsset) { replace(asset) }

    func removeExternally(id: String) {
        allAssets.removeAll { $0.id == id }
        regroup()
        Task.detached(priority: .background) {
            await SpotlightIndexer.remove(ids: [id])
        }
    }

    // MARK: - Filter helpers

    private func matches(_ asset: ImmichAsset) -> Bool {
        // OR within categories, AND across categories (intuitive default).
        for filter in activeFilters {
            switch filter {
            case .photos: if asset.type != .image { return false }
            case .videos: if asset.type != .video { return false }
            case .favorites: if !asset.isFavorite { return false }
            case .livePhotos: if !asset.isLivePhoto { return false }
            case .screenshots:
                if !asset.originalFileName.localizedCaseInsensitiveContains("screenshot") {
                    return false
                }
            case .raw:
                let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
                if !["cr2", "arw", "nef", "dng", "rw2", "raf", "orf"].contains(ext) {
                    return false
                }
            case .fourStarPlus:
                // nil rating treated as 0 → excluded.
                if asset.ratingValue < 4 { return false }
            case .flagged:
                if !asset.isFavorite { return false }
            }
        }
        return true
    }

    // MARK: - Helpers

    private func locate(_ id: String) -> (g: Int, a: Int)? {
        for (g, group) in groupedAssets.enumerated() {
            if let a = group.assets.firstIndex(where: { $0.id == id }) {
                return (g, a)
            }
        }
        return nil
    }

    private func applyFavorite(_ value: Bool, id: String) {
        if let loc = locate(id) {
            groupedAssets[loc.g].assets[loc.a].isFavorite = value
        }
        if let i = allAssets.firstIndex(where: { $0.id == id }) {
            allAssets[i].isFavorite = value
        }
    }

    private func replace(_ asset: ImmichAsset) {
        if let loc = locate(asset.id) {
            groupedAssets[loc.g].assets[loc.a] = asset
        }
        if let i = allAssets.firstIndex(where: { $0.id == asset.id }) {
            allAssets[i] = asset
        }
    }

    // MARK: - Grouping (respects groupBy + sortOrder)

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; return f
    }()
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy"; return f
    }()

    private func sortedAssets() -> [ImmichAsset] {
        if let cache = sortCache, cache.order == sortOrder { return cache.assets }
        let sorted: [ImmichAsset]
        switch sortOrder {
        case .newest:
            sorted = allAssets.sorted { $0.localDateTime > $1.localDateTime }
        case .oldest:
            sorted = allAssets.sorted { $0.localDateTime < $1.localDateTime }
        case .recentlyAdded:
            sorted = allAssets.sorted { $0.fileCreatedAt > $1.fileCreatedAt }
        case .fileName:
            sorted = allAssets.sorted {
                $0.originalFileName.localizedCaseInsensitiveCompare($1.originalFileName) == .orderedAscending
            }
        }
        sortCache = (sortOrder, sorted)
        return sorted
    }

    private func bucketKey(for date: Date, calendar: Calendar) -> (key: String, title: String) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        switch groupBy {
        case .day:
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
            return (key, Self.dayFormatter.string(from: date))
        case .month:
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            return (key, Self.monthYearFormatter.string(from: date))
        case .year:
            let key = "\(comps.year ?? 0)"
            return (key, Self.yearFormatter.string(from: date))
        }
    }

    private func regroup() {
        let calendar = Calendar.current
        let sorted = sortedAssets()

        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [ImmichAsset]] = [:]
        for asset in sorted {
            let (key, title) = bucketKey(for: asset.localDateTime, calendar: calendar)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
                titles[key] = title
            }
            buckets[key]?.append(asset)
        }

        groupedAssets = order.map { key in
            TimelineGroup(
                id: key,
                title: titles[key] ?? "",
                assets: buckets[key] ?? []
            )
        }
    }
}
