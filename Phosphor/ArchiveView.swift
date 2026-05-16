import SwiftUI

struct ArchiveView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var selection: PhotoSelection?
    @State private var showReadOnlyAlert = false
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
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { if assets.isEmpty { await load() } }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                if case .trashed(let id) = change {
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
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorPrimary)
            }
        } else if assets.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "archivebox")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No archived photos")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { asset in
                        AssetGridCell(asset: asset)
                            .onTapGesture {
                                HapticManager.impact(.light)
                                open(asset)
                            }
                            .contextMenu {
                                Button {
                                    Task { await unarchive(asset) }
                                } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    guard !isReadOnly else {
                                        showReadOnlyAlert = true
                                        return
                                    }
                                    Task { await trash(asset) }
                                } label: {
                                    Label(isReadOnly ? "Trash (Locked)" : "Trash",
                                          systemImage: isReadOnly ? "lock" : "trash")
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

    private func open(_ asset: ImmichAsset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        selection = PhotoSelection(assets: assets, index: index)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchArchived(page: 1)
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func unarchive(_ asset: ImmichAsset) async {
        let snapshot = assets
        assets.removeAll { $0.id == asset.id }
        do {
            _ = try await ImmichAPI.shared.toggleArchive(asset: asset)
            HapticManager.notification(.success)
        } catch {
            assets = snapshot
            HapticManager.notification(.error)
        }
    }

    private func trash(_ asset: ImmichAsset) async {
        let snapshot = assets
        assets.removeAll { $0.id == asset.id }
        do {
            try await ImmichAPI.shared.trashAssets(ids: [asset.id])
            HapticManager.notification(.success)
        } catch {
            assets = snapshot
            HapticManager.notification(.error)
        }
    }
}
