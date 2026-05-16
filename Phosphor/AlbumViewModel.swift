import Foundation

@MainActor
final class AlbumViewModel: ObservableObject {

    @Published private(set) var albums: [ImmichAlbum] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?

    func loadAlbums() async {
        isLoading = true
        defer { isLoading = false }
        do {
            albums = try await ImmichAPI.shared.fetchAlbums()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    @discardableResult
    func createAlbum(name: String) async throws -> ImmichAlbum {
        let album = try await ImmichAPI.shared.createAlbum(name: name)
        albums.insert(album, at: 0)
        return album
    }

    func deleteAlbum(_ album: ImmichAlbum) async throws {
        try await ImmichAPI.shared.deleteAlbum(id: album.id)
        albums.removeAll { $0.id == album.id }
    }

    func renameAlbum(_ album: ImmichAlbum, newName: String) async throws {
        let updated = try await ImmichAPI.shared.renameAlbum(id: album.id, newName: newName)
        if let i = albums.firstIndex(where: { $0.id == album.id }) {
            albums[i] = updated
        }
    }

    func addAssets(_ assetIds: [String], to album: ImmichAlbum) async throws {
        try await ImmichAPI.shared.addAssetsToAlbum(id: album.id, assetIds: assetIds)
        // Optimistic count bump in the visible list.
        if let i = albums.firstIndex(where: { $0.id == album.id }) {
            albums[i].assetCount += assetIds.count
        }
    }

    func removeAssets(_ assetIds: [String], from album: ImmichAlbum) async throws {
        try await ImmichAPI.shared.removeAssetsFromAlbum(id: album.id, assetIds: assetIds)
        if let i = albums.firstIndex(where: { $0.id == album.id }) {
            albums[i].assetCount = max(0, albums[i].assetCount - assetIds.count)
        }
    }
}
