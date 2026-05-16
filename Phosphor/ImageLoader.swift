import Foundation
import UIKit

/// Actor-based async image cache for Immich thumbnails and full images.
///
/// Backed by an `NSCache`, with in-flight request de-duplication so concurrent
/// requests for the same asset share a single download. The cache is cleared on
/// memory-warning notifications, and in-flight downloads are cancelled on deinit.
actor ImageLoader {

    static let shared = ImageLoader()

    private enum CacheLimit {
        static let count = 400
        static let totalCostBytes = 100 * 1024 * 1024   // 100 MB
    }

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = CacheLimit.count
        cache.totalCostLimit = CacheLimit.totalCostBytes
        return cache
    }()

    /// Approximate decoded byte size, used as the NSCache eviction cost.
    private static func cost(of image: UIImage) -> Int {
        let scale = image.scale
        let pixels = image.size.width * scale * image.size.height * scale
        return Int(pixels) * 4   // RGBA
    }

    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await ImageLoader.shared.clearCache() }
        }
    }

    deinit {
        for task in inflight.values { task.cancel() }
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func thumbnail(for assetId: String, size: ThumbnailSize) async -> UIImage? {
        guard let url = ImmichAPI.shared.fetchThumbnailURL(id: assetId, size: size)
        else { return nil }
        return await image(forKey: "thumb:\(assetId):\(size.rawValue)", url: url)
    }

    func fullImage(for assetId: String) async -> UIImage? {
        guard let url = ImmichAPI.shared.originalURL(id: assetId)
        else { return nil }
        return await image(forKey: "full:\(assetId)", url: url)
    }

    func personThumbnail(for personId: String) async -> UIImage? {
        guard let url = ImmichAPI.shared.personThumbnailURL(id: personId)
        else { return nil }
        return await image(forKey: "person:\(personId)", url: url)
    }

    /// Warm the thumbnail cache for assets likely to scroll into view. The
    /// list is clamped to `prefetchWindow` so callers can safely pass a
    /// larger candidate set (e.g. an entire section) without flooding the
    /// network. Sized at "visible + ~2 rows ahead" assuming a 4-column iPad
    /// grid; iPhone (3-col) will under-use the cap, which is the safe side.
    nonisolated func prefetch(assetIds: [String]) {
        let window = Array(assetIds.prefix(Self.prefetchWindow))
        guard !window.isEmpty else { return }
        Task {
            for id in window {
                _ = await self.thumbnail(for: id, size: .thumbnail)
            }
        }
    }

    private static let prefetchWindow = 24

    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Core fetch with de-duplication

    private func image(forKey key: String, url: URL) async -> UIImage? {
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) {
            return cached
        }
        if let existing = inflight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [url] in
            await Self.download(url: url)
        }
        inflight[key] = task

        let image = await task.value
        inflight[key] = nil
        if let image {
            cache.setObject(image, forKey: nsKey, cost: Self.cost(of: image))
        }
        return image
    }

    private static func download(url: URL) async -> UIImage? {
        guard let request = try? ImmichAPI.shared.authorizedImageRequest(for: url) else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
