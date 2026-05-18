import Foundation

extension UserDefaults {
    /// Shared App Group suite used by both the main app and the widget
    /// extension. Falls back to `.standard` if the suite isn't available.
    static let phosphor: UserDefaults = {
        UserDefaults(suiteName: AppSettings.appGroupID) ?? .standard
    }()
}

// MARK: - Enums used by settings

enum TimelineViewMode: String, CaseIterable, Identifiable {
    case grid, list, justified
    var id: String { rawValue }
}

enum GroupByUnit: String, CaseIterable, Identifiable {
    case day, month, year
    var id: String { rawValue }
}

enum TimelineSortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, recentlyAdded, fileName
    var id: String { rawValue }
}

enum AssetFilter: String, CaseIterable, Identifiable, Hashable {
    case photos, videos, favorites, livePhotos, screenshots, raw, fourStarPlus, flagged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .favorites: return "Favorites"
        case .livePhotos: return "Live Photos"
        case .screenshots: return "Screenshots"
        case .raw: return "RAW"
        case .fourStarPlus: return "★ 4+"
        case .flagged: return "Flagged"
        }
    }
}

enum LockDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case fiveSeconds = 5
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .immediately: return "Immediately"
        case .fiveSeconds: return "After 5 seconds"
        case .thirtySeconds: return "After 30 seconds"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        }
    }
}

/// Single source of truth for every `@AppStorage` key used in the app.
enum AppSettings {
    static let appGroupID = "group.com.sarpedon.phosphor"

    enum Keys {
        // Storage / safety / haptics
        static let readOnlyMode = "read_only_mode"
        static let showStorageIndicator = "show_storage_indicator"
        static let hapticsEnabled = "haptics_enabled"
        static let wifiOnlyBackup = "wifi_only_backup"
        static let lastBackupDate = "last_backup_date"
        static let backupQueue = "backup_pending_ids"
        static let backupAlbums = "backup_album_ids"

        // Timeline layout
        static let gridDensity = "grid_density"
        static let timelineViewMode = "timeline_view_mode"
        static let groupByUnit = "group_by_unit"
        static let timelineSortOrder = "timeline_sort_order"

        // Notifications
        static let onThisDayNotificationsEnabled = "on_this_day_notifications_enabled"
        static let backupNotificationsEnabled = "backup_notifications_enabled"

        // Security
        static let appLockEnabled = "app_lock_enabled"
        static let lockDelaySeconds = "lock_delay_seconds"

        // Network
        static let uploadThrottleKBps = "upload_throttle_kbps"

        // Session continuity
        static let lastActiveTab = "last_active_tab"
        static let lastViewedAssetId = "last_viewed_asset_id"
        static let lastScrollSectionId = "last_scroll_section_id"
        static let recentlyViewedAssetIds = "recently_viewed_asset_ids"

        // Saved searches
        static let savedSearches = "saved_searches"

        // Server profiles
        static let serverProfiles = "server_profiles"
        static let activeServerProfile = "active_server_profile_id"

        // Album local sort (persisted per-album-id is overkill; one global value)
        static let albumsSortOrder = "albums_sort_order"

        // Excluded local albums (PHAssetCollection.localIdentifier list)
        static let excludedBackupAlbums = "excluded_backup_albums"
    }

    enum Defaults {
        static let readOnlyMode = false
        static let showStorageIndicator = true
        static let hapticsEnabled = true
        static let wifiOnlyBackup = true
        static let gridDensity = 3
        static let timelineViewMode = TimelineViewMode.grid
        static let groupByUnit = GroupByUnit.month
        static let timelineSortOrder = TimelineSortOrder.newest
        static let onThisDayNotificationsEnabled = true
        static let backupNotificationsEnabled = true
        static let appLockEnabled = false
        static let lockDelaySeconds = 5
        static let uploadThrottleKBps = 0
        static let lastActiveTab = 0
        static let recentlyViewedMax = 20
    }

    // MARK: - Non-view readers (UserDefaults direct)

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        let defaults = UserDefaults.phosphor
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.bool(forKey: key)
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        let defaults = UserDefaults.phosphor
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.integer(forKey: key)
    }

    static var isReadOnly: Bool { bool(Keys.readOnlyMode, default: Defaults.readOnlyMode) }
    static var hapticsEnabled: Bool { bool(Keys.hapticsEnabled, default: Defaults.hapticsEnabled) }
    static var appLockEnabled: Bool { bool(Keys.appLockEnabled, default: Defaults.appLockEnabled) }
    static var lockDelaySeconds: Int { int(Keys.lockDelaySeconds, default: Defaults.lockDelaySeconds) }
    static var uploadThrottleKBps: Int { int(Keys.uploadThrottleKBps, default: Defaults.uploadThrottleKBps) }
}
