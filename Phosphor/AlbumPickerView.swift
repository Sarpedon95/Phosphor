import SwiftUI

/// Picks an album to add one or more assets to. Fetches the album list on
/// appear; on tap, posts the assets and dismisses.
struct AlbumPickerView: View {
    let assetIds: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [ImmichAlbum] = []
    @State private var isLoading = false
    @State private var error: ImmichError?
    @State private var adding: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
            .task { if albums.isEmpty { await load() } }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && albums.isEmpty {
            ProgressView().tint(.phosphorPrimary)
        } else if let error, albums.isEmpty {
            VStack(spacing: Spacing.m) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorAccent)
            }
        } else if albums.isEmpty {
            VStack(spacing: Spacing.m) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No albums yet")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
        } else {
            List(albums) { album in
                Button { Task { await add(to: album) } } label: {
                    HStack {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.phosphorAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.albumName)
                                .foregroundStyle(.phosphorPrimary)
                            Text("\(album.assetCount) \(album.assetCount == 1 ? "item" : "items")")
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                        }
                        Spacer()
                        if adding == album.id {
                            ProgressView().controlSize(.small).tint(.phosphorAccent)
                        }
                    }
                }
                .listRowBackground(Color.phosphorSurface)
                .disabled(adding != nil)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            albums = try await ImmichAPI.shared.fetchAlbums()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func add(to album: ImmichAlbum) async {
        adding = album.id
        defer { adding = nil }
        do {
            try await ImmichAPI.shared.addAssetsToAlbum(id: album.id, assetIds: assetIds)
            HapticManager.notification(.success)
            dismiss()
        } catch {
            HapticManager.notification(.error)
        }
    }
}
