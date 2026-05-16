import SwiftUI
import UIKit

enum AlbumSort: String, CaseIterable {
    case recentlyModified = "Recently Modified"
    case alphabetical = "Alphabetical"
    case assetCount = "Asset Count"
}

struct AlbumsView: View {
    @StateObject private var viewModel = AlbumViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var albumZoom

    @State private var sort: AlbumSort = .recentlyModified
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var renameTarget: ImmichAlbum?
    @State private var renameText = ""
    @State private var deleteTarget: ImmichAlbum?
    @State private var actionError: String?
    @State private var showReadOnlyAlert = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14),
            count: horizontalSizeClass == .regular ? 3 : 2
        )
    }

    private var sortedAlbums: [ImmichAlbum] {
        switch sort {
        case .recentlyModified:
            return viewModel.albums.sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
        case .alphabetical:
            return viewModel.albums.sorted {
                $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending
            }
        case .assetCount:
            return viewModel.albums.sorted { $0.assetCount > $1.assetCount }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Albums")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
            .navigationDestination(for: ImmichAlbum.self) { album in
                albumDestination(album)
            }
            .navigationDestination(for: SmartAlbum.self) { smart in
                SmartAlbumGridView(album: smart)
            }
        }
        .tint(.white)
        .task {
            if viewModel.albums.isEmpty { await viewModel.loadAlbums() }
        }
        .alert("New Album", isPresented: $showNewAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
            Button("Create") {
                let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                newAlbumName = ""
                guard !name.isEmpty else { return }
                Task { await create(name: name) }
            }
        }
        .alert(
            "Rename Album",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Album name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let album = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        Task { await rename(album, to: name) }
                    }
                }
                renameTarget = nil
            }
        }
        .alert(
            "Delete Album?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { album in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                Task { await delete(album) }
                deleteTarget = nil
            }
        } message: { album in
            Text("\"\(album.albumName)\" will be permanently deleted.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) { actionError = nil }
        } message: { message in
            Text(message)
        }
        .alert("Read-only mode is on", isPresented: $showReadOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Disable read-only mode in Profile to perform this action.")
        }
    }

    private func create(name: String) async {
        do {
            _ = try await viewModel.createAlbum(name: name)
        } catch let caught {
            HapticManager.notify(.error)
            actionError = (caught as? ImmichError)?.localizedDescription
                ?? caught.localizedDescription
        }
    }

    private func rename(_ album: ImmichAlbum, to name: String) async {
        do {
            try await viewModel.renameAlbum(album, newName: name)
        } catch let caught {
            HapticManager.notify(.error)
            actionError = (caught as? ImmichError)?.localizedDescription
                ?? caught.localizedDescription
        }
    }

    private func delete(_ album: ImmichAlbum) async {
        do {
            try await viewModel.deleteAlbum(album)
        } catch let caught {
            HapticManager.notify(.error)
            actionError = (caught as? ImmichError)?.localizedDescription
                ?? caught.localizedDescription
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.error, viewModel.albums.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl + Spacing.s)
                Button("Retry") { Task { await viewModel.loadAlbums() } }
                    .foregroundStyle(.phosphorPrimary)
                    .accessibilityHint("Tries loading albums again.")
            }
        } else if viewModel.albums.isEmpty && viewModel.isLoading {
            ProgressView().tint(.phosphorPrimary)
        } else if viewModel.albums.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No albums yet")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                SmartAlbumsSection()
                LazyVGrid(columns: columns, spacing: Spacing.m + Spacing.xs + 2) {
                    ForEach(sortedAlbums) { album in
                        navigationLink(for: album)
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(album.albumName), \(album.assetCount) items")
                        .accessibilityAddTraits(.isLink)
                        .contextMenu {
                            Button {
                                renameText = album.albumName
                                renameTarget = album
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                if isReadOnly {
                                    showReadOnlyAlert = true
                                } else {
                                    deleteTarget = album
                                }
                            } label: {
                                Label(
                                    isReadOnly ? "Delete (Locked)" : "Delete",
                                    systemImage: isReadOnly ? "lock" : "trash"
                                )
                            }
                        }
                    }
                }
                .padding(Spacing.l)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                HapticManager.impact(.light)
                await viewModel.loadAlbums()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(AlbumSort.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort albums")
            .accessibilityHint("Sort by recently modified, alphabetical, or asset count.")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNewAlbum = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New album")
            .accessibilityHint("Creates a new empty album.")
        }
    }

    // MARK: - Zoom navigation (iOS 18+, additive)

    @ViewBuilder
    private func navigationLink(for album: ImmichAlbum) -> some View {
        if #available(iOS 18, *) {
            NavigationLink(value: album) {
                AlbumCard(album: album)
            }
            .matchedTransitionSource(id: album.id, in: albumZoom)
        } else {
            NavigationLink(value: album) {
                AlbumCard(album: album)
            }
        }
    }

    @ViewBuilder
    private func albumDestination(_ album: ImmichAlbum) -> some View {
        if #available(iOS 18, *) {
            AlbumDetailView(album: album, viewModel: viewModel)
                .navigationTransition(.zoom(sourceID: album.id, in: albumZoom))
        } else {
            AlbumDetailView(album: album, viewModel: viewModel)
        }
    }
}

// MARK: - Album card

private struct AlbumCard: View {
    let album: ImmichAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs + 2) {
            AlbumCover(assetId: album.albumThumbnailAssetId)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            Text(album.albumName)
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)
                .lineLimit(1)

            HStack(spacing: Spacing.xs) {
                Text("\(album.assetCount) \(album.assetCount == 1 ? "item" : "items")")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                if album.sharedUserCount > 0 {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.phosphorSecondary)
                    Text("\(album.sharedUserCount)")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            }
        }
    }
}

private struct AlbumCover: View {
    let assetId: String?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    ShimmerView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
        }
        .task(id: assetId) {
            guard let assetId else { return }
            image = await ImageLoader.shared.thumbnail(for: assetId, size: .preview)
        }
    }
}
