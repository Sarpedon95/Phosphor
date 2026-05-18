import Foundation

// MARK: - Thumbnail sizing

/// Size variants supported by `GET /assets/{id}/thumbnail`.
enum ThumbnailSize: String {
    /// Small square-ish thumbnail for grids.
    case thumbnail
    /// Larger downscaled JPEG suitable for full-screen display.
    case preview
}

// MARK: - Errors

enum ImmichError: Error, LocalizedError {
    case notConfigured
    case unauthorized
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server URL or API key is not configured."
        case .unauthorized:
            return "The API key was rejected by the server."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode the server response: \(error.localizedDescription)"
        case .serverError(let code):
            return "The server returned an error (HTTP \(code))."
        }
    }
}

// MARK: - Client

/// REST client for the Immich API.
///
/// Credentials live in `UserDefaults` (written by `ConnectionManager`) and are
/// read fresh on every request, so reconfiguring the connection takes effect
/// immediately without re-injecting anything into this singleton.
final class ImmichAPI {

    static let shared = ImmichAPI()

    private init() {}

    /// Single source of truth for Keychain credential keys.
    enum KeychainKey {
        static let baseURL = "immich_base_url"
        static let apiKey = "immich_api_key"
        static let accessToken = "immich_access_token"
    }

    private let session: URLSession = .shared

    // MARK: Credentials (read fresh every call)

    private var baseURL: URL? {
        guard let raw = KeychainManager.get(forKey: KeychainKey.baseURL),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    private var apiKey: String? {
        guard let key = KeychainManager.get(forKey: KeychainKey.apiKey),
              !key.isEmpty
        else { return nil }
        return key
    }

    private var accessToken: String? {
        KeychainManager.get(forKey: KeychainKey.accessToken)
    }

    var isConfigured: Bool { baseURL != nil && (accessToken != nil || apiKey != nil) }

    // MARK: Decoding

    /// Decoder that tolerates Immich's mixed ISO8601 output: fractional-seconds
    /// first (`2024-01-02T03:04:05.123Z`), then a plain internet date-time.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: string) { return date }
            if let date = iso8601Standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO8601 date: \(string)"
            )
        }
        return decoder
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Core request

    private func makeURL(path: String, query: [URLQueryItem]?) throws -> URL {
        guard let base = baseURL else { throw ImmichError.notConfigured }
        guard var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw ImmichError.notConfigured }
        if let query, !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ImmichError.notConfigured }
        return url
    }

    private func addAuthHeader(to request: inout URLRequest) throws {
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            throw ImmichError.notConfigured
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem]?,
        body: Data?
    ) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        try addAuthHeader(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ImmichError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ImmichError.serverError(-1)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            Task { @MainActor in AuthState.shared.flagUnauthorized() }
            throw ImmichError.unauthorized
        default:
            throw ImmichError.serverError(http.statusCode)
        }
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem]? = nil,
        body: Data? = nil
    ) async throws -> T {
        let request = try makeRequest(path: path, method: method, query: query, body: body)
        let data = try await send(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ImmichError.decodingError(error)
        }
    }

    private func requestVoid(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem]? = nil,
        body: Data? = nil
    ) async throws {
        let request = try makeRequest(path: path, method: method, query: query, body: body)
        _ = try await send(request)
    }

    // MARK: Image request building (used by ImageLoader)
    //
    // These helpers return `nil` when the connection is unconfigured so callers
    // can fail soft (skip the request, render a placeholder, hide a ShareLink).

    /// `{base}/assets/{id}/thumbnail?size=…`.
    func fetchThumbnailURL(id: String, size: ThumbnailSize) -> URL? {
        try? makeURL(
            path: "assets/\(id)/thumbnail",
            query: [URLQueryItem(name: "size", value: size.rawValue)]
        )
    }

    /// `{base}/assets/{id}/original` — the full-resolution source file.
    func originalURL(id: String) -> URL? {
        try? makeURL(path: "assets/\(id)/original", query: nil)
    }

    /// `{base}/people/{id}/thumbnail` — a recognized person's face crop.
    func personThumbnailURL(id: String) -> URL? {
        try? makeURL(path: "people/\(id)/thumbnail", query: nil)
    }

    /// Builds an authenticated GET request for a media URL produced above.
    func authorizedImageRequest(for url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        try addAuthHeader(to: &request)
        return request
    }

    /// Raw bytes of an asset's original file (`GET /assets/{id}/original`).
    /// Returns `Data` — callers decode/resize as needed.
    func downloadOriginal(assetId: String) async throws -> Data {
        guard let url = originalURL(id: assetId) else { throw ImmichError.notConfigured }
        let request = try authorizedImageRequest(for: url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImmichError.serverError(-1)
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:
            Task { @MainActor in AuthState.shared.flagUnauthorized() }
            throw ImmichError.unauthorized
        default: throw ImmichError.serverError(http.statusCode)
        }
    }

    /// `{base}/assets/{id}/video/playback`.
    ///
    /// Auth is added by the caller via `AVURLAsset` headers (see
    /// `makeAuthenticatedPlayerItem`) rather than a query parameter, keeping
    /// the API key out of server access logs.
    func videoPlaybackURL(for assetId: String) -> URL? {
        try? makeURL(path: "assets/\(assetId)/video/playback", query: nil)
    }

    // MARK: - Endpoints

    func fetchTimeline(page: Int, pageSize: Int) async throws -> [ImmichAsset] {
        try await request(
            "assets",
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(pageSize))
            ]
        )
    }

    func fetchAsset(id: String) async throws -> ImmichAsset {
        try await request("assets/\(id)")
    }

    func fetchAlbums() async throws -> [ImmichAlbum] {
        try await request("albums")
    }

    func fetchAlbum(id: String) async throws -> ImmichAlbum {
        try await request("albums/\(id)")
    }

    func createAlbum(name: String) async throws -> ImmichAlbum {
        let body = try JSONEncoder().encode(CreateAlbumRequest(albumName: name))
        return try await request("albums", method: "POST", body: body)
    }

    func deleteAlbum(id: String) async throws {
        try await requestVoid("albums/\(id)", method: "DELETE")
    }

    func renameAlbum(id: String, newName: String) async throws -> ImmichAlbum {
        let body = try JSONEncoder().encode(RenameAlbumRequest(albumName: newName))
        return try await request("albums/\(id)", method: "PATCH", body: body)
    }

    func addAssetsToAlbum(id: String, assetIds: [String]) async throws {
        let body = try JSONEncoder().encode(AlbumAssetsRequest(ids: assetIds))
        try await requestVoid("albums/\(id)/assets", method: "PUT", body: body)
    }

    func removeAssetsFromAlbum(id: String, assetIds: [String]) async throws {
        let body = try JSONEncoder().encode(AlbumAssetsRequest(ids: assetIds))
        try await requestVoid("albums/\(id)/assets", method: "DELETE", body: body)
    }

    func searchMetadata(query: String, page: Int) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(SearchRequest(query: query, page: page))
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    func searchSmart(query: String, page: Int) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(SearchRequest(query: query, page: page))
        let response: SearchResponse = try await request(
            "search/smart", method: "POST", body: body
        )
        return response.assets.items
    }

    // MARK: - Filtered search

    /// All-filters search used by SearchView and SmartAlbums. Any nil field is
    /// omitted from the JSON body so older Immich versions ignore unknown keys.
    func searchFiltered(
        query: String? = nil,
        city: String? = nil,
        make: String? = nil,
        model: String? = nil,
        takenAfter: Date? = nil,
        takenBefore: Date? = nil,
        isFavorite: Bool? = nil,
        isArchived: Bool? = nil,
        isVideo: Bool? = nil,
        albumId: String? = nil,
        page: Int = 1,
        size: Int = 100
    ) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(
            FilteredSearchRequest(
                query: query,
                city: city,
                make: make,
                model: model,
                takenAfter: takenAfter,
                takenBefore: takenBefore,
                isFavorite: isFavorite,
                isArchived: isArchived,
                type: isVideo == true ? "VIDEO" : (isVideo == false ? "IMAGE" : nil),
                albumIds: albumId.map { [$0] },
                page: page,
                size: size
            )
        )
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    /// On-this-day query that fans out one /search/metadata request per year
    /// in the user's library range. Up to 10 requests run concurrently via
    /// TaskGroup. Results are merged, sorted newest-first, and capped at 100.
    func fetchOnThisDay(
        month: Int,
        day: Int,
        earliestYear: Int = Calendar.current.component(.year, from: Date()) - 10
    ) async throws -> [ImmichAsset] {
        let currentYear = Calendar.current.component(.year, from: Date())
        // Skip the current year — "on this day" looks at prior years only.
        guard earliestYear < currentYear else { return [] }
        let years = Array(earliestYear...(currentYear - 1)).reversed()

        let calendar = Calendar.current
        let chunkSize = 10
        var collected: [ImmichAsset] = []

        for chunk in stride(from: 0, to: years.count, by: chunkSize) {
            let slice = Array(years)[chunk..<min(chunk + chunkSize, years.count)]
            let results = try await withThrowingTaskGroup(of: [ImmichAsset].self) { group in
                for year in slice {
                    guard let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                          let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                    else { continue }
                    group.addTask {
                        try await self.searchFiltered(
                            takenAfter: dayStart,
                            takenBefore: dayEnd,
                            page: 1,
                            size: 50
                        )
                    }
                }
                var combined: [ImmichAsset] = []
                for try await batch in group {
                    combined.append(contentsOf: batch)
                }
                return combined
            }
            collected.append(contentsOf: results)
            if collected.count >= 100 { break }
        }

        return Array(
            collected
                .sorted { $0.localDateTime > $1.localDateTime }
                .prefix(100)
        )
    }

    // MARK: - Album patch

    func updateAlbum(
        id: String,
        thumbnailAssetId: String? = nil,
        description: String? = nil
    ) async throws -> ImmichAlbum {
        let body = try JSONEncoder().encode(
            UpdateAlbumRequest(
                albumThumbnailAssetId: thumbnailAssetId,
                description: description
            )
        )
        return try await request("albums/\(id)", method: "PATCH", body: body)
    }

    func fetchFavorites(page: Int) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(FavoritesSearchRequest(isFavorite: true, page: page))
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    func fetchPersonAssets(personId: String) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(
            PersonSearchRequest(personIds: [personId], page: 1)
        )
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    func fetchExplore() async throws -> [ExploreItem] {
        let groups: [ExploreGroupResponse] = try await request("search/explore")
        return groups.flatMap { group in
            group.items.map { ExploreItem(label: $0.value, asset: $0.data) }
        }
    }

    func toggleFavorite(asset: ImmichAsset) async throws -> ImmichAsset {
        let body = try JSONEncoder().encode(
            UpdateAssetRequest(isFavorite: !asset.isFavorite, isArchived: nil)
        )
        return try await request("assets/\(asset.id)", method: "PUT", body: body)
    }

    func toggleArchive(asset: ImmichAsset) async throws -> ImmichAsset {
        let body = try JSONEncoder().encode(
            UpdateAssetRequest(isFavorite: nil, isArchived: !asset.isArchived)
        )
        return try await request("assets/\(asset.id)", method: "PUT", body: body)
    }

    /// Sets the 0–5 star rating. `rating: 0` clears it (sent as `0`, not
    /// `null`) — a non-optional field guarantees JSONEncoder emits the value.
    @discardableResult
    func setRating(assetId: String, rating: Int) async throws -> ImmichAsset {
        let clamped = max(0, min(5, rating))
        let body = try JSONEncoder().encode(RatingRequest(rating: clamped))
        return try await request("assets/\(assetId)", method: "PUT", body: body)
    }

    func trashAssets(ids: [String]) async throws {
        let body = try JSONEncoder().encode(BulkDeleteRequest(ids: ids, force: false))
        try await requestVoid("assets", method: "DELETE", body: body)
    }

    /// Bulk favorite / archive toggle via `PUT /assets`.
    func bulkUpdate(ids: [String], isFavorite: Bool? = nil, isArchived: Bool? = nil) async throws {
        let body = try JSONEncoder().encode(
            BulkUpdateRequest(ids: ids, isFavorite: isFavorite, isArchived: isArchived)
        )
        try await requestVoid("assets", method: "PUT", body: body)
    }

    /// Permanently delete (skip trash).
    func deleteAssetsPermanently(ids: [String]) async throws {
        let body = try JSONEncoder().encode(BulkDeleteRequest(ids: ids, force: true))
        try await requestVoid("assets", method: "DELETE", body: body)
    }

    func restoreAssets(ids: [String]) async throws {
        let body = try JSONEncoder().encode(BulkIDsRequest(ids: ids))
        try await requestVoid("trash/restore/assets", method: "POST", body: body)
    }

    func emptyTrash() async throws {
        try await requestVoid("trash/empty", method: "POST")
    }

    func fetchTrashed(page: Int) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(TrashedSearchRequest(isTrashed: true, page: page))
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    func fetchArchived(page: Int) async throws -> [ImmichAsset] {
        let body = try JSONEncoder().encode(ArchivedSearchRequest(isArchived: true, page: page))
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
    }

    // MARK: - Stacks

    func fetchStack(stackId: String) async throws -> [ImmichAsset] {
        let response: StackResponse = try await request("stacks/\(stackId)")
        return response.assets
    }

    func createStack(assetIds: [String]) async throws {
        let body = try JSONEncoder().encode(CreateStackRequest(assetIds: assetIds))
        try await requestVoid("stacks", method: "POST", body: body)
    }

    // MARK: - Map

    func fetchMapMarkers() async throws -> [MapMarker] {
        try await request("map/markers")
    }

    // MARK: - Shared Links

    func fetchSharedLinks() async throws -> [SharedLink] {
        try await request("shared-links")
    }

    func createSharedLink(
        type: SharedLinkType,
        albumId: String? = nil,
        assetIds: [String] = [],
        description: String? = nil,
        password: String? = nil,
        expiresAt: Date? = nil,
        allowDownload: Bool = true,
        showMetadata: Bool = true
    ) async throws -> SharedLink {
        let body = try JSONEncoder().encode(
            CreateSharedLinkRequest(
                type: type,
                albumId: albumId,
                assetIds: assetIds,
                description: description,
                password: password,
                expiresAt: expiresAt,
                allowDownload: allowDownload,
                showMetadata: showMetadata
            )
        )
        return try await request("shared-links", method: "POST", body: body)
    }

    func deleteSharedLink(id: String) async throws {
        try await requestVoid("shared-links/\(id)", method: "DELETE")
    }

    // MARK: - Duplicates

    func fetchDuplicates() async throws -> [DuplicateGroup] {
        let groups: [DuplicateGroupResponse] = try await request("duplicates")
        return groups.map { DuplicateGroup(id: $0.duplicateId, assets: $0.assets) }
    }

    // MARK: - Backup upload

    /// Asks the server which of the given local assets it already has, keyed by
    /// the caller's `deviceAssetId`. Used both to skip re-uploads during backup
    /// and to confirm a local copy is safe to delete in "Free Up Space".
    ///
    /// `checksum` must be the base64-encoded SHA1 digest of the original file
    /// (Immich's `/assets/bulk-upload-check` contract). Returns the set of
    /// `deviceAssetId`s the server reports as already present.
    func existingAssetIDs(_ items: [(deviceAssetId: String, checksum: String)]) async throws -> Set<String> {
        guard !items.isEmpty else { return [] }
        let payload = BulkUploadCheckRequest(
            assets: items.map { .init(id: $0.deviceAssetId, checksum: $0.checksum) }
        )
        let body = try JSONEncoder().encode(payload)
        let response: BulkUploadCheckResponse = try await request(
            "assets/bulk-upload-check", method: "POST", body: body
        )
        return Set(
            response.results
                .filter { $0.action == "reject" && $0.reason == "duplicate" }
                .map(\.id)
        )
    }

    /// Upload a local asset (PHAsset data) via multipart/form-data. The server
    /// returns the created asset. Throws `ImmichError` on failure.
    func uploadAsset(
        data: Data,
        deviceAssetId: String,
        deviceId: String,
        fileName: String,
        fileCreatedAt: Date,
        fileModifiedAt: Date,
        isFavorite: Bool = false
    ) async throws -> ImmichAsset {
        guard let base = baseURL else { throw ImmichError.notConfigured }
        let url = base.appendingPathComponent("assets")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        try addAuthHeader(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }
        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField(name: "deviceAssetId", value: deviceAssetId)
        appendField(name: "deviceId", value: deviceId)
        appendField(name: "fileCreatedAt", value: isoFormatter.string(from: fileCreatedAt))
        appendField(name: "fileModifiedAt", value: isoFormatter.string(from: fileModifiedAt))
        appendField(name: "isFavorite", value: isFavorite ? "true" : "false")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let responseData = try await send(request: request, body: body)
        do {
            return try Self.decoder.decode(ImmichAsset.self, from: responseData)
        } catch {
            throw ImmichError.decodingError(error)
        }
    }

    private func send(request: URLRequest, body: Data) async throws -> Data {
        var req = request
        req.httpBody = body
        return try await send(req)
    }

    // MARK: - Users / sharing

    func fetchUsers(query: String) async throws -> [ImmichUser] {
        var queryItems: [URLQueryItem] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmed))
        }
        let users: [ImmichUser] = try await request("users", query: queryItems.isEmpty ? nil : queryItems)
        return users
    }

    func shareAlbum(id: String, userIds: [String]) async throws {
        struct Body: Encodable { let sharedUserIds: [String] }
        let body = try JSONEncoder().encode(Body(sharedUserIds: userIds))
        try await requestVoid("albums/\(id)/users", method: "PUT", body: body)
    }

    func unshareAlbum(id: String, userId: String) async throws {
        try await requestVoid("albums/\(id)/user/\(userId)", method: "DELETE")
    }

    func fetchPeople() async throws -> [Person] {
        let response: PeopleResponse = try await request("people")
        return response.people
    }

    /// Merge `sourceId` into `destinationId`. Endpoint availability varies by
    /// Immich version — `serverError(404)` indicates the server doesn't
    /// support merging.
    func mergePerson(sourceId: String, destinationId: String) async throws {
        struct Body: Encodable { let mergedIntoPersonId: String }
        let body = try JSONEncoder().encode(Body(mergedIntoPersonId: destinationId))
        try await requestVoid("people/\(sourceId)", method: "PATCH", body: body)
    }

    /// `PATCH /people/{id}` — rename or hide a recognized face.
    func updatePerson(id: String, name: String? = nil, isHidden: Bool? = nil) async throws -> Person {
        let body = try JSONEncoder().encode(
            UpdatePersonRequest(name: name, isHidden: isHidden)
        )
        return try await request("people/\(id)", method: "PATCH", body: body)
    }

    func toggleMemorySaved(id: String, saved: Bool) async throws {
        struct Body: Encodable { let isSaved: Bool }
        let body = try JSONEncoder().encode(Body(isSaved: saved))
        try await requestVoid("memories/\(id)", method: "PUT", body: body)
    }

    func deleteMemory(id: String) async throws {
        try await requestVoid("memories/\(id)", method: "DELETE")
    }

    func fetchMemories() async throws -> [ImmichMemory] {
        let memories: [MemoryResponse] = try await request("memories")
        return memories.map { dto in
            ImmichMemory(
                id: dto.id,
                title: dto.data?.year.map(String.init) ?? dto.type.capitalized,
                assets: dto.assets ?? [],
                type: dto.type,
                createdAt: dto.createdAt
            )
        }
    }

    func testConnection() async throws -> Bool {
        let ping: PingResponse = try await request("server/ping")
        return ping.res == "pong"
    }

    /// Test arbitrary credentials WITHOUT touching the stored ones. Used by
    /// AddServerView so probing a new server doesn't clobber the active
    /// session. Returns (pinged ok, version string, round-trip ms).
    static func probe(baseURL: String, apiKey: String) async throws -> (ok: Bool, version: String?, latencyMs: Int) {
        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard !trimmedURL.isEmpty, !apiKey.isEmpty,
              let base = URL(string: trimmedURL)
        else { throw ImmichError.notConfigured }

        func makeRequest(path: String) -> URLRequest {
            var r = URLRequest(url: base.appendingPathComponent(path))
            r.httpMethod = "GET"
            r.timeoutInterval = 30
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            return r
        }

        let start = Date()
        do {
            let (pingData, pingResponse) = try await URLSession.shared.data(for: makeRequest(path: "server/ping"))
            guard let http = pingResponse as? HTTPURLResponse else {
                throw ImmichError.serverError(-1)
            }
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw ImmichError.unauthorized
            default: throw ImmichError.serverError(http.statusCode)
            }
            let pong = try JSONDecoder().decode(PingResponse.self, from: pingData)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1_000)
            guard pong.res == "pong" else { return (false, nil, latencyMs) }

            // Version is supplementary — failure here doesn't invalidate the probe.
            var version: String?
            if let (vData, vResp) = try? await URLSession.shared.data(for: makeRequest(path: "server/version")),
               let http = vResp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode(ServerVersion.self, from: vData) {
                version = "\(decoded.major).\(decoded.minor).\(decoded.patch)"
            }
            return (true, version, latencyMs)
        } catch let caught as ImmichError {
            throw caught
        } catch {
            throw ImmichError.networkError(error)
        }
    }

    /// Login with email + password. Returns the decoded auth response on
    /// success; throws `ImmichError.unauthorized` on 401.
    static func login(baseURL: String, email: String, password: String) async throws -> AuthResponse {
        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard !trimmedURL.isEmpty, let base = URL(string: trimmedURL)
        else { throw ImmichError.notConfigured }

        struct LoginRequest: Encodable {
            let email: String
            let password: String
        }
        var req = URLRequest(url: base.appendingPathComponent("auth/login"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(LoginRequest(email: email, password: password))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ImmichError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ImmichError.serverError(-1) }
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(AuthResponse.self, from: data) }
            catch { throw ImmichError.decodingError(error) }
        case 401, 403: throw ImmichError.unauthorized
        default: throw ImmichError.serverError(http.statusCode)
        }
    }

    /// Validate a bearer token. Returns `true` if the server responds with 200.
    static func validateToken(baseURL: String, token: String) async throws -> Bool {
        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard !trimmedURL.isEmpty, let base = URL(string: trimmedURL)
        else { throw ImmichError.notConfigured }

        var req = URLRequest(url: base.appendingPathComponent("auth/validateToken"))
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response): (Data, URLResponse)
        do { (_, response) = try await URLSession.shared.data(for: req) }
        catch { throw ImmichError.networkError(error) }
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Probe with email + password instead of an API key. Authenticates via
    /// the login endpoint and fetches the server version for supplementary info.
    static func probe(baseURL: String, email: String, password: String) async throws -> (ok: Bool, version: String?, latencyMs: Int) {
        let start = Date()
        let auth = try await login(baseURL: baseURL, email: email, password: password)
        let latencyMs = Int(Date().timeIntervalSince(start) * 1_000)

        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard let base = URL(string: trimmedURL) else { return (true, nil, latencyMs) }

        var vReq = URLRequest(url: base.appendingPathComponent("server/version"))
        vReq.httpMethod = "GET"
        vReq.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        vReq.setValue("application/json", forHTTPHeaderField: "Accept")

        var version: String?
        if let (vData, vResp) = try? await URLSession.shared.data(for: vReq),
           let http = vResp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(ServerVersion.self, from: vData) {
            version = "\(decoded.major).\(decoded.minor).\(decoded.patch)"
        }
        return (true, version, latencyMs)
    }

    func fetchServerVersion() async throws -> String {
        let v: ServerVersion = try await request("server/version")
        return "\(v.major).\(v.minor).\(v.patch)"
    }

    /// Composes `/server/statistics` with album + people counts into a single
    /// `ServerStats`. The three sub-requests run concurrently via `async let`.
    func fetchServerStatistics() async throws -> ServerStats {
        async let statsTask: ServerStatisticsResponse = request("server/statistics")
        async let albumsTask: [ImmichAlbum] = request("albums")
        async let peopleTask: PeopleResponse = request("people")

        let (stats, albums, people) = try await (statsTask, albumsTask, peopleTask)
        return ServerStats(
            totalAssets: stats.photos + stats.videos,
            totalVideos: stats.videos,
            totalPhotos: stats.photos,
            storageUsed: stats.usage,
            totalAlbums: albums.count,
            totalPeople: people.people.count
        )
    }
}

// MARK: - Request bodies

private struct SearchRequest: Encodable {
    let query: String
    let page: Int
}

private struct UpdateAssetRequest: Encodable {
    let isFavorite: Bool?
    let isArchived: Bool?
}

private struct RatingRequest: Encodable {
    let rating: Int
}

private struct BulkDeleteRequest: Encodable {
    let ids: [String]
    let force: Bool
}

private struct CreateAlbumRequest: Encodable {
    let albumName: String
}

private struct RenameAlbumRequest: Encodable {
    let albumName: String
}

private struct AlbumAssetsRequest: Encodable {
    let ids: [String]
}

private struct FavoritesSearchRequest: Encodable {
    let isFavorite: Bool
    let page: Int
}

private struct PersonSearchRequest: Encodable {
    let personIds: [String]
    let page: Int
}

private struct FilteredSearchRequest: Encodable {
    let query: String?
    let city: String?
    let make: String?
    let model: String?
    let takenAfter: Date?
    let takenBefore: Date?
    let isFavorite: Bool?
    let isArchived: Bool?
    let type: String?
    let albumIds: [String]?
    let page: Int
    let size: Int
}

private struct UpdateAlbumRequest: Encodable {
    let albumThumbnailAssetId: String?
    let description: String?
}

private struct UpdatePersonRequest: Encodable {
    let name: String?
    let isHidden: Bool?
}

private struct TrashedSearchRequest: Encodable {
    let isTrashed: Bool
    let page: Int
}

private struct ArchivedSearchRequest: Encodable {
    let isArchived: Bool
    let page: Int
}

private struct BulkIDsRequest: Encodable {
    let ids: [String]
}

private struct BulkUpdateRequest: Encodable {
    let ids: [String]
    let isFavorite: Bool?
    let isArchived: Bool?
}

private struct BulkUploadCheckRequest: Encodable {
    struct Item: Encodable {
        let id: String
        let checksum: String
    }
    let assets: [Item]
}

private struct CreateStackRequest: Encodable {
    let assetIds: [String]
}

private struct CreateSharedLinkRequest: Encodable {
    let type: SharedLinkType
    let albumId: String?
    let assetIds: [String]
    let description: String?
    let password: String?
    let expiresAt: Date?
    let allowDownload: Bool
    let showMetadata: Bool
}

// MARK: - Public response types

struct AuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let userId: String
    let userEmail: String
}

// MARK: - Response DTOs
//
// Immich wraps several responses in pagination/envelope objects that differ
// from the flat domain models in Models.swift. These private DTOs decode the
// wire shape and are mapped onto the Stage-1 models above.

private struct SearchResponse: Decodable {
    struct AssetsPage: Decodable {
        let items: [ImmichAsset]
    }
    let assets: AssetsPage
}

private struct PeopleResponse: Decodable {
    let people: [Person]
}

private struct MemoryResponse: Decodable {
    struct MemoryData: Decodable {
        let year: Int?
    }
    let id: String
    let type: String
    let createdAt: Date
    let data: MemoryData?
    let assets: [ImmichAsset]?
}

/// `GET /search/explore` → `[{ fieldName, items: [{ value, data: Asset }] }]`.
private struct ExploreGroupResponse: Decodable {
    struct Item: Decodable {
        let value: String
        let data: ImmichAsset
    }
    let fieldName: String
    let items: [Item]
}

private struct PingResponse: Decodable {
    let res: String
}

private struct ServerVersion: Decodable {
    let major: Int
    let minor: Int
    let patch: Int
}

/// `GET /server/statistics` → `{ photos, videos, usage, usageByUser: [...] }`.
private struct ServerStatisticsResponse: Decodable {
    let photos: Int
    let videos: Int
    let usage: Int64
}

private struct StackResponse: Decodable {
    let id: String
    let assets: [ImmichAsset]
}

private struct DuplicateGroupResponse: Decodable {
    let duplicateId: String
    let assets: [ImmichAsset]
}

private struct BulkUploadCheckResponse: Decodable {
    struct Result: Decodable {
        let id: String
        let action: String
        let reason: String?
    }
    let results: [Result]
}
