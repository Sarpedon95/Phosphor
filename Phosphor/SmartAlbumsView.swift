import SwiftUI

/// A virtual album defined by a search query rather than a stored album id.
struct SmartAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let sfSymbol: String
    let kind: Kind

    enum Kind: Hashable {
        case thisYear
        case last30Days
        case allVideos
        case allFavorites
        case unarchived
        case screenshots
        case rawFiles
        case noLocation
    }

    static let all: [SmartAlbum] = [
        .init(id: "thisYear", name: "This Year", sfSymbol: "calendar", kind: .thisYear),
        .init(id: "last30", name: "Last 30 Days", sfSymbol: "clock", kind: .last30Days),
        .init(id: "videos", name: "All Videos", sfSymbol: "video", kind: .allVideos),
        .init(id: "favs", name: "All Favorites", sfSymbol: "heart", kind: .allFavorites),
        .init(id: "unarchived", name: "Unarchived", sfSymbol: "tray", kind: .unarchived),
        .init(id: "screenshots", name: "Screenshots", sfSymbol: "camera.viewfinder", kind: .screenshots),
        .init(id: "raw", name: "RAW Files", sfSymbol: "circle.hexagongrid", kind: .rawFiles),
        .init(id: "noLocation", name: "No Location", sfSymbol: "location.slash", kind: .noLocation)
    ]
}

@MainActor
final class SmartAlbumViewModel: ObservableObject {
    @Published private(set) var assets: [ImmichAsset] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?

    let album: SmartAlbum

    init(album: SmartAlbum) {
        self.album = album
    }

    func load() async {
        guard assets.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let calendar = Calendar.current
            let now = Date()

            switch album.kind {
            case .thisYear:
                let start = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1))
                assets = try await ImmichAPI.shared.searchFiltered(
                    takenAfter: start, takenBefore: now, size: 500
                )
            case .last30Days:
                let start = calendar.date(byAdding: .day, value: -30, to: now)
                assets = try await ImmichAPI.shared.searchFiltered(
                    takenAfter: start, takenBefore: now, size: 500
                )
            case .allVideos:
                assets = try await ImmichAPI.shared.searchFiltered(isVideo: true, size: 500)
            case .allFavorites:
                assets = try await ImmichAPI.shared.fetchFavorites(page: 1)
            case .unarchived:
                assets = try await ImmichAPI.shared.searchFiltered(isArchived: false, size: 500)
            case .screenshots:
                let recent = try await ImmichAPI.shared.searchFiltered(size: 500)
                assets = recent.filter {
                    $0.originalFileName.localizedCaseInsensitiveContains("screenshot")
                }
            case .rawFiles:
                let recent = try await ImmichAPI.shared.searchFiltered(size: 500)
                let exts: Set<String> = ["cr2", "arw", "nef", "dng", "rw2", "raf", "orf"]
                assets = recent.filter {
                    exts.contains(($0.originalFileName as NSString).pathExtension.lowercased())
                }
            case .noLocation:
                let recent = try await ImmichAPI.shared.searchFiltered(size: 500)
                assets = recent.filter { $0.exifInfo?.latitude == nil || $0.exifInfo?.longitude == nil }
            }
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }
}

struct SmartAlbumGridView: View {
    let album: SmartAlbum
    @StateObject private var viewModel: SmartAlbumViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: PhotoSelection?

    init(album: SmartAlbum) {
        self.album = album
        _viewModel = StateObject(wrappedValue: SmartAlbumViewModel(album: album))
    }

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
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.load() }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.assets.isEmpty {
            ProgressView().tint(.phosphorAccent)
        } else if let error = viewModel.error, viewModel.assets.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                Button("Retry") { Task { await viewModel.load() } }
                    .foregroundStyle(.phosphorAccent)
            }
        } else if viewModel.assets.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: album.sfSymbol)
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("Nothing here yet")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorAccent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.assets) { asset in
                        AssetGridCell(asset: asset)
                            .onTapGesture {
                                guard let i = viewModel.assets.firstIndex(where: { $0.id == asset.id }) else { return }
                                HapticManager.impact(.light)
                                selection = PhotoSelection(assets: viewModel.assets, index: i)
                            }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Top section of `AlbumsView` listing smart albums above user albums.
struct SmartAlbumsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Smart Albums")
                .font(Typography.title3)
                .foregroundStyle(.phosphorAccent)
                .padding(.horizontal, Spacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(SmartAlbum.all) { album in
                        NavigationLink(value: album) {
                            VStack(spacing: Spacing.xs) {
                                Image(systemName: album.sfSymbol)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.phosphorAccent)
                                    .frame(width: 64, height: 64)
                                    .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
                                Text(album.name)
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorAccent)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(album.name)
                    }
                }
                .padding(.horizontal, Spacing.md)
            }
        }
        .padding(.bottom, Spacing.md)
    }
}
