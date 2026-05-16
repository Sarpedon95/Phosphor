import SwiftUI
import CoreSpotlight

@main
struct PhosphorApp: App {
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var session = SessionState.shared
    @StateObject private var appLock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBackground = false
    // Connection + profiles share a single ConnectionManager.
    @StateObject private var connectionManager: ConnectionManager
    @StateObject private var profilesManager: ServerProfilesManager

    init() {
        BGTaskManager.registerHandlers()
        Task { @MainActor in
            BGTaskManager.scheduleRefresh()
        }
        let conn = ConnectionManager()
        _connectionManager = StateObject(wrappedValue: conn)
        _profilesManager = StateObject(wrappedValue: ServerProfilesManager(connection: conn))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(connectionManager: connectionManager)
                    .environmentObject(router)
                    .environmentObject(session)
                    .environmentObject(appLock)
                    .environmentObject(profilesManager)
                    .onOpenURL { url in router.handle(url: url) }
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        if let id = SpotlightIndexer.assetID(from: activity.userInfo ?? [:]) {
                            router.route = .asset(id)
                        }
                    }

                if appLock.isLocked {
                    LockScreenView()
                        .environmentObject(appLock)
                }

                // Privacy curtain. MUST be:
                //   1. Raised on `.inactive` (the system snapshots between
                //      active→background for the app-switcher), not on
                //      `.background`.
                //   2. Drawn with no animation — using `Group { ... }
                //      .animation(nil, value: isBackground)` so any inherited
                //      animation from the parent hierarchy is cleared.
                Group {
                    if isBackground {
                        Color.black.ignoresSafeArea()
                    }
                }
                .animation(nil, value: isBackground)
            }
            .onChange(of: scenePhase) { _, newPhase in
                handlePhase(newPhase)
            }
        }
    }

    private func handlePhase(_ phase: ScenePhase) {
        // Apply state changes *synchronously* in the order the system needs:
        // curtain up first, lock scheduled second.
        switch phase {
        case .inactive:
            // Pre-snapshot moment. Raise the curtain immediately and with no
            // animation. Do NOT start the lock timer yet — the user could be
            // pulling down the notification shade or splitting on iPad.
            isBackground = true
        case .background:
            isBackground = true
            appLock.scheduleLockOnBackground()
        case .active:
            isBackground = false
            appLock.cancelScheduledLock()
        @unknown default:
            break
        }
    }
}
