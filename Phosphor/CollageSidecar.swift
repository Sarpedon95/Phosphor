import Foundation
import CoreGraphics
import UIKit

// MARK: - Sidecar model

struct CollageSidecar: Codable, Hashable {
    let collageId: UUID
    let createdAt: Date
    let canvasSize: CGSize
    let cells: [SidecarCell]
}

struct SidecarCell: Codable, Hashable {
    let assetId: String
    let canvasFrame: CGRect      // pixel coords in exported image
    let salientRegion: CGRect    // normalized 0–1 in source image
    let cropRect: CGRect         // normalized 0–1 in source image
    let originalSize: CGSize     // source image pixel size
}

// MARK: - Persistence

/// File-based sidecar store. JSON in the app's Documents directory keyed by
/// collage UUID. Persists across launches and is included in iCloud Documents
/// backup if the user has that turned on.
enum CollageSidecarStore {
    static let fileExtension = "phosphor-sidecar"

    private static var directory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("CollageSidecars", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func url(for collageId: UUID) -> URL {
        directory.appendingPathComponent("\(collageId.uuidString).\(fileExtension)")
    }

    /// Persist. Returns the on-disk URL on success.
    @discardableResult
    static func save(_ sidecar: CollageSidecar) -> URL? {
        let url = url(for: sidecar.collageId)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sidecar)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    static func load(collageId: UUID) -> CollageSidecar? {
        let url = url(for: collageId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CollageSidecar.self, from: data)
    }

    /// Best-effort: which sidecar (if any) describes this Immich asset id?
    /// Used by `PhotoDetailView` to detect collage assets and offer deep zoom.
    static func sidecar(for assetId: String) -> CollageSidecar? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in urls where url.pathExtension == fileExtension {
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? decoder.decode(CollageSidecar.self, from: data)
            else { continue }
            // The collage is exported as a single Immich asset; if any cell
            // points to this asset id, ignore (that's the cell, not the
            // collage itself). The collageId UUID matches the local sidecar
            // file name; lookup by Immich asset id requires the renderer to
            // have stamped the asset id into the sidecar at export time —
            // see `markUploaded`. For now we expose the listing API and let
            // the caller bind by exported-asset-id.
            _ = sidecar
        }
        return nil
    }

    static func allSidecars() -> [CollageSidecar] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url -> CollageSidecar? in
            guard url.pathExtension == fileExtension,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? decoder.decode(CollageSidecar.self, from: data)
        }
    }

    // MARK: - Mapping local collageId → uploaded Immich asset

    /// Records that this collage was uploaded to Immich as `assetId`. The
    /// mapping is stored in App Group UserDefaults so the deep-zoom lookup in
    /// PhotoDetailView is a single dictionary read.
    static func recordUploadedAsset(_ assetId: String, for collageId: UUID) {
        var map = uploadedAssetMap()
        map[assetId] = collageId.uuidString
        UserDefaults.phosphor.set(map, forKey: mapKey)
    }

    static func collageId(forUploadedAsset assetId: String) -> UUID? {
        let map = uploadedAssetMap()
        guard let raw = map[assetId] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Sidecar for the Immich asset id of an uploaded collage. Returns nil
    /// when the asset isn't a collage.
    static func sidecarForUploadedAsset(_ assetId: String) -> CollageSidecar? {
        guard let id = collageId(forUploadedAsset: assetId) else { return nil }
        return load(collageId: id)
    }

    private static let mapKey = "collage_uploaded_asset_map"
    private static func uploadedAssetMap() -> [String: String] {
        UserDefaults.phosphor.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }
}

// MARK: - Deep zoom support

/// Helpers used by `PhotoDetailView` when the user zooms into a collage past
/// the normal-zoom threshold. Determines which cell the user is looking at
/// and returns its source asset id for full-resolution swap-in.
enum CollageDeepZoom {
    /// Resolve a touch point in collage-image coordinates to the source asset
    /// id of the cell under that point, plus the cell's source crop rect.
    /// Returns nil if no cell contains the point (e.g. the user is on a gap).
    static func resolve(
        sidecar: CollageSidecar,
        pointInImage: CGPoint
    ) -> (assetId: String, cropRect: CGRect)? {
        for cell in sidecar.cells where cell.canvasFrame.contains(pointInImage) {
            return (cell.assetId, cell.cropRect)
        }
        return nil
    }
}
