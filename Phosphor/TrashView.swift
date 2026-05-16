import SwiftUI

struct TrashView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var showRestoreAll = false
    @State private var showEmptyTrash = false
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
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showRestoreAll = true
                    } label: {
                        Label("Restore All", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        if isReadOnly { return }
                        showEmptyTrash = true
                    } label: {
                        Label(isReadOnly ? "Empty Trash (Locked)" : "Empty Trash",
                              systemImage: isReadOnly ? "lock" : "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(assets.isEmpty)
                .accessibilityLabel("Trash actions")
            }
        }
        .task { if assets.isEmpty { await load() } }
        .alert("Restore all photos?", isPresented: $showRestoreAll) {
            Button("Cancel", role: .cancel) {}
            Button("Restore All") { Task { await restoreAll() } }
        }
        .alert("Permanently delete everything?", isPresented: $showEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) { Task { await emptyTrash() } }
        } message: {
            Text("This permanently deletes all \(assets.count) items. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if assets.isEmpty && isLoading {
            ProgressView().tint(.phosphorPrimary)
        } else if let loadError, assets.isEmpty {
            errorState(loadError)
        } else if assets.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "trash")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("Trash is empty")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { asset in
                        AssetGridCell(asset: asset)
                            .overlay(Color.phosphorDanger.opacity(0.18))
                            .contextMenu {
                                Button {
                                    Task { await restore([asset.id]) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    Task { await deletePermanently([asset.id]) }
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash.slash")
                                }
                            }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
    }

    private func errorState(_ error: ImmichError) -> some View {
        VStack(spacing: Spacing.m + 2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.yellow)
            Text(error.localizedDescription)
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
            Button("Retry") { Task { await load() } }
                .foregroundStyle(.phosphorPrimary)
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchTrashed(page: 1)
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func restore(_ ids: [String]) async {
        let snapshot = assets
        assets.removeAll { ids.contains($0.id) }
        do {
            try await ImmichAPI.shared.restoreAssets(ids: ids)
            HapticManager.notification(.success)
        } catch {
            assets = snapshot
            HapticManager.notification(.error)
        }
    }

    private func restoreAll() async {
        await restore(assets.map(\.id))
    }

    private func deletePermanently(_ ids: [String]) async {
        let snapshot = assets
        assets.removeAll { ids.contains($0.id) }
        do {
            try await ImmichAPI.shared.deleteAssetsPermanently(ids: ids)
            HapticManager.notification(.success)
        } catch {
            assets = snapshot
            HapticManager.notification(.error)
        }
    }

    private func emptyTrash() async {
        let snapshot = assets
        assets = []
        do {
            try await ImmichAPI.shared.emptyTrash()
            HapticManager.notification(.success)
        } catch {
            assets = snapshot
            HapticManager.notification(.error)
        }
    }
}
