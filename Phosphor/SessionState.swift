import Foundation
import SwiftUI

/// Persists session continuity across launches.
///
/// Writes are coalesced: each `@Published` setter only hits `UserDefaults`
/// when the value actually changes, and the scroll-position write is debounced
/// at 1 s so a fast scroll doesn't thrash the suite.
@MainActor
final class SessionState: ObservableObject {
    static let shared = SessionState()

    @Published var lastActiveTab: Int {
        didSet {
            guard lastActiveTab != oldValue else { return }
            defaults.set(lastActiveTab, forKey: AppSettings.Keys.lastActiveTab)
        }
    }

    @Published var lastViewedAssetId: String {
        didSet {
            guard lastViewedAssetId != oldValue else { return }
            defaults.set(lastViewedAssetId, forKey: AppSettings.Keys.lastViewedAssetId)
            if !lastViewedAssetId.isEmpty {
                defaults.set(Date(), forKey: Self.lastViewedTimestampKey)
            } else {
                defaults.removeObject(forKey: Self.lastViewedTimestampKey)
            }
        }
    }

    @Published var lastScrollSectionId: String {
        didSet {
            guard lastScrollSectionId != oldValue else { return }
            defaults.set(lastScrollSectionId, forKey: AppSettings.Keys.lastScrollSectionId)
        }
    }

    @Published private(set) var recentlyViewedAssetIds: [String]

    /// Bumped when the user re-taps the currently-active tab. Tabs observe
    /// `.onChange(of:)` and scroll their primary container to the top.
    @Published var scrollToTopSignal: UUID = UUID()
    /// Tag of the tab that just received a re-tap, so peers ignore the signal.
    @Published var scrollToTopTab: Int = -1

    private static let lastViewedTimestampKey = "last_viewed_asset_timestamp"
    private static let continueFreshness: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults = .phosphor
    private var debounceTask: Task<Void, Never>?

    init() {
        self.lastActiveTab = defaults.integer(forKey: AppSettings.Keys.lastActiveTab)
        self.lastViewedAssetId = defaults.string(forKey: AppSettings.Keys.lastViewedAssetId) ?? ""
        self.lastScrollSectionId = defaults.string(forKey: AppSettings.Keys.lastScrollSectionId) ?? ""
        self.recentlyViewedAssetIds = defaults.stringArray(
            forKey: AppSettings.Keys.recentlyViewedAssetIds
        ) ?? []
    }

    /// True only when there's a stored last-viewed asset AND it was viewed
    /// within the last 24 hours. Past that, the "Continue where you left off"
    /// banner is stale and shouldn't show.
    var hasFreshContinue: Bool {
        guard !lastViewedAssetId.isEmpty else { return false }
        guard let ts = defaults.object(forKey: Self.lastViewedTimestampKey) as? Date
        else { return false }
        return Date().timeIntervalSince(ts) < Self.continueFreshness
    }

    // MARK: - Scroll position (debounced)

    /// Coalesce many `onAppear` calls into one write per second. Cancelled if
    /// the user keeps scrolling.
    func saveScrollPosition(sectionId: String) {
        guard sectionId != lastScrollSectionId else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.lastScrollSectionId = sectionId }
        }
    }

    // MARK: - Last viewed + Recently Viewed

    func saveLastViewedAsset(id: String) {
        guard !id.isEmpty else { return }
        lastViewedAssetId = id   // didSet stamps timestamp
        // Dedupe + cap.
        var list = recentlyViewedAssetIds.filter { $0 != id }
        list.insert(id, at: 0)
        if list.count > AppSettings.Defaults.recentlyViewedMax {
            list = Array(list.prefix(AppSettings.Defaults.recentlyViewedMax))
        }
        guard list != recentlyViewedAssetIds else { return }
        recentlyViewedAssetIds = list
        defaults.set(list, forKey: AppSettings.Keys.recentlyViewedAssetIds)
    }

    func clearRecentlyViewed() {
        recentlyViewedAssetIds = []
        defaults.removeObject(forKey: AppSettings.Keys.recentlyViewedAssetIds)
    }

    func clearContinue() {
        lastViewedAssetId = ""
    }

    /// Wipe everything — used when switching server profiles.
    func clearAll() {
        debounceTask?.cancel()
        lastActiveTab = 0
        lastViewedAssetId = ""
        lastScrollSectionId = ""
        recentlyViewedAssetIds = []
        defaults.removeObject(forKey: AppSettings.Keys.recentlyViewedAssetIds)
    }
}
