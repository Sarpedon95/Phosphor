import SwiftUI

struct ContentView: View {
    @ObservedObject var connectionManager: ConnectionManager
    @StateObject private var authState = AuthState.shared
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var session: SessionState

    @State private var selectedTab = Tab.library
    @State private var deepLinkedAsset: PhotoSelection?
    @State private var searchPrefill = ""

    enum Tab: Int, Hashable {
        case library = 0
        case albums = 1
        case search = 2
        case map = 3
        case profile = 4
    }

    /// Custom binding so a tap on the already-active tab posts a
    /// `scrollToTopSignal` for that tab to consume.
    private var tabBinding: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    session.scrollToTopTab = newValue.rawValue
                    session.scrollToTopSignal = UUID()
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabBinding) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
                .tag(Tab.library)

            AlbumsView()
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                .tag(Tab.albums)

            SearchView(initialQuery: searchPrefill)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)

            ProfileView(connectionManager: connectionManager)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .tint(.phosphorPrimary)
        .preferredColorScheme(.dark)
        .environmentObject(connectionManager)
        .overlay(alignment: .top) {
            ConnectionBanner(connection: connectionManager)
                .padding(.top, 0)
        }
        .fullScreenCover(isPresented: showOnboarding) {
            OnboardingView(connectionManager: connectionManager)
                .environmentObject(connectionManager)
        }
        .fullScreenCover(item: $deepLinkedAsset) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
        .sheet(isPresented: reauthBinding) {
            OnboardingView(connectionManager: connectionManager)
                .environmentObject(connectionManager)
                .interactiveDismissDisabled(true)
        }
        .onChange(of: router.route) { _, newValue in
            handle(newValue)
        }
        .onChange(of: connectionManager.isConnected) { _, connected in
            // A fresh successful connection clears any pending re-auth prompt.
            if connected { authState.clear() }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == newTab {
                // SwiftUI doesn't normally fire `.onChange` for the same value,
                // so this branch is defensive. The actual re-tap path is the
                // `Binding` interception below.
                session.scrollToTopTab = newTab.rawValue
                session.scrollToTopSignal = UUID()
            }
            session.lastActiveTab = newTab.rawValue
        }
        .onAppear {
            if let restored = Tab(rawValue: session.lastActiveTab) {
                selectedTab = restored
            }
        }
    }

    /// Re-auth prompt: shown when a request was rejected (401/403) but the
    /// user still has stored credentials (so onboarding's `!isConfigured`
    /// gate wouldn't fire).
    private var reauthBinding: Binding<Bool> {
        Binding(
            get: { authState.needsReauth && connectionManager.isConfigured },
            set: { if !$0 { authState.clear() } }
        )
    }

    private func handle(_ route: DeepLinkRouter.Route?) {
        guard let route else { return }
        switch route {
        case .favorites, .memories:
            // Both live under the Library tab (Memories is its header strip;
            // Favorites is reachable from Profile). Route to the closest tab.
            selectedTab = route == .favorites ? .profile : .library
        case .search(let query):
            searchPrefill = query
            selectedTab = .search
        case .asset(let id):
            Task {
                if let asset = try? await ImmichAPI.shared.fetchAsset(id: id) {
                    deepLinkedAsset = PhotoSelection(assets: [asset], index: 0)
                }
            }
        }
        // Consume the route so re-entry doesn't re-trigger.
        router.route = nil
    }

    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !connectionManager.isConfigured },
            set: { _ in }
        )
    }
}
