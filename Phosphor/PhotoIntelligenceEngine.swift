import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

struct SceneLabel: Hashable {
    let identifier: String
    let confidence: Float
}

/// Vision-only on-device analysis. No bundled CoreML models, no third party.
/// Every method dispatches its heavy work via `Task.detached` so callers
/// (often `@MainActor` view models) never block the UI.
actor PhotoIntelligenceEngine {
    static let shared = PhotoIntelligenceEngine()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Blur

    /// 0.0 = razor sharp, 1.0 = very blurry. Threshold for "blurry" is > 0.65.
    /// Approach: edge map (CIEdges) → variance of edge luminance. Sharp images
    /// have many high-contrast edges → high variance.
    func detectBlur(image: UIImage) async -> Double {
        let context = ciContext
        return await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return 0 }
            let ci = CIImage(cgImage: cg)
            let downsized = Self.downsample(ci, longest: 400)

            let edges = CIFilter.edges()
            edges.inputImage = downsized
            edges.intensity = 1.0
            guard let out = edges.outputImage else { return 0 }

            let extent = out.extent.integral
            guard extent.width > 1, extent.height > 1,
                  let rendered = context.createCGImage(out, from: extent)
            else { return 0 }

            // Mean + variance of edge luminance.
            let stats = Self.luminanceStats(of: rendered)
            // Empirical: variance below ~0.0015 ≈ very soft. Map to 0–1.
            let v = stats.variance
            let sharpness = min(1.0, v / 0.02)        // 1.0 = lots of crisp edges
            return max(0.0, 1.0 - sharpness)
        }.value
    }

    // MARK: - Faces

    /// Face bounding boxes in **UIKit** normalized coords (origin top-left).
    /// Empty array (never nil) on any failure.
    func detectFaces(image: UIImage) async -> [CGRect] {
        await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return [] }
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            guard let observations = request.results else { return [] }
            return observations.map { obs in
                let b = obs.boundingBox   // Vision: origin bottom-left
                return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            }
        }.value
    }

    // MARK: - Scene classification

    func classifyScene(image: UIImage) async -> [SceneLabel] {
        await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return [] }
            // Fresh request + handler per call — never reuse (results leak).
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            guard let observations = request.results else { return [] }
            return observations
                .filter { $0.confidence > 0.5 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }
        }.value
    }

    // MARK: - Similarity

    func computeFeaturePrint(image: UIImage) async -> VNFeaturePrintObservation? {
        await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return nil }
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            return request.results?.first as? VNFeaturePrintObservation
        }.value
    }

    /// Returns candidates sorted by L2 distance **ascending** — lower distance
    /// is more similar. Candidates whose distance can't be computed are
    /// skipped, not crashed.
    func findSimilar(
        reference: VNFeaturePrintObservation,
        candidates: [(assetId: String, observation: VNFeaturePrintObservation)]
    ) async -> [(assetId: String, distance: Float)] {
        var scored: [(assetId: String, distance: Float)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            var distance: Float = 0
            do {
                try reference.computeDistance(&distance, to: candidate.observation)
            } catch {
                continue   // skip uncomputable pairs
            }
            scored.append((candidate.assetId, distance))
        }
        return scored.sorted { $0.distance < $1.distance }
    }

    // MARK: - Horizon

    /// Degrees of rotation to level the horizon. Positive = clockwise (matches
    /// the straighten slider's convention). 0 if no horizon / error.
    func detectHorizon(image: UIImage) async -> Double {
        await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return 0 }
            let request = VNDetectHorizonRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return 0
            }
            guard let obs = request.results?.first as? VNHorizonObservation else { return 0 }
            // `obs.angle` is the horizon tilt in radians. The correction to
            // level it is the negation, expressed in degrees.
            let degrees = Double(-obs.angle) * 180.0 / .pi
            return max(-45, min(45, degrees))
        }.value
    }

    // MARK: - Helpers

    nonisolated private static func downsample(_ image: CIImage, longest: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = longest / max(extent.width, extent.height)
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Mean + variance of luminance from an RGBA8 CGImage, computed with a
    /// straightforward single pass (the image is already ≤400px so this is
    /// cheap and avoids pulling in a vDSP pipeline for a scalar statistic).
    nonisolated private static func luminanceStats(of cg: CGImage) -> (mean: Double, variance: Double) {
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return (0, 0) }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum: Double = 0
        var sumSq: Double = 0
        let count = width * height
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            sum += l
            sumSq += l * l
        }
        let mean = sum / Double(count)
        let variance = max(0, sumSq / Double(count) - mean * mean)
        return (mean, variance)
    }
}
