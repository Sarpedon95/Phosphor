import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager
    @EnvironmentObject private var profilesManager: ServerProfilesManager
    @StateObject private var viewModel: ProfileViewModel

    @State private var showAPIKey = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled: Bool = AppSettings.Defaults.hapticsEnabled
    @AppStorage(AppSettings.Keys.showStorageIndicator) private var showStorageIndicator: Bool = AppSettings.Defaults.showStorageIndicator

    private static let immichDocsURL = URL(string: "https://immich.app/docs")

    init(connectionManager: ConnectionManager) {
        _viewModel = StateObject(wrappedValue: ProfileViewModel(connectionManager: connectionManager))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                List {
                    serverSection
                    statsSection
                    librarySection
                    appearanceSection
                    safetySection
                    aboutSection
                    wordmarkSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Profile")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(.phosphorPrimary)
        .task { await viewModel.loadStats() }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section("Server") {
            NavigationLink {
                ServerProfilesView()
            } label: {
                HStack {
                    Label("Servers", systemImage: "server.rack")
                        .foregroundStyle(.phosphorAccent)
                    Spacer()
                    Text(activeServerName)
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                        .lineLimit(1)
                }
            }
            .listRowBackground(Color.phosphorSurface)
            .accessibilityHint("Switch, add, or remove server profiles.")

            TextField("https://immich.example.com", text: $viewModel.serverURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .listRowBackground(Color.phosphorSurface)
                .accessibilityLabel("Server URL")

            HStack {
                Group {
                    if showAPIKey {
                        TextField("API key", text: $viewModel.apiKey)
                    } else {
                        SecureField("API key", text: $viewModel.apiKey)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("API key")

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.phosphorSecondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
            }
            .listRowBackground(Color.phosphorSurface)

            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    if viewModel.isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.phosphorPrimary)
                        Text("Testing…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Test Connection")
                    }
                    Spacer()
                }
                .foregroundStyle(.phosphorPrimary)
            }
            .disabled(viewModel.isTestingConnection)
            .listRowBackground(Color.phosphorSurface)
            .accessibilityHint("Verifies the server URL and API key reach the Immich server.")

            if let result = viewModel.connectionResult {
                connectionResultRow(result)
            }
        }
    }

    @ViewBuilder
    private func connectionResultRow(_ result: ConnectionResult) -> some View {
        switch result {
        case .success(let version, let latency):
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.phosphorSuccess)
                Text("Connected · v\(version) · \(latency)ms")
                    .foregroundStyle(.phosphorPrimary)
            }
            .font(Typography.subheadline)
            .listRowBackground(Color.phosphorSurface)
        case .failure(let message):
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.phosphorDanger)
                Text(message)
                    .foregroundStyle(.phosphorPrimary)
            }
            .font(Typography.subheadline)
            .listRowBackground(Color.phosphorSurface)
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        Section {
            if let stats = viewModel.stats {
                statRow("Total Assets", value: "\(stats.totalAssets)")
                statRow("Photos", value: "\(stats.totalPhotos)")
                statRow("Videos", value: "\(stats.totalVideos)")
                statRow("Storage Used", value: StorageFormatter.string(fromBytes: stats.storageUsed))
                statRow("Albums", value: "\(stats.totalAlbums)")
                statRow("People", value: "\(stats.totalPeople)")
            } else if viewModel.isLoadingStats {
                HStack {
                    ProgressView().controlSize(.small).tint(.phosphorPrimary)
                    Text("Loading statistics…").foregroundStyle(.phosphorSecondary)
                }
                .listRowBackground(Color.phosphorSurface)
            } else if let error = viewModel.statsError {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(error.localizedDescription)
                        .font(Typography.footnote)
                        .foregroundStyle(.phosphorSecondary)
                    Button("Retry") {
                        Task { await viewModel.loadStats() }
                    }
                    .font(Typography.subheadline)
                }
                .listRowBackground(Color.phosphorSurface)
            }
        } header: {
            Text("Statistics")
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.phosphorSecondary)
            Spacer()
            Text(value).foregroundStyle(.phosphorPrimary).font(Typography.monoStat)
        }
        .listRowBackground(Color.phosphorSurface)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.phosphorSecondary)
                Text("Always Dark — by design")
                    .foregroundStyle(.phosphorSecondary)
                Spacer()
                // A locked toggle communicates the intent more clearly than
                // hiding the row entirely.
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .disabled(true)
            }
            .listRowBackground(Color.phosphorSurface)
            .accessibilityLabel("Dark mode is permanently enabled")
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            Toggle(isOn: $isReadOnly) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read-only Mode")
                        Text("Disables trash, delete, and remove-from-album actions across the app.")
                            .font(Typography.footnote)
                            .foregroundStyle(.phosphorSecondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                }
            }
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)
            .accessibilityHint("When on, destructive actions are blocked everywhere in the app.")

            Toggle(isOn: $hapticsEnabled) {
                Label("Haptics", systemImage: "waveform")
            }
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)

            Toggle(isOn: $showStorageIndicator) {
                Label("Storage Indicator", systemImage: "externaldrive")
            }
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)
        } header: {
            Text("Safety & Behavior")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version").foregroundStyle(.phosphorSecondary)
                Spacer()
                Text(versionString).foregroundStyle(.phosphorPrimary)
            }
            .listRowBackground(Color.phosphorSurface)

            if let url = Self.immichDocsURL {
                Link(destination: url) {
                    HStack {
                        Label("Immich Docs", systemImage: "book")
                            .foregroundStyle(.phosphorPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.phosphorSecondary)
                    }
                }
                .listRowBackground(Color.phosphorSurface)
                .accessibilityHint("Opens the Immich documentation website in Safari.")
            }

        }
    }

    // MARK: - Library management

    private var librarySection: some View {
        Section("Library") {
            libraryLink("Favorites", "heart") { FavoritesView() }
            libraryLink("Backup", "arrow.up.circle") { BackupView() }
            libraryLink("Trash", "trash") { TrashView() }
            libraryLink("Archive", "archivebox") { ArchiveView() }
            libraryLink("Shared Links", "link") { SharedLinksView() }
            libraryLink("Duplicates", "square.on.square") { DuplicatesView() }
            libraryLink("Insights", "chart.bar") { InsightsView() }
        }
    }

    private func libraryLink<Destination: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: symbol)
        }
        .listRowBackground(Color.phosphorSurface)
        .accessibilityHint("Opens \(title).")
    }

    private var wordmarkSection: some View {
        Section {
            HStack {
                Spacer()
                Text("Phosphor")
                    .font(Typography.wordmark)
                    .foregroundStyle(.phosphorSecondary)
                    .padding(.vertical, Spacing.xl)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var activeServerName: String {
        if let active = profilesManager.activeProfileId,
           let profile = profilesManager.profiles.first(where: { $0.id == active }) {
            return profile.name
        }
        return profilesManager.profiles.isEmpty ? "None" : "Unsaved"
    }
}
