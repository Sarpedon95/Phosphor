import Foundation

// MARK: - Asset

/// Immich asset media kind. Raw values match the Immich API (`IMAGE`, `VIDEO`, ...).
enum AssetType: String, Codable, Hashable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

/// A single photo or video as returned by `GET /assets` / `GET /assets/{id}`.
///
/// Date fields are ISO8601 strings in the Immich API; the API client is expected
/// to install a JSONDecoder with a fractional-seconds ISO8601 date strategy.
struct ImmichAsset: Identifiable, Codable, Hashable {
    let id: String
    let deviceAssetId: String
    let ownerId: String
    let type: AssetType
    let originalFileName: String
    let originalPath: String
    let thumbhash: String?
    let localDateTime: Date
    let fileCreatedAt: Date
    let fileModifiedAt: Date
    var isFavorite: Bool
    var isArchived: Bool
    var isTrashed: Bool
    var exifInfo: ExifInfo?
    var people: [Person]?
    /// Present on some Immich versions (older `stackCount`); nil when the
    /// server reports stacks via a nested `stack` object instead.
    let stackCount: Int?
    /// Server-side stack identifier; nil when this asset is not part of a stack.
    let stackId: String?
    /// Companion video asset for iOS Live Photos.
    let livePhotoVideoId: String?
    /// File size in bytes when reported (some endpoints omit it).
    let fileSizeInByte: Int64?
    /// SHA1 checksum used for duplicate detection (Immich's `checksum` field).
    let checksum: String?
    /// 0–5 star rating (Immich `rating` field). Absent on older assets.
    var rating: Int?

    var isVideo: Bool { type == .video }
    var isStacked: Bool { (stackCount ?? 0) > 1 }
    var isLivePhoto: Bool { livePhotoVideoId != nil }
    /// Treats a missing rating as 0 for filtering / display.
    var ratingValue: Int { rating ?? 0 }
}

// MARK: - EXIF

/// EXIF / metadata for an asset. Every field is optional — Immich frequently
/// returns partial metadata depending on the source file.
struct ExifInfo: Codable, Hashable {
    let make: String?
    let model: String?
    let lensModel: String?
    let focalLength: Double?
    let fNumber: Double?
    let iso: Int?
    let exposureTime: String?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let description: String?
    /// Source pixel dimensions (Immich `exifImageWidth`/`exifImageHeight`).
    /// Absent on assets whose EXIF lacked them.
    let exifImageWidth: Int?
    let exifImageHeight: Int?
}

// MARK: - Album

/// An album from `GET /albums` (without assets) or `GET /albums/{id}` (with assets).
struct ImmichAlbum: Identifiable, Codable, Hashable {
    let id: String
    let albumName: String
    let description: String?
    let albumThumbnailAssetId: String?
    var assetCount: Int
    let updatedAt: Date?
    let shared: Bool?
    let sharedUsers: [SharedUser]?
    var assets: [ImmichAsset]?

    var sharedUserCount: Int { sharedUsers?.count ?? 0 }
}

/// Minimal projection of a shared-with user (Immich returns more; we use the
/// count only).
struct SharedUser: Codable, Hashable {
    let id: String
    let email: String?
}

// MARK: - People

/// A recognized person from `GET /people`.
struct Person: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let thumbnailPath: String?
    let birthDate: String?

    /// Name to show in UI — never empty.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : name
    }
}

// MARK: - Memories

/// A memory ("on this day") grouping from `GET /memories`.
struct ImmichMemory: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let assets: [ImmichAsset]
    let type: String
    let createdAt: Date
}

// MARK: - Search

/// Result wrapper for `GET /search/metadata` and `GET /search/smart`.
struct SearchResult: Codable, Hashable {
    let assets: [ImmichAsset]
}

// MARK: - Server

/// Aggregated server stats shown in the Profile screen. Composed from
/// `/server/statistics` (assets + storage) and `/albums` / `/people` counts.
struct ServerStats: Hashable {
    let totalAssets: Int
    let totalVideos: Int
    let totalPhotos: Int
    let storageUsed: Int64
    let totalAlbums: Int
    let totalPeople: Int
}

// MARK: - Map

/// Geotagged marker from `GET /map/markers`.
struct MapMarker: Identifiable, Codable, Hashable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case id, lat, lon, city, state, country
    }
}

// MARK: - Shared links

enum SharedLinkType: String, Codable, Hashable {
    case album = "ALBUM"
    case individual = "INDIVIDUAL"
}

/// A shareable public link from `GET /shared-links`.
struct SharedLink: Identifiable, Codable, Hashable {
    let id: String
    let key: String
    let type: SharedLinkType
    let description: String?
    let password: String?
    let expiresAt: Date?
    let allowDownload: Bool
    let showMetadata: Bool
    let allowUpload: Bool
    let album: ImmichAlbum?
    let assets: [ImmichAsset]?
    let createdAt: Date
}

// MARK: - Duplicates

/// A group of likely-duplicate assets from `GET /duplicates`.
struct DuplicateGroup: Identifiable, Hashable {
    let id: String
    let assets: [ImmichAsset]
}
