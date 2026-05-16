import UIKit
import Vision
import CoreImage

/// Vision-powered cropping. All requests run off the main thread (the actor
/// hop itself takes us off MainActor); a small `NSCache` short-circuits
/// repeated calls for the same `(assetId, aspect)` pair so layout switches
/// don't re-trigger Vision for already-analyzed photos.
actor IntelligentCropEngine {
    static let shared = IntelligentCropEngine()

    private let cache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 500
        return cache
    }()

    // MARK: - Public API

    /// Best crop respecting `targetAspect`, with subject (salient region)
    /// centered. Returns a rect normalized to `[0,1]` of the source image.
    func bestCrop(for image: UIImage, targetAspect: CGFloat) async -> CGRect {
        await bestCrop(for: image, targetAspect: targetAspect, withinBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Content-aware crop: first trims off near-black borders, then picks the
    /// salient region within the trimmed area. This is the primary entry
    /// point used by `CollageLayoutEngine`.
    func smartCrop(assetId: String, image: UIImage, targetAspect: CGFloat) async -> CGRect {
        let key = "\(assetId)|\(Double(targetAspect))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.cgRectValue
        }
        let bounds = await detectContentBounds(for: image)
        let crop = await bestCrop(for: image, targetAspect: targetAspect, withinBounds: bounds)
        cache.setObject(NSValue(cgRect: crop), forKey: key)
        return crop
    }

    /// Trim near-black letterboxing / scan borders. Returns a normalized
    /// `CGRect` in source-image coordinates. Defaults to full image if no
    /// borders are detected.
    func detectContentBounds(for image: UIImage) async -> CGRect {
        await Task.detached(priority: .userInitiated) {
            Self.computeContentBounds(image)
        }.value
    }

    func dropCache() {
        cache.removeAllObjects()
    }

    // MARK: - Salience pipeline

    private func bestCrop(for image: UIImage, targetAspect: CGFloat, withinBounds: CGRect) async -> CGRect {
        guard targetAspect > 0 else { return withinBounds }
        guard let cgImage = image.cgImage else { return withinBounds }

        let salient: CGRect = await Task.detached(priority: .userInitiated) {
            Self.unionOfSaliency(cgImage: cgImage) ?? .null
        }.value

        // Translate salient (in full-image normalized coords) into within-bounds
        // coords. If saliency was empty, use the bounds' center as the focal.
        let focal: CGPoint
        if salient.isNull || salient.isEmpty {
            focal = CGPoint(x: withinBounds.midX, y: withinBounds.midY)
        } else {
            let clamped = salient.intersection(withinBounds)
            focal = clamped.isNull
                ? CGPoint(x: withinBounds.midX, y: withinBounds.midY)
                : CGPoint(x: clamped.midX, y: clamped.midY)
        }
        return Self.expandToAspect(focal: focal, target: targetAspect, within: withinBounds)
    }

    /// Returns the union of attention/objectness saliency bounding boxes in
    /// **UIKit-normalized coordinates** (origin top-left). Vision uses
    /// bottom-left; we flip Y here so all downstream math is uniform.
    nonisolated private static func unionOfSaliency(cgImage: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        if let union = saliencyUnion(
            request: VNGenerateAttentionBasedSaliencyImageRequest(),
            handler: handler
        ) {
            return union
        }
        if let union = saliencyUnion(
            request: VNGenerateObjectnessBasedSaliencyImageRequest(),
            handler: handler
        ) {
            return union
        }
        return nil
    }

    nonisolated private static func saliencyUnion(
        request: VNImageBasedRequest,
        handler: VNImageRequestHandler
    ) -> CGRect? {
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let result = request.results?.first as? VNSaliencyImageObservation,
              let objects = result.salientObjects,
              !objects.isEmpty
        else { return nil }

        var union: CGRect = .null
        for obj in objects {
            union = union.union(obj.boundingBox)
        }
        guard !union.isNull, !union.isEmpty else { return nil }
        // Vision: origin bottom-left in normalized coords. Flip to UIKit.
        let flipped = CGRect(
            x: union.minX,
            y: 1.0 - union.maxY,
            width: union.width,
            height: union.height
        )
        return flipped
    }

    // MARK: - Crop math

    /// Expand a focal point into a rect with `target` aspect ratio that fits
    /// inside `within`. Always clamps to bounds (never crops outside source).
    nonisolated private static func expandToAspect(
        focal: CGPoint,
        target: CGFloat,
        within: CGRect
    ) -> CGRect {
        let boundsAspect = within.width / max(within.height, 0.0001)
        let cropW: CGFloat
        let cropH: CGFloat
        if target >= boundsAspect {
            // Limited by bounds width.
            cropW = within.width
            cropH = within.width / target
        } else {
            cropH = within.height
            cropW = within.height * target
        }
        var rect = CGRect(
            x: focal.x - cropW / 2,
            y: focal.y - cropH / 2,
            width: cropW,
            height: cropH
        )
        if rect.minX < within.minX { rect.origin.x = within.minX }
        if rect.minY < within.minY { rect.origin.y = within.minY }
        if rect.maxX > within.maxX { rect.origin.x = within.maxX - rect.width }
        if rect.maxY > within.maxY { rect.origin.y = within.maxY - rect.height }
        return rect
    }

    // MARK: - Content bounds (dark-border trim)

    nonisolated private static func computeContentBounds(_ image: UIImage) -> CGRect {
        guard let cgImage = image.cgImage else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // Downsample to 200px longest side for speed.
        let maxSide: CGFloat = 200
        let scale = maxSide / max(CGFloat(cgImage.width), CGFloat(cgImage.height), 1)
        let targetW = Int(CGFloat(cgImage.width) * scale)
        let targetH = Int(CGFloat(cgImage.height) * scale)
        guard targetW > 4, targetH > 4 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = targetW * 4
        guard let ctx = CGContext(
            data: nil,
            width: targetW, height: targetH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let buffer = ctx.data else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: targetW * targetH * 4)

        // Luminance threshold under which a row/column is considered "border".
        let threshold: Double = 0.08

        func rowLuminance(_ y: Int) -> Double {
            var sum: Double = 0
            for x in 0..<targetW {
                let idx = (y * targetW + x) * 4
                let r = Double(pixels[idx])
                let g = Double(pixels[idx + 1])
                let b = Double(pixels[idx + 2])
                sum += 0.299 * r + 0.587 * g + 0.114 * b
            }
            return sum / (Double(targetW) * 255.0)
        }
        func colLuminance(_ x: Int) -> Double {
            var sum: Double = 0
            for y in 0..<targetH {
                let idx = (y * targetW + x) * 4
                let r = Double(pixels[idx])
                let g = Double(pixels[idx + 1])
                let b = Double(pixels[idx + 2])
                sum += 0.299 * r + 0.587 * g + 0.114 * b
            }
            return sum / (Double(targetH) * 255.0)
        }

        var top = 0
        while top < targetH - 1, rowLuminance(top) < threshold { top += 1 }
        var bottom = targetH - 1
        while bottom > top + 1, rowLuminance(bottom) < threshold { bottom -= 1 }
        var left = 0
        while left < targetW - 1, colLuminance(left) < threshold { left += 1 }
        var right = targetW - 1
        while right > left + 1, colLuminance(right) < threshold { right -= 1 }

        // If we trimmed nothing, return full image.
        let trimmedAtAll = (top > 0 || left > 0 || bottom < targetH - 1 || right < targetW - 1)
        guard trimmedAtAll else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let nx = CGFloat(left) / CGFloat(targetW)
        let ny = CGFloat(top) / CGFloat(targetH)
        let nw = CGFloat(right - left + 1) / CGFloat(targetW)
        let nh = CGFloat(bottom - top + 1) / CGFloat(targetH)
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }
}
