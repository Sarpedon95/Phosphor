import Foundation

enum SearchMode: String, CaseIterable {
    case smart = "Smart"
    case metadata = "Metadata"
}

/// A suggested search topic from `GET /search/explore`.
struct ExploreItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let asset: ImmichAsset
}

/// User-saveable search definition (persisted as JSON).
struct SavedSearch: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var query: String
    var dateFrom: Date?
    var dateTo: Date?
    var city: String?
    var camera: String?
    var albumScopeId: String?
    var createdAt: Date

    var filterSummary: String {
        var parts: [String] = []
        if let city { parts.append(city) }
        if let camera { parts.append(camera) }
        if dateFrom != nil || dateTo != nil { parts.append("date range") }
        if albumScopeId != nil { parts.append("in album") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

@MainActor
final class SearchViewModel: ObservableObject {

    @Published var searchMode: SearchMode = .smart
    @Published private(set) var results: [ImmichAsset] = []
    @Published private(set) var isSearching = false
    @Published private(set) var exploreItems: [ExploreItem] = []
    @Published private(set) var recentSearches: [String] = []
    @Published var error: ImmichError?

    // Filter state
    @Published var dateFrom: Date?
    @Published var dateTo: Date?
    @Published var locationFilter: String?
    @Published var cameraFilter: String?
    @Published var albumScopeId: String?

    @Published private(set) var savedSearches: [SavedSearch] = []

    private let defaults: UserDefaults
    private static let recentsKey = "recent_searches"
    private let maxRecents = 10

    init(defaults: UserDefaults = .phosphor) {
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Self.recentsKey) ?? []
        if let data = defaults.data(forKey: AppSettings.Keys.savedSearches),
           let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            savedSearches = decoded
        }
    }

    var hasActiveFilters: Bool {
        dateFrom != nil || dateTo != nil || locationFilter != nil
            || cameraFilter != nil || albumScopeId != nil
    }

    func clearFilters() {
        dateFrom = nil
        dateTo = nil
        locationFilter = nil
        cameraFilter = nil
        albumScopeId = nil
    }

    /// Debounced filtered search.
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runEmptyQueryFilters = trimmed.isEmpty && hasActiveFilters
        guard !trimmed.isEmpty || runEmptyQueryFilters else {
            results = []
            isSearching = false
            return
        }

        // Date range sanity: if the user has both endpoints and they're
        // inverted, refuse to run rather than sending a request that returns
        // nothing meaningful. The UI shows the chips so the inversion is
        // visible.
        if let from = dateFrom, let to = dateTo, to < from {
            results = []
            isSearching = false
            return
        }

        do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
        if Task.isCancelled { return }

        isSearching = true
        error = nil
        defer { isSearching = false }
        do {
            let (make, model) = splitCamera(cameraFilter)
            let assets: [ImmichAsset]
            if !trimmed.isEmpty && !hasActiveFilters {
                switch searchMode {
                case .smart:
                    assets = try await ImmichAPI.shared.searchSmart(query: trimmed, page: 1)
                case .metadata:
                    assets = try await ImmichAPI.shared.searchMetadata(query: trimmed, page: 1)
                }
            } else {
                assets = try await ImmichAPI.shared.searchFiltered(
                    query: trimmed.isEmpty ? nil : trimmed,
                    city: locationFilter,
                    make: make,
                    model: model,
                    takenAfter: dateFrom,
                    takenBefore: dateTo,
                    albumId: albumScopeId,
                    page: 1,
                    size: 200
                )
            }
            if Task.isCancelled { return }
            results = assets
            if !trimmed.isEmpty { addRecent(trimmed) }
        } catch let caught {
            results = []
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func loadExplore() async {
        guard exploreItems.isEmpty else { return }
        do {
            exploreItems = try await ImmichAPI.shared.fetchExplore()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func applyExternalUpdate(_ asset: ImmichAsset) {
        if let i = results.firstIndex(where: { $0.id == asset.id }) {
            results[i] = asset
        }
    }

    func removeExternally(id: String) {
        results.removeAll { $0.id == id }
    }

    func clearRecentSearches() {
        recentSearches = []
        defaults.removeObject(forKey: Self.recentsKey)
    }

    // MARK: - Saved searches

    func saveCurrentSearch(name: String, query: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = SavedSearch(
            id: UUID(),
            name: trimmed,
            query: query,
            dateFrom: dateFrom,
            dateTo: dateTo,
            city: locationFilter,
            camera: cameraFilter,
            albumScopeId: albumScopeId,
            createdAt: Date()
        )
        savedSearches.insert(entry, at: 0)
        persistSaved()
    }

    func deleteSavedSearch(_ search: SavedSearch) {
        savedSearches.removeAll { $0.id == search.id }
        persistSaved()
    }

    func loadSavedSearch(_ search: SavedSearch) -> String {
        dateFrom = search.dateFrom
        dateTo = search.dateTo
        locationFilter = search.city
        cameraFilter = search.camera
        albumScopeId = search.albumScopeId
        return search.query
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedSearches) {
            defaults.set(data, forKey: AppSettings.Keys.savedSearches)
        }
    }

    // MARK: - Helpers

    private func splitCamera(_ combined: String?) -> (String?, String?) {
        guard let combined, !combined.isEmpty else { return (nil, nil) }
        let parts = combined.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (combined, nil)
    }

    private func addRecent(_ query: String) {
        var list = recentSearches.filter {
            $0.caseInsensitiveCompare(query) != .orderedSame
        }
        list.insert(query, at: 0)
        if list.count > maxRecents { list = Array(list.prefix(maxRecents)) }
        recentSearches = list
        defaults.set(list, forKey: Self.recentsKey)
    }
}
