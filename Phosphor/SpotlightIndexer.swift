import CoreSpotlight
import UniformTypeIdentifiers
import UIKit

/// Indexes recent assets into CoreSpotlight so a system search can deep-link
/// straight into `PhotoDetailView`.
enum SpotlightIndexer {

    static let domain = "com.sarpedon.phosphor.assets"

    /// Index up to 500 recent assets. Thumbnails are fetched best-effort;
    /// missing thumbnails still index the text metadata.
    static func index(_ assets: [ImmichAsset]) async {
        let slice = Array(assets.prefix(500))
        guard !slice.isEmpty else { return }

        var items: [CSSearchableItem] = []
        for asset in slice {
            let attributes = CSSearchableItemAttributeSet(contentType: .image)
            attributes.title = asset.originalFileName
            let place = [asset.exifInfo?.city, asset.exifInfo?.country]
                .compactMap { $0 }
                .joined(separator: ", ")
            let date = asset.localDateTime.formatted(date: .abbreviated, time: .omitted)
            attributes.contentDescription = place.isEmpty ? date : "\(place) · \(date)"

            if let image = await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail) {
                attributes.thumbnailData = image.jpegData(compressionQuality: 0.7)
            }

            let item = CSSearchableItem(
                uniqueIdentifier: asset.id,
                domainIdentifier: domain,
                attributeSet: attributes
            )
            items.append(item)
        }

        do {
            try await CSSearchableIndex.default().indexSearchableItems(items)
        } catch {
            // Spotlight indexing is best-effort; a failure is non-fatal.
        }
    }

    /// Remove assets from the Spotlight index when they leave the library
    /// (trashed / permanently deleted) so search can't deep-link to a 404.
    static func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: ids)
        } catch {
            // Best-effort; a stale entry is non-fatal.
        }
    }

    /// Resolve a Spotlight activity into a deep link the router understands.
    static func assetID(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[CSSearchableItemActivityIdentifier] as? String
    }
}
