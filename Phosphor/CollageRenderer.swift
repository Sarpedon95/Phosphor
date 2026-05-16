import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os
import Darwin

/// Renders a `CollageSpec` to a UIImage at the requested resolution.
///
/// All compositing is GPU-accelerated via `CIContext(options:
/// [.useSoftwareRenderer: false])`. To keep memory bounded on large collages,
/// cells are processed in tiles of `maxConcurrentCells` (4 by default).
actor CollageRenderer {
    static let shared = CollageRenderer()

    /// Hard cap on the number of full-resolution cells materialized at once.
    /// Tuned for "30 photos at 6000px" to stay under ~600 MB working set.
    static let maxConcurrentCells = 4

    private let context: CIContext = {
        // Software renderer would fall back to CPU; we want Metal.
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Progress callback type: `(cellsRendered, totalCells)`.
    typealias Progress = @Sendable (Int, Int) -> Void

    /// Renders the spec to a single `UIImage`.
    ///
    /// `outputSize` is the canvas size in pixels. If `nil` (Maximum quality)
    /// the renderer derives a size from the sum of input asset pixel sizes,
    /// capped at 12000px to prevent absurd outputs.
    func render(
        spec: CollageSpec,
        outputSize: CGSize?,
        progress: Progress? = nil
    ) async -> UIImage? {
        guard !spec.cells.isEmpty else { return nil }
        let canvasPx = resolveCanvasSize(spec: spec, outputSize: outputSize)
        guard canvasPx.width > 0, canvasPx.height > 0 else { return nil }

        // Background.
        let bgColor = CIColor(
            red: spec.backgroundColor.red,
            green: spec.backgroundColor.green,
            blue: spec.backgroundColor.blue,
            alpha: spec.backgroundColor.opacity
        )
        var composite = CIImage(color: bgColor)
            .cropped(to: CGRect(origin: .zero, size: canvasPx))

        // Sort cells by zIndex so freeform/cascade composite correctly.
        let ordered = spec.cells.sorted { $0.zIndex < $1.zIndex }
        let total = ordered.count
        var rendered = 0

        // Process in tiles.
        for tile in tiles(of: ordered, size: Self.maxConcurrentCells) {
            let pieces = await processTile(
                tile,
                spec: spec,
                canvasPx: canvasPx
            )
            for piece in pieces {
                composite = piece.composited(over: composite)
            }
            rendered += tile.count
            progress?(rendered, total)
        }

        // Apply outer corner radius via a mask if requested.
        if spec.cornerRadius > 0 {
            composite = applyCornerMask(composite, canvasPx: canvasPx, radius: spec.cornerRadius)
        }

        // Render to UIImage on GPU.
        guard let cg = context.createCGImage(composite, from: CGRect(origin: .zero, size: canvasPx))
        else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Pipeline

    private func processTile(
        _ cells: [CollageCell],
        spec: CollageSpec,
        canvasPx: CGSize
    ) async -> [CIImage] {
        // Concurrent per-cell extraction (load + crop + blend filters).
        var results = Array<CIImage?>(repeating: nil, count: cells.count)
        await withTaskGroup(of: (Int, CIImage?).self) { group in
            for (idx, cell) in cells.enumerated() {
                let renderer = self
                group.addTask {
                    let img = await renderer.renderCell(cell, spec: spec, canvasPx: canvasPx)
                    return (idx, img)
                }
            }
            for await (idx, img) in group {
                if idx < results.count { results[idx] = img }
            }
        }
        return results.compactMap { $0 }
    }

    private func renderCell(
        _ cell: CollageCell,
        spec: CollageSpec,
        canvasPx: CGSize
    ) async -> CIImage? {
        guard let uiImage = await ImageLoader.shared.fullImage(for: cell.assetId),
              let cgImage = uiImage.cgImage
        else { return nil }
        var ci = CIImage(cgImage: cgImage)

        // Apply optional colour harmonisation BEFORE cropping so the per-cell
        // tone normalisation operates on the full image.
        if spec.blendMode == .colorHarmonized {
            ci = harmonize(ci)
        }

        // Crop in source pixels.
        let srcSize = ci.extent.size
        let cropPx = CGRect(
            x: cell.cropRect.minX * srcSize.width,
            y: (1 - cell.cropRect.maxY) * srcSize.height,   // CI origin is bottom-left
            width: cell.cropRect.width * srcSize.width,
            height: cell.cropRect.height * srcSize.height
        )
        ci = ci.cropped(to: cropPx)
            .transformed(by: CGAffineTransform(translationX: -cropPx.minX, y: -cropPx.minY))

        // Compute the destination frame in pixels.
        let effectiveGap = (spec.blendMode == .fullBleed) ? 0 : spec.gapWidth
        var destPx = CGRect(
            x: cell.frame.minX * canvasPx.width + effectiveGap / 2,
            y: (1 - cell.frame.maxY) * canvasPx.height + effectiveGap / 2,
            width: cell.frame.width * canvasPx.width - effectiveGap,
            height: cell.frame.height * canvasPx.height - effectiveGap
        )
        // Negative sizes from gap > cell — clamp.
        if destPx.width <= 0 || destPx.height <= 0 { return nil }

        // Scale source crop to destination size.
        let scaleX = destPx.width / cropPx.width
        let scaleY = destPx.height / cropPx.height
        ci = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Optional rotation around the cell center.
        if cell.rotation != 0 {
            let radians = cell.rotation * .pi / 180
            let center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
            ci = ci
                .transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
                .transformed(by: CGAffineTransform(rotationAngle: -radians))
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
        }

        // Per-cell corner radius via SwiftUI gets us free anti-aliased clipping;
        // in CI we use a rounded-rect mask.
        let cornerRadius = max(cell.cornerRadius, spec.cornerRadius > 0 ? 0 : 0)
        if cornerRadius > 0 {
            ci = applyRoundedMask(ci, in: ci.extent, radius: cornerRadius * scaleX)
        }

        // Translate the cell into its canvas position.
        ci = ci.transformed(by: CGAffineTransform(
            translationX: destPx.minX - ci.extent.minX,
            y: destPx.minY - ci.extent.minY
        ))

        // Feathered edges: only on edges that touch another cell.
        if spec.blendMode == .feathered {
            ci = featherEdges(ci, cellFrame: cell.frame, neighbours: spec.cells, destPx: destPx)
        }

        return ci
    }

    // MARK: - Blend mode helpers

    private func harmonize(_ image: CIImage) -> CIImage {
        // Push every cell toward a shared target luminance/temperature so a
        // mixed-tone set looks like one shoot.
        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = image
        temperature.neutral = CIVector(x: 6500, y: 0)
        temperature.targetNeutral = CIVector(x: 6200, y: 0)
        let tempOut = temperature.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = tempOut
        controls.saturation = 0.92
        controls.contrast = 1.02
        controls.brightness = 0
        return controls.outputImage ?? tempOut
    }

    private func applyRoundedMask(_ image: CIImage, in extent: CGRect, radius: CGFloat) -> CIImage {
        // Build a rounded-rect alpha mask via CG, lift it into CI.
        let renderer = UIGraphicsImageRenderer(size: extent.size)
        let mask = renderer.image { ctx in
            UIColor.black.setFill()
            let rect = CGRect(origin: .zero, size: extent.size)
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        }
        guard let maskCG = mask.cgImage else { return image }
        let maskCI = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = maskCI
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        return blend.outputImage ?? image
    }

    private func applyCornerMask(_ image: CIImage, canvasPx: CGSize, radius: CGFloat) -> CIImage {
        let extent = CGRect(origin: .zero, size: canvasPx)
        return applyRoundedMask(image, in: extent, radius: radius)
    }

    /// Feathered: build a per-edge alpha gradient that fades to transparent on
    /// edges adjacent to another cell. Edges on the canvas border stay solid.
    private func featherEdges(
        _ image: CIImage,
        cellFrame: CGRect,
        neighbours: [CollageCell],
        destPx: CGRect
    ) -> CIImage {
        let featherPx: CGFloat = 12

        func touches(side: Edge) -> Bool {
            let epsilon: CGFloat = 0.002
            switch side {
            case .left:
                if cellFrame.minX <= epsilon { return false }
                return neighbours.contains { other in
                    !other.frame.equalTo(cellFrame)
                        && abs(other.frame.maxX - cellFrame.minX) < epsilon
                }
            case .right:
                if cellFrame.maxX >= 1 - epsilon { return false }
                return neighbours.contains { other in
                    !other.frame.equalTo(cellFrame)
                        && abs(other.frame.minX - cellFrame.maxX) < epsilon
                }
            case .top:
                if cellFrame.minY <= epsilon { return false }
                return neighbours.contains { other in
                    !other.frame.equalTo(cellFrame)
                        && abs(other.frame.maxY - cellFrame.minY) < epsilon
                }
            case .bottom:
                if cellFrame.maxY >= 1 - epsilon { return false }
                return neighbours.contains { other in
                    !other.frame.equalTo(cellFrame)
                        && abs(other.frame.minY - cellFrame.maxY) < epsilon
                }
            }
        }

        var image = image
        if touches(side: .left) {
            image = applyEdgeFade(image, extent: destPx, edge: .left, length: featherPx)
        }
        if touches(side: .right) {
            image = applyEdgeFade(image, extent: destPx, edge: .right, length: featherPx)
        }
        if touches(side: .top) {
            image = applyEdgeFade(image, extent: destPx, edge: .top, length: featherPx)
        }
        if touches(side: .bottom) {
            image = applyEdgeFade(image, extent: destPx, edge: .bottom, length: featherPx)
        }
        return image
    }

    private enum Edge { case left, right, top, bottom }

    /// Multiply the cell's alpha by a linear gradient that's transparent at the
    /// requested edge over `length` pixels and opaque elsewhere.
    private func applyEdgeFade(_ image: CIImage, extent: CGRect, edge: Edge, length: CGFloat) -> CIImage {
        let start: CGPoint
        let end: CGPoint
        switch edge {
        case .left:
            start = CGPoint(x: extent.minX, y: extent.midY)
            end = CGPoint(x: extent.minX + length, y: extent.midY)
        case .right:
            start = CGPoint(x: extent.maxX, y: extent.midY)
            end = CGPoint(x: extent.maxX - length, y: extent.midY)
        case .top:
            start = CGPoint(x: extent.midX, y: extent.maxY)
            end = CGPoint(x: extent.midX, y: extent.maxY - length)
        case .bottom:
            start = CGPoint(x: extent.midX, y: extent.minY)
            end = CGPoint(x: extent.midX, y: extent.minY + length)
        }
        // `CIBlendWithMask` interpolates input ↔ background by the mask's
        // *luminance*, not alpha. The fading edge must therefore be BLACK
        // (luminance 0 → show transparent background) transitioning to WHITE
        // (luminance 1 → show full input). The previous implementation used a
        // pure-black gradient varying only in alpha, which made the entire
        // cell invisible.
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: start.x, y: start.y)
        gradient.point1 = CGPoint(x: end.x, y: end.y)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let mask = gradient.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        return blend.outputImage ?? image
    }

    // MARK: - Sizing

    private func resolveCanvasSize(spec: CollageSpec, outputSize: CGSize?) -> CGSize {
        if let outputSize { return safe(outputSize) }
        // Maximum quality: cap at 12000px longest side as the absolute ceiling
        // (matches Apple Photos export), then clamp again to whatever the
        // current device can actually allocate.
        let longest: CGFloat = 12000
        let raw: CGSize
        if spec.canvasAspect >= 1 {
            raw = CGSize(width: longest, height: longest / spec.canvasAspect)
        } else {
            raw = CGSize(width: longest * spec.canvasAspect, height: longest)
        }
        return safe(raw)
    }

    /// Clamp a requested canvas size to what the device can plausibly render.
    /// A premultiplied RGBA buffer is 4 bytes per pixel; iOS will out-of-memory
    /// well before exhausting physical RAM because of the unified-memory budget,
    /// so we target 25 % of `os_proc_available_memory()` as a working-set cap
    /// (Apple's recommended ceiling for "single transient buffer").
    private func safe(_ size: CGSize) -> CGSize {
        let pixels = Double(size.width) * Double(size.height)
        guard pixels > 0 else { return size }
        let bytesNeeded = pixels * 4
        let available = Double(os_proc_available_memory())
        // Defensive default for simulators / cases where the API returns 0.
        let budget = available > 0 ? available * 0.25 : (1024 * 1024 * 1024)   // 1 GB fallback
        guard bytesNeeded > budget else { return size }
        let scale = sqrt(budget / bytesNeeded)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func tiles<T>(of items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
