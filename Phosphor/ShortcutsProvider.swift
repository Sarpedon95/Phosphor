import AppIntents
import SwiftUI

/// Routes that Siri Shortcuts / Spotlight can request. `ContentView` observes
/// the shared router and reacts (switches tab, opens a sheet, pre-fills text).
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    enum Route: Equatable {
        case favorites
        case memories
        case search(String)
        case asset(String)
    }

    @Published var route: Route?

    /// Parse a `phosphor://` deep link (used by intents + Spotlight handoff).
    func handle(url: URL) {
        guard url.scheme == "phosphor" else { return }
        switch url.host {
        case "favorites": route = .favorites
        case "memories": route = .memories
        case "search":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            route = .search(q)
        case "asset":
            let id = url.pathComponents.dropFirst().first ?? ""
            if !id.isEmpty { route = .asset(id) }
        default:
            break
        }
    }
}

// MARK: - Intents

struct OpenFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Favorites"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.route = .favorites
        return .result()
    }
}

struct OpenMemoriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Memories"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.route = .memories
        return .result()
    }
}

struct StartBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Photos"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await BackupManager.shared.startForegroundBackup()
        return .result()
    }
}

struct SearchPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Photos"
    static var openAppWhenRun = true

    @Parameter(title: "Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.route = .search(query)
        return .result()
    }
}

// MARK: - Shortcuts

struct PhosphorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenFavoritesIntent(),
            phrases: ["Open Favorites in \(.applicationName)"],
            shortTitle: "Favorites",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: OpenMemoriesIntent(),
            phrases: ["Show Memories in \(.applicationName)"],
            shortTitle: "Memories",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: StartBackupIntent(),
            phrases: ["Back up photos with \(.applicationName)"],
            shortTitle: "Backup",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: SearchPhotosIntent(),
            phrases: ["Search photos in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}
