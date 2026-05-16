import SwiftUI

struct FavoritesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var selection: PhotoSelection?
    @State private var showReadOnlyAlert = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 2),
            count: horizontalSizeClass == .regular ? 4 : 3
        )
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content

            if isSelecting {
                BulkActionsToolbar(
                    selectedIDs: selectedIDs,
                    onCancel: exitSelection,
                    onOutcome: handleBulk
                )
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isSelecting)
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !assets.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        HapticManager.selection()
                        if isSelecting { exitSelection() } else { isSelecting = true }
                    }
                    .foregroundStyle(.phosphorPrimary)
                }
            }
        }
        .task { if assets.isEmpty { await load() } }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                switch change {
                case .favorited(let asset):
                    if asset.isFavorite {
                        if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                            assets[i] = asset
                        }
                    } else {
                        assets.removeAll { $0.id == asset.id }
                    }
                case .trashed(let id):
                    assets.removeAll { $0.id == id }
                }
            }
        }
        .alert("Read-only mode is on", isPresented: $showReadOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Disable read-only mode in Profile to perform this action.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if assets.isEmpty && isLoading {
            ProgressView().tint(.phosphorPrimary)
        } else if let loadError, assets.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(loadError.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl + Spacing.s)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorPrimary)
                    .accessibilityHint("Tries loading favorites again.")
            }
        } else if assets.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "heart")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No favorites yet")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { asset in
                        AssetGridCell(asset: asset)
                            .overlay {
                                if isSelecting {
                                    ZStack(alignment: .topTrailing) {
                                        Color.black.opacity(selectedIDs.contains(asset.id) ? 0.45 : 0.001)
                                        Image(systemName: selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(.white)
                                            .padding(6)
                                    }
                                }
                            }
                            .onTapGesture {
                                if isSelecting {
                                    toggleSelect(asset.id)
                                } else {
                                    HapticManager.impact(.light)
                                    open(asset)
                                }
                            }
                            .contextMenu {
                                if !isSelecting {
                                    Button {
                                        HapticManager.impact(.medium)
                                        HapticManager.notification(.success)
                                        Task { await unfavorite(asset) }
                                    } label: {
                                        Label("Unfavorite", systemImage: "heart.slash")
                                    }
                                    if let shareURL = ImmichAPI.shared.originalURL(id: asset.id) {
                                        ShareLink(item: shareURL) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        guard !isReadOnly else {
                                            showReadOnlyAlert = true
                                            return
                                        }
                                        HapticManager.impact(.heavy)
                                        HapticManager.notification(.warning)
                                        Task { await trash(asset) }
                                    } label: {
                                        Label(
                                            isReadOnly ? "Trash (Locked)" : "Trash",
                                            systemImage: isReadOnly ? "lock" : "trash"
                                        )
                                    }
                                }
                            }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                HapticManager.impact(.light)
                await load()
            }
        }
    }

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func handleBulk(_ outcome: BulkOutcome) {
        switch outcome {
        case .favorited:
            break
        case .archived(let ids), .trashed(let ids):
            // Archived assets and trashed assets both leave the favorites grid.
            assets.removeAll { ids.contains($0.id) }
        }
        exitSelection()
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchFavorites(page: 1)
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.selection()
        selection = PhotoSelection(assets: assets, index: index)
    }

    private func unfavorite(_ asset: ImmichAsset) async {
        let snapshot = assets
        assets.removeAll { $0.id == asset.id }
        do {
            _ = try await ImmichAPI.shared.toggleFavorite(asset: asset)
        } catch {
            assets = snapshot
            HapticManager.notify(.error)
        }
    }

    private func trash(_ asset: ImmichAsset) async {
        let snapshot = assets
        assets.removeAll { $0.id == asset.id }
        do {
            try await ImmichAPI.shared.trashAssets(ids: [asset.id])
        } catch {
            assets = snapshot
            HapticManager.notify(.error)
        }
    }
}
