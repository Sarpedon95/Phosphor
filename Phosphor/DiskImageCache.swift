import Foundation
import UIKit

/// File-backed cache for thumbnails. Keyed by `{assetId}:{size}`; values are
/// JPEG-encoded bytes on disk under `Caches/PhosphorThumbs`. Capped at 500MB
/// with LRU-by-creation-date eviction triggered after each write.
actor DiskImageCache {

    static let shared = DiskImageCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private static let maxBytes: Int64 = 500 * 1024 * 1024
    private var evictionTask: Task<Void, Never>?

    init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PhosphorThumbs", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func image(forAssetId assetId: String, size: ThumbnailSize) -> UIImage? {
        let url = fileURL(forAssetId: assetId, size: size)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else { return nil }
        // Touch the modification date so eviction treats this as recently used.
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return image
    }

    func store(_ image: UIImage, forAssetId assetId: String, size: ThumbnailSize) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let url = fileURL(forAssetId: assetId, size: size)
        try? data.write(to: url, options: .atomic)
        scheduleEviction()
    }

    func clear() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Internals

    private func fileURL(forAssetId assetId: String, size: ThumbnailSize) -> URL {
        let safe = assetId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).\(size.rawValue).jpg")
    }

    private func scheduleEviction() {
        // Coalesce: if an eviction pass is already queued, don't queue another.
        guard evictionTask == nil else { return }
        evictionTask = Task.detached(priority: .background) { [weak self] in
            await self?.evictIfNeeded()
            await self?.clearEvictionTask()
        }
    }

    private func clearEvictionTask() {
        evictionTask = nil
    }

    private func evictIfNeeded() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries: [(url: URL, size: Int64, date: Date)] = contents.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            return (url, size, date)
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > Self.maxBytes else { return }

        // Oldest first.
        let ordered = entries.sorted { $0.date < $1.date }
        for entry in ordered {
            if total <= Self.maxBytes { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
