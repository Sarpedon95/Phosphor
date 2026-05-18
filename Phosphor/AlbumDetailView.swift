import SwiftUI
import UIKit

struct AlbumDetailView: View {
    let album: ImmichAlbum
    @ObservedObject var viewModel: AlbumViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var selection: PhotoSelection?
    @State private var isEditing = false
    @State private var selected: Set<String> = []
    @State private var showReadOnlyAlert = false
    @State private var collageAssets: CollageAssetSelection?
    @State private var albumState: ImmichAlbum
    @State private var isEditingDescription = false
    @State private var descriptionDraft = ""
    @State private var sortMode: AlbumSortMode = .dateNewest
    @State private var showSharing = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    enum AlbumSortMode: String, CaseIterable, Identifiable {
        case dateNewest, dateOldest, fileName, recentlyAdded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dateNewest: return "Newest first"
            case .dateOldest: return "Oldest first"
            case .fileName: return "File name"
            case .recentlyAdded: return "Recently added"
            }
        }
    }

    init(album: ImmichAlbum, viewModel: AlbumViewModel) {
        self.album = album
        self.viewModel = viewModel
        self._albumState = State(initialValue: album)
    }

    private var sortedAssets: [ImmichAsset] {
        switch sortMode {
        case .dateNewest: return assets.sorted { $0.localDateTime > $1.localDateTime }
        case .dateOldest: return assets.sorted { $0.localDateTime < $1.localDateTime }
        case .fileName:
            return assets.sorted {
                $0.originalFileName.localizedCaseInsensitiveCompare($1.originalFileName) == .orderedAscending
            }
        case .recentlyAdded: return assets.sorted { $0.fileCreatedAt > $1.fileCreatedAt }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 2),
            count: horizontalSizeClass == .regular ? 4 : 3
        )
    }

    private var dateRange: String? {
        let dates = assets.map(\.localDateTime)
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        let loStr = Self.dateFormatter.string(from: lo)
        let hiStr = Self.dateFormatter.string(from: hi)
        return loStr == hiStr ? loStr : "\(loStr) – \(hiStr)"
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: Spacing.m) {
                    header
                    grid
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                HapticManager.impact(.light)
                await load()
            }

            if isEditing && !selected.isEmpty {
                removeBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        showSharing = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .foregroundStyle(.phosphorAccent)
                    .accessibilityLabel("Manage sharing")
                    if assets.count >= 2 {
                        Button {
                            collageAssets = CollageAssetSelection(assets: sortedAssets)
                        } label: {
                            Image(systemName: "rectangle.3.group")
                        }
                        .foregroundStyle(.phosphorAccent)
                        .accessibilityLabel("Create collage from this album")
                    }
                    Menu {
                        Picker("Sort", selection: $sortMode) {
                            ForEach(AlbumSortMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort album")

                    Button(isEditing ? "Done" : "Edit") {
                        HapticManager.selection()
                        isEditing.toggle()
                        selected.removeAll()
                    }
                    .foregroundStyle(.phosphorPrimary)
                }
            }
        }
        .fullScreenCover(item: $collageAssets) { selection in
            CollageView(assets: selection.assets)
        }
        .sheet(isPresented: $showSharing) {
            SharedAlbumManagementView(album: albumState) { _ in }
        }
        .task { if assets.isEmpty { await load() } }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                switch change {
                case .favorited(let asset):
                    if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                        assets[i] = asset
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

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(albumState.albumName)
                .font(Typography.displayTitle)
                .foregroundStyle(.phosphorPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text("\(assets.count) \(assets.count == 1 ? "item" : "items")")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
            if let dateRange {
                Text(dateRange)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            descriptionField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.s)
    }

    @ViewBuilder
    private var descriptionField: some View {
        if isEditingDescription {
            HStack {
                TextField("Description", text: $descriptionDraft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.phosphorAccent)
                    .submitLabel(.done)
                    .onSubmit { Task { await saveDescription() } }
                Button("Save") { Task { await saveDescription() } }
                    .foregroundStyle(.phosphorAccent)
            }
            .padding(Spacing.sm)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        } else if let desc = albumState.description, !desc.isEmpty {
            Text(desc)
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .onTapGesture {
                    descriptionDraft = desc
                    isEditingDescription = true
                }
                .accessibilityLabel("Album description: \(desc). Double-tap to edit.")
        } else {
            Button("Add a description") {
                descriptionDraft = ""
                isEditingDescription = true
            }
            .font(Typography.caption)
            .foregroundStyle(.phosphorSecondary)
        }
    }

    private func saveDescription() async {
        let text = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingDescription = false
        do {
            let updated = try await ImmichAPI.shared.updateAlbum(
                id: albumState.id,
                description: text
            )
            albumState = updated
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func setCover(to asset: ImmichAsset) async {
        do {
            let updated = try await ImmichAPI.shared.updateAlbum(
                id: albumState.id,
                thumbnailAssetId: asset.id
            )
            albumState = updated
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if assets.isEmpty && isLoading {
            ProgressView().tint(.phosphorPrimary).padding(.top, 60)
        } else if let loadError, assets.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(loadError.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorPrimary)
                    .accessibilityHint("Tries loading album contents again.")
            }
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(sortedAssets) { asset in
                    cell(asset)
                }
            }
        }
    }

    private func cell(_ asset: ImmichAsset) -> some View {
        AssetGridCell(asset: asset)
            .overlay {
                if isEditing {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(selected.contains(asset.id) ? 0.45 : 0.001)
                        Image(systemName: selected.contains(asset.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            }
            .onTapGesture {
                if isEditing {
                    toggleSelect(asset.id)
                } else {
                    open(asset)
                }
            }
            .contextMenu {
                Button {
                    HapticManager.impact(.medium)
                    HapticManager.notification(.success)
                    Task { await toggleFavorite(asset) }
                } label: {
                    Label(asset.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: asset.isFavorite ? "heart.slash" : "heart")
                }
                Button {
                    Task { await setCover(to: asset) }
                } label: {
                    Label("Set as Album Cover", systemImage: "photo.on.rectangle")
                }
                Button {
                    guard !isReadOnly else {
                        showReadOnlyAlert = true
                        return
                    }
                    Task { await removeFromAlbum([asset.id]) }
                } label: {
                    Label(
                        isReadOnly ? "Remove (Locked)" : "Remove from Album",
                        systemImage: isReadOnly ? "lock" : "rectangle.stack.badge.minus"
                    )
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

    private var removeBar: some View {
        VStack {
            Spacer()
            Button {
                guard !isReadOnly else {
                    showReadOnlyAlert = true
                    return
                }
                HapticManager.impact(.medium)
                let ids = Array(selected)
                Task { await removeFromAlbum(ids) }
            } label: {
                Text("Remove \(selected.count) from Album")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.m + 2)
                    .background(.phosphorDanger, in: Capsule())
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.m)
            }
            .accessibilityLabel("Remove \(selected.count) selected from album")
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let full = try await ImmichAPI.shared.fetchAlbum(id: album.id)
            assets = full.assets ?? []
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.selection()
        selection = PhotoSelection(assets: assets, index: index)
    }

    private func toggleSelect(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleFavorite(_ asset: ImmichAsset) async {
        guard let i = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let original = assets[i]
        assets[i].isFavorite.toggle()
        do {
            assets[i] = try await ImmichAPI.shared.toggleFavorite(asset: original)
        } catch {
            assets[i] = original
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

    private func removeFromAlbum(_ ids: [String]) async {
        let snapshot = assets
        assets.removeAll { ids.contains($0.id) }
        selected.removeAll()
        isEditing = false
        do {
            try await viewModel.removeAssets(ids, from: album)
        } catch {
            assets = snapshot
            HapticManager.notify(.error)
        }
    }
}
