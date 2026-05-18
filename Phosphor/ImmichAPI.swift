import Foundation
import Network

/// One-shot continuation guard for the TCP reachability probe.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    func tryConsume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

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

// MARK: - Self-signed TLS handling

/// Per-server "allow self-signed certificate" Keychain key. The host is
/// sanitized so it's a valid account string.
func immichSelfSignedKey(forHost host: String) -> String {
    let safe = host.lowercased().replacingOccurrences(
        of: "[^a-z0-9.-]", with: "_", options: .regularExpression
    )
    return "immich_allow_self_signed_\(safe)"
}

/// URLSession delegate that optionally trusts self-signed server certs for a
/// host the user has explicitly opted into (home servers with a local CA).
final class ImmichAPIDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let allowed = KeychainManager.get(forKey: immichSelfSignedKey(forHost: host)) == "1"
        if allowed {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Client

/// REST client for the Immich API.
///
/// Credentials live in the Keychain (written by `ConnectionManager`) and are
/// read fresh on every request, so reconfiguring the connection takes effect
/// immediately without re-injecting anything into this singleton.
///
/// Remote access: enter any reachable hostname — Tailscale MagicDNS names,
/// VPN addresses, and reverse proxy domains all work as-is. There is no
/// NAT-traversal magic; a hostname that resolves and routes is sufficient.
/// For HTTPS with self-signed certs, enable "Allow self-signed certificate"
/// in connection settings.
///
/// API prefix: Immich v1.91+ serves every endpoint under `/api`. The working
/// prefix ("" for pre-v1.91, "/api" otherwise) is detected during onboarding
/// and persisted in the Keychain so all later requests target the right path.
final class ImmichAPI {

    static let shared = ImmichAPI()

    private init() {}

    /// Single source of truth for Keychain credential keys.
    enum KeychainKey {
        static let baseURL = "immich_base_url"
        static let apiKey = "immich_api_key"
        static let accessToken = "immich_access_token"
        static let apiPrefix = "immich_api_prefix"
    }

    /// Timeout for onboarding probes — short so a wrong address fails fast.
    static let probeTimeout: TimeInterval = 8

    /// Custom session (NOT `.shared`) so the self-signed-cert delegate can be
    /// installed. `.shared` cannot have a delegate assigned after init. A
    /// non-lazy `let` (vs. the lazy var originally sketched) is used because
    /// the singleton is hit from many concurrent async contexts and `lazy`
    /// initialization is not thread-safe.
    let session: URLSession = URLSession(
        configuration: .default,
        delegate: ImmichAPIDelegate(),
        delegateQueue: nil
    )

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

    /// "" (pre-v1.91) or "/api" (default). Normalized so it's empty or a
    /// single leading-slash segment with no trailing slash.
    private var apiPrefix: String {
        guard let raw = KeychainManager.get(forKey: KeychainKey.apiPrefix) else {
            return "/api"
        }
        var p = raw.trimmingCharacters(in: .whitespaces)
        while p.hasSuffix("/") { p.removeLast() }
        if p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    /// `baseURL` with the detected API prefix appended. All endpoint paths are
    /// resolved against this so callers never embed `/api` themselves.
    private var baseAPIURL: URL? {
        guard let base = baseURL else { return nil }
        guard !apiPrefix.isEmpty else { return base }
        return base.appendingPathComponent(apiPrefix.hasPrefix("/")
            ? String(apiPrefix.dropFirst()) : apiPrefix)
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
        guard let base = baseAPIURL else { throw ImmichError.notConfigured }
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

    /// Lists timeline assets via `POST /search/metadata`. Modern Immich
    /// (v1.106+) removed `GET /assets`; this is the surviving endpoint that
    /// returns a paginated, unfiltered asset list when the body is empty
    /// apart from page/size.
    func fetchTimeline(page: Int, pageSize: Int) async throws -> [ImmichAsset] {
        struct TimelineRequest: Encodable {
            let page: Int
            let size: Int
        }
        let body = try JSONEncoder().encode(
            TimelineRequest(page: page, size: pageSize)
        )
        let response: SearchResponse = try await request(
            "search/metadata", method: "POST", body: body
        )
        return response.assets.items
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
        guard let base = baseAPIURL else { throw ImmichError.notConfigured }
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

    // MARK: - Connection resolution (onboarding)

    /// A reachable Immich endpoint: the base URL (scheme + host[:port], no
    /// trailing slash) and the API prefix that responded ("" or "/api").
    struct ResolvedConnection {
        let baseURL: String
        let prefix: String
    }

    /// Strips any scheme and trailing slashes, returning bare host[:port].
    private static func bareHost(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("https://") { h.removeFirst(8) }
        else if h.hasPrefix("http://") { h.removeFirst(7) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    /// Hits `{base}{prefix}/server/ping` (no auth) with the short probe
    /// timeout, trying "/api" first then root. Returns the working prefix or
    /// nil if neither responds with a pong.
    static func detectAPIPrefix(forBase trimmedBase: String) async -> String? {
        guard let base = URL(string: trimmedBase) else { return nil }
        for prefix in ["/api", ""] {
            var url = base
            if !prefix.isEmpty { url.appendPathComponent("api") }
            url.appendPathComponent("server/ping")
            var r = URLRequest(url: url)
            r.httpMethod = "GET"
            r.timeoutInterval = probeTimeout
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await ImmichAPI.shared.session.data(for: r),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let pong = try? JSONDecoder().decode(PingResponse.self, from: data),
                  pong.res == "pong"
            else { continue }
            return prefix
        }
        return nil
    }

    /// Detects whether the bare host string contains an explicit `:port`.
    /// IPv6 literals (`[::1]:443`) aren't supported by the typing UI, so we
    /// just check for a numeric tail after the last colon.
    private static func hasExplicitPort(in hostPart: String) -> Bool {
        guard let colon = hostPart.lastIndex(of: ":") else { return false }
        let tail = hostPart[hostPart.index(after: colon)...]
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }

    /// Looks-like-LAN heuristic — IPv4, `.local`, or single-label hostname.
    /// We append Immich's default `:2283` only to addresses that look local;
    /// public domains with a reverse proxy usually answer on 443 (or 80).
    private static func looksLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") { return true }
        if h.contains("."), h.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return true
        }
        return !h.contains(".")
    }

    /// Resolves a user-typed address to a reachable base + prefix. Strategy:
    ///   • If a scheme was given, respect it.
    ///   • Otherwise try https then http.
    ///   • If no port was given AND the host looks local, also try `:2283`.
    /// Each candidate is checked against `/api` first, then root.
    /// Returns nil if nothing answered within the probe budget.
    static func resolveConnection(address raw: String) async -> ResolvedConnection? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let hostPart = bareHost(trimmed)
        let portInAddress = hasExplicitPort(in: hostPart)
        let hostOnly: String = {
            guard let colon = hostPart.lastIndex(of: ":"),
                  portInAddress
            else { return hostPart }
            return String(hostPart[..<colon])
        }()

        // Candidate bases, in order of likelihood.
        var bases: [String] = []
        if hadScheme {
            bases.append(trimmed)
        } else {
            bases.append("https://\(hostPart)")
            bases.append("http://\(hostPart)")
        }
        // Local-looking address with no port: also try Immich's default :2283.
        if !portInAddress && looksLocal(hostOnly) {
            let host2283 = "\(hostOnly):2283"
            if hadScheme {
                let scheme = trimmed.hasPrefix("https://") ? "https" : "http"
                bases.append("\(scheme)://\(host2283)")
            } else {
                bases.append("http://\(host2283)")
                bases.append("https://\(host2283)")
            }
        }
        // De-dup while preserving order.
        var seen = Set<String>()
        bases = bases.filter { seen.insert($0).inserted }

        for base in bases {
            if let prefix = await detectAPIPrefix(forBase: base) {
                return ResolvedConnection(baseURL: base, prefix: prefix)
            }
        }
        return nil
    }

    // MARK: - Structured connection test (onboarding)

    /// A single check the onboarding "Testing Connection" screen displays.
    enum ConnectionStepStatus {
        case pending
        case running
        case success(String)
        case failure(String)
    }

    /// Phases of the onboarding probe — the user sees a row per phase and a
    /// status icon for each. Same shape LyrPlay uses for its web/stream
    /// pair, generalized for Immich's single-endpoint reality.
    struct ConnectionTestStep: Identifiable {
        let id: Phase
        let label: String
        var status: ConnectionStepStatus

        enum Phase { case reach, api, version }
    }

    /// Builds the empty step list — the test screen seeds itself from this.
    static func makeConnectionTestSteps() -> [ConnectionTestStep] {
        [
            .init(id: .reach,   label: "Server reachable",      status: .pending),
            .init(id: .api,     label: "Immich API responding", status: .pending),
            .init(id: .version, label: "Server version",        status: .pending)
        ]
    }

    /// Runs the three-phase probe against a typed address. Callers should
    /// pass `update` to receive incremental status updates as each phase
    /// flips state — the test screen renders the most recent snapshot.
    /// On success returns the resolved (base, prefix) the next step uses.
    static func runConnectionTest(
        address: String,
        update: @MainActor @escaping ([ConnectionTestStep]) -> Void
    ) async -> ResolvedConnection? {
        // `steps` is mutated below; each `await MainActor.run` snapshots it
        // into an immutable `let` before crossing the actor boundary, so the
        // closure captures a Sendable copy (Swift 6 strict-concurrency).
        var steps = makeConnectionTestSteps()
        let snapshot0 = steps
        await MainActor.run { update(snapshot0) }

        // Phase 1 + 2 are folded together: resolveConnection() does a TCP
        // open + HTTP /server/ping decode. We surface them as separate UI
        // rows so the user can see whether the failure was at the network
        // layer or at the API layer.
        steps[0].status = .running
        let snapshot1 = steps
        await MainActor.run { update(snapshot1) }

        guard let resolved = await resolveConnection(address: address) else {
            // Try a raw TCP probe to distinguish "host unreachable" from
            // "host answers but isn't Immich".
            let tcpOK = await tcpReachable(address: address)
            if tcpOK {
                steps[0].status = .success("Reached")
                steps[1].status = .failure("No Immich API at that address")
            } else {
                steps[0].status = .failure("Couldn't reach that address")
                steps[1].status = .pending
            }
            steps[2].status = .pending
            let snapshotFail = steps
            await MainActor.run { update(snapshotFail) }
            return nil
        }

        steps[0].status = .success("Reached")
        steps[1].status = .success(resolved.prefix.isEmpty ? "Legacy API (no /api)" : "/api")
        steps[2].status = .running
        let snapshot2 = steps
        await MainActor.run { update(snapshot2) }

        // Phase 3: server version is supplementary — failure doesn't fail
        // the test, it just shows "unknown" in the row.
        guard let root = URL(string: resolved.baseURL) else { return resolved }
        var url = root
        if !resolved.prefix.isEmpty {
            url.appendPathComponent(resolved.prefix.hasPrefix("/")
                ? String(resolved.prefix.dropFirst()) : resolved.prefix)
        }
        url.appendPathComponent("server/version")
        var req = URLRequest(url: url)
        req.timeoutInterval = probeTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let (data, response) = try? await ImmichAPI.shared.session.data(for: req),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let v = try? JSONDecoder().decode(ServerVersion.self, from: data) {
            steps[2].status = .success("v\(v.major).\(v.minor).\(v.patch)")
        } else {
            steps[2].status = .success("unknown")
        }
        let snapshot3 = steps
        await MainActor.run { update(snapshot3) }
        return resolved
    }

    /// Raw TCP open against the host[:port] portion of a typed address.
    /// Used by the test screen to tell "wrong address" from "wrong app".
    private static func tcpReachable(address: String) async -> Bool {
        // Pull out a host and a probable port. We don't try multiple ports
        // here — this is just a "did anything at all answer" sanity check.
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme = "http"
        if s.hasPrefix("https://") { s.removeFirst(8); scheme = "https" }
        else if s.hasPrefix("http://") { s.removeFirst(7) }
        while s.hasSuffix("/") { s.removeLast() }
        var host = s
        var port: UInt16 = scheme == "https" ? 443 : 80
        if let colon = s.lastIndex(of: ":"),
           !s[s.index(after: colon)...].isEmpty,
           s[s.index(after: colon)...].allSatisfy(\.isNumber),
           let p = UInt16(s[s.index(after: colon)...]) {
            host = String(s[..<colon])
            port = p
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let once = OneShotLatch()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.tryConsume() {
                        conn.cancel()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if once.tryConsume() {
                        conn.cancel()
                        cont.resume(returning: false)
                    }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            // Hard cap so we don't hang on filtered ports.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(probeTimeout * 1_000_000_000))
                if once.tryConsume() {
                    conn.cancel()
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// POSTs `{base}{prefix}/auth/login`. Throws `.unauthorized` on 401.
    static func login(
        baseURL: String,
        prefix: String,
        email: String,
        password: String
    ) async throws -> AuthResponse {
        guard let root = URL(string: baseURL) else { throw ImmichError.notConfigured }
        var url = root
        if !prefix.isEmpty {
            url.appendPathComponent(prefix.hasPrefix("/") ? String(prefix.dropFirst()) : prefix)
        }
        url.appendPathComponent("auth/login")

        struct LoginRequest: Encodable { let email: String; let password: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(LoginRequest(email: email, password: password))

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await ImmichAPI.shared.session.data(for: req) }
        catch { throw ImmichError.networkError(error) }
        guard let http = response as? HTTPURLResponse else { throw ImmichError.serverError(-1) }
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(AuthResponse.self, from: data) }
            catch { throw ImmichError.decodingError(error) }
        case 401, 403: throw ImmichError.unauthorized
        default: throw ImmichError.serverError(http.statusCode)
        }
    }

    /// Full email/password connect: resolve a reachable base + prefix, then
    /// authenticate. Returns everything the caller must persist.
    static func connectWithPassword(
        address: String,
        email: String,
        password: String
    ) async throws -> (token: String, baseURL: String, prefix: String) {
        guard let resolved = await resolveConnection(address: address) else {
            throw ImmichError.networkError(URLError(.cannotConnectToHost))
        }
        let auth = try await login(
            baseURL: resolved.baseURL,
            prefix: resolved.prefix,
            email: email,
            password: password
        )
        return (auth.accessToken, resolved.baseURL, resolved.prefix)
    }

    /// Full API-key connect: resolve, then verify the key with an authed ping.
    static func connectWithAPIKey(
        address: String,
        apiKey: String
    ) async throws -> (baseURL: String, prefix: String) {
        guard let resolved = await resolveConnection(address: address) else {
            throw ImmichError.networkError(URLError(.cannotConnectToHost))
        }
        guard let root = URL(string: resolved.baseURL) else {
            throw ImmichError.notConfigured
        }
        var url = root
        if !resolved.prefix.isEmpty {
            url.appendPathComponent(resolved.prefix.hasPrefix("/")
                ? String(resolved.prefix.dropFirst()) : resolved.prefix)
        }
        url.appendPathComponent("server/ping")
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.timeoutInterval = probeTimeout
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response): (Data, URLResponse)
        do { (_, response) = try await ImmichAPI.shared.session.data(for: r) }
        catch { throw ImmichError.networkError(error) }
        guard let http = response as? HTTPURLResponse else { throw ImmichError.serverError(-1) }
        switch http.statusCode {
        case 200..<300: return (resolved.baseURL, resolved.prefix)
        case 401, 403: throw ImmichError.unauthorized
        default: throw ImmichError.serverError(http.statusCode)
        }
    }

    /// Test arbitrary API-key credentials WITHOUT touching stored ones. Used
    /// by AddServerView. Tries "/api" then root. Returns (ok, version, ms).
    static func probe(baseURL: String, apiKey: String) async throws -> (ok: Bool, version: String?, latencyMs: Int) {
        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard !trimmedURL.isEmpty, !apiKey.isEmpty,
              let base = URL(string: trimmedURL)
        else { throw ImmichError.notConfigured }

        func request(prefix: String, path: String) -> URLRequest {
            var url = base
            if !prefix.isEmpty { url.appendPathComponent("api") }
            url.appendPathComponent(path)
            var r = URLRequest(url: url)
            r.httpMethod = "GET"
            r.timeoutInterval = probeTimeout
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            return r
        }

        let start = Date()
        var lastError: ImmichError = .serverError(-1)
        for prefix in ["/api", ""] {
            do {
                let (pingData, pingResponse) = try await ImmichAPI.shared.session.data(
                    for: request(prefix: prefix, path: "server/ping")
                )
                guard let http = pingResponse as? HTTPURLResponse else {
                    lastError = .serverError(-1); continue
                }
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: throw ImmichError.unauthorized
                default: lastError = .serverError(http.statusCode); continue
                }
                guard let pong = try? JSONDecoder().decode(PingResponse.self, from: pingData),
                      pong.res == "pong" else { lastError = .serverError(-1); continue }
                let latencyMs = Int(Date().timeIntervalSince(start) * 1_000)

                var version: String?
                if let (vData, vResp) = try? await ImmichAPI.shared.session.data(
                    for: request(prefix: prefix, path: "server/version")
                ),
                   let http = vResp as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let decoded = try? JSONDecoder().decode(ServerVersion.self, from: vData) {
                    version = "\(decoded.major).\(decoded.minor).\(decoded.patch)"
                }
                return (true, version, latencyMs)
            } catch let caught as ImmichError {
                if case .unauthorized = caught { throw caught }
                lastError = caught
            } catch {
                lastError = .networkError(error)
            }
        }
        throw lastError
    }

    /// Validate a bearer token. Tries "/api" then root. Returns true on 200.
    static func validateToken(baseURL: String, token: String) async throws -> Bool {
        let trimmedURL: String = {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard !trimmedURL.isEmpty, let base = URL(string: trimmedURL)
        else { throw ImmichError.notConfigured }

        for prefix in ["/api", ""] {
            var url = base
            if !prefix.isEmpty { url.appendPathComponent("api") }
            url.appendPathComponent("auth/validateToken")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = probeTimeout
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (_, response) = try? await ImmichAPI.shared.session.data(for: req),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return true
            }
        }
        return false
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
