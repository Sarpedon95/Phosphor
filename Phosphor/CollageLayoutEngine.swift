import UIKit
import CoreGraphics

/// Input bundle for the layout engine. `aspect` is the source image's intrinsic
/// aspect (width / height); we don't recompute it from UIImage so the caller
/// can supply EXIF-corrected values when available.
struct CollageInput: Hashable {
    let assetId: String
    let image: UIImage
    let aspect: CGFloat
}

/// Produces a fully-populated `CollageSpec` (cell frames + cell crops) for a
/// set of inputs and a chosen layout. Smart cropping runs concurrently via
/// `TaskGroup` so even 30-photo collages compute in a single Vision pass.
actor CollageLayoutEngine {
    static let shared = CollageLayoutEngine()
    private let cropper = IntelligentCropEngine.shared

    /// Produce a `CollageSpec`. `gapWidth` and corner radius are passed in so
    /// the renderer can use them later; layout maths themselves are
    /// gap-agnostic (we compute frames as if there were no gap, then the
    /// renderer trims).
    func generateLayout(
        assets: [CollageInput],
        layout: CollageLayout,
        canvasAspect: CGFloat,
        gapWidth: CGFloat
    ) async -> CollageSpec {
        let frames = computeFrames(layout: layout, count: assets.count, canvasAspect: canvasAspect, inputs: assets)
        let crops = await computeCrops(inputs: assets, frames: frames)

        var cells: [CollageCell] = []
        cells.reserveCapacity(assets.count)
        for (i, input) in assets.enumerated() where i < frames.count {
            let frame = frames[i].frame
            let rotation = frames[i].rotation
            let zIndex = frames[i].zIndex
            let cropRect = crops[i] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            cells.append(CollageCell(
                assetId: input.assetId,
                frame: frame,
                cropRect: cropRect,
                aspectRatio: input.aspect,
                rotation: rotation,
                zIndex: zIndex,
                cornerRadius: 0
            ))
        }

        return CollageSpec(
            layout: layout,
            cells: cells,
            canvasAspect: canvasAspect,
            gapWidth: gapWidth
        )
    }

    // MARK: - Concurrent smart cropping

    private func computeCrops(
        inputs: [CollageInput],
        frames: [PositionedFrame]
    ) async -> [CGRect?] {
        var results = Array<CGRect?>(repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, CGRect?).self) { group in
            for (i, input) in inputs.enumerated() where i < frames.count {
                let cellAspect = max(0.001, frames[i].frame.width / max(frames[i].frame.height, 0.0001))
                let canvasCellAspect = cellAspect    // already in canvas-normalized space
                let cropper = self.cropper
                let image = input.image
                let assetId = input.assetId
                group.addTask {
                    let crop = await cropper.smartCrop(
                        assetId: assetId, image: image, targetAspect: canvasCellAspect
                    )
                    return (i, crop)
                }
            }
            for await (i, crop) in group {
                if i < results.count { results[i] = crop }
            }
        }
        return results
    }

    // MARK: - Frame layout dispatch

    /// One placed cell in canvas-normalized coordinates plus rotation/z.
    private struct PositionedFrame {
        var frame: CGRect
        var rotation: CGFloat = 0
        var zIndex: Int = 0
    }

    private func computeFrames(
        layout: CollageLayout,
        count: Int,
        canvasAspect: CGFloat,
        inputs: [CollageInput]
    ) -> [PositionedFrame] {
        guard count > 0 else { return [] }
        switch layout {
        case .justified(let h):
            return justified(targetRowHeight: h, canvasAspect: canvasAspect, inputs: inputs)
        case .quilt(let columns):
            return quilt(columns: columns, count: count, canvasAspect: canvasAspect)
        case .mosaic:
            return mosaic(count: count, canvasAspect: canvasAspect)
        case .magazine:
            return magazine(count: count, canvasAspect: canvasAspect)
        case .horizontalStrip:
            return horizontalStrip(canvasAspect: canvasAspect, inputs: inputs)
        case .verticalStrip:
            return verticalStrip(canvasAspect: canvasAspect, inputs: inputs)
        case .diagonal(let angle):
            return diagonal(angle: angle, count: count, canvasAspect: canvasAspect)
        case .cascade:
            return cascade(count: count, canvasAspect: canvasAspect)
        case .freeform:
            return freeformDefault(count: count, canvasAspect: canvasAspect)
        }
    }

    // MARK: - Layout algorithms (canvas-normalized 0–1)

    /// Justified: variable row widths at equal heights, scale each row to fill.
    private func justified(
        targetRowHeight: CGFloat,
        canvasAspect: CGFloat,
        inputs: [CollageInput]
    ) -> [PositionedFrame] {
        // Convert pixel-ish targetRowHeight into a normalized row height by
        // assuming a notional 1000pt-wide canvas. The actual canvas size is
        // applied at render time.
        let notionalWidth: CGFloat = 1000
        let notionalHeight = notionalWidth / canvasAspect
        let rowH = max(40, min(targetRowHeight, notionalHeight))
        let normalizedRowH = rowH / notionalHeight

        struct Row { var indices: [Int]; var aspectSum: CGFloat }
        var rows: [Row] = []
        var current = Row(indices: [], aspectSum: 0)
        let targetAspectSum = canvasAspect / normalizedRowH   // packed widths fill canvas

        for (i, input) in inputs.enumerated() {
            let a = clampedAspect(input.aspect)
            if current.aspectSum + a > targetAspectSum && !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], aspectSum: 0)
            }
            current.indices.append(i)
            current.aspectSum += a
        }
        if !current.indices.isEmpty { rows.append(current) }

        // Lay out each row.
        //
        // Derivation: a photo of natural aspect `a` rendered at normalized
        // canvas-height `h` has normalized canvas-width `h * a / canvasAspect`
        // (the canvas is anisotropic in 0–1 coordinates). For widths to sum
        // to 1.0 across a fill row:
        //
        //   h * (Σa) / canvasAspect = 1   →   h = canvasAspect / Σa
        //
        // That value is `scale`. So normalized height = scale directly, and
        // normalized width per photo = a / Σa.
        //
        // For a last-row no-stretch case we instead use `scale = normalizedRowH`
        // (the target row height in normalized canvas-height units); the same
        // identities still hold.
        var frames = Array(repeating: PositionedFrame(frame: .zero), count: inputs.count)
        var y: CGFloat = 0
        for row in rows {
            let isLast = (row.indices == rows.last?.indices)
            let scale: CGFloat
            if isLast && row.indices.count < 3 {
                scale = normalizedRowH    // don't stretch a small last row
            } else {
                scale = canvasAspect / row.aspectSum   // fill exactly
            }
            let normH = scale
            var x: CGFloat = 0
            for idx in row.indices {
                let a = clampedAspect(inputs[idx].aspect)
                let normW = a * scale / canvasAspect
                frames[idx] = PositionedFrame(
                    frame: CGRect(x: x, y: y, width: normW, height: normH)
                )
                x += normW
            }
            y += normH
            if y >= 1 { break }
        }
        return frames
    }

    /// Quilt: equal-size cells in a `columns`-wide grid.
    ///
    /// Pixel-square cells (`cellH = cellW × canvasAspect`) would overflow a
    /// wide canvas — three rows of pixel-squares on a 2:1 canvas total 200%
    /// normalized height. We therefore:
    ///   1. Compute pixel-square cell size.
    ///   2. Pick the row count that fits within 1.0 normalized height
    ///      (`floor(1 / pixelSquareH)`, but at least one row).
    ///   3. If the total cell count exceeds that grid, fall back to
    ///      proportional cells (`cellH = 1 / rows`) so every supplied photo
    ///      is placed; cells are visually square only on a square canvas.
    private func quilt(columns: Int, count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        let cols = max(1, columns)
        let neededRows = Int(ceil(Double(count) / Double(cols)))
        guard neededRows > 0 else { return [] }

        let cellW: CGFloat = 1.0 / CGFloat(cols)
        let pixelSquareH: CGFloat = cellW * canvasAspect
        let rowsFittingSquare = max(1, Int(floor(1.0 / pixelSquareH)))
        let cellH: CGFloat
        if neededRows <= rowsFittingSquare {
            cellH = pixelSquareH
        } else {
            // Compress to non-square (proportional) to fit all photos.
            cellH = 1.0 / CGFloat(neededRows)
        }

        var frames: [PositionedFrame] = []
        for i in 0..<count {
            let c = i % cols
            let r = i / cols
            frames.append(PositionedFrame(
                frame: CGRect(
                    x: CGFloat(c) * cellW,
                    y: CGFloat(r) * cellH,
                    width: cellW,
                    height: cellH
                )
            ))
        }
        return frames
    }

    /// Mosaic: hero top-left + filler cells. For >9 photos the hero shrinks
    /// and the remainder fills as a justified band.
    private func mosaic(count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        guard count > 0 else { return [] }
        if count == 1 {
            return [PositionedFrame(frame: CGRect(x: 0, y: 0, width: 1, height: 1))]
        }

        let heroSize: CGFloat = count > 9 ? 0.5 : (2.0 / 3.0)
        var frames: [PositionedFrame] = []
        // Hero.
        frames.append(PositionedFrame(frame: CGRect(x: 0, y: 0, width: heroSize, height: heroSize)))

        // Right column.
        let rightCols = 1
        let rightRows = max(1, count - 1) / 2   // half goes on right, half on bottom
        let rightCellW = 1 - heroSize
        let rightCellH = heroSize / CGFloat(max(1, rightRows))
        var placed = 1
        for r in 0..<rightRows where placed < count {
            frames.append(PositionedFrame(
                frame: CGRect(x: heroSize, y: CGFloat(r) * rightCellH, width: rightCellW, height: rightCellH)
            ))
            placed += 1
        }

        // Bottom row across full width, equal cells.
        let remaining = max(0, count - placed)
        if remaining > 0 {
            let bottomH = 1 - heroSize
            let bottomCells = max(1, remaining)
            let cellW = 1.0 / CGFloat(bottomCells)
            for i in 0..<bottomCells {
                frames.append(PositionedFrame(
                    frame: CGRect(x: CGFloat(i) * cellW, y: heroSize, width: cellW, height: bottomH)
                ))
            }
        }
        _ = rightCols
        return frames
    }

    /// Magazine: full-width hero (40%) + justified grid below (60%).
    private func magazine(count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        guard count > 0 else { return [] }
        var frames: [PositionedFrame] = []
        frames.append(PositionedFrame(frame: CGRect(x: 0, y: 0, width: 1, height: 0.4)))
        let remaining = count - 1
        if remaining > 0 {
            // Lay the rest out as a 2-row equal grid.
            let cols = max(1, Int(ceil(Double(remaining) / 2.0)))
            let cellW = 1.0 / CGFloat(cols)
            let cellH: CGFloat = 0.3
            for i in 0..<remaining {
                let c = i % cols
                let r = i / cols
                let y: CGFloat = 0.4 + CGFloat(r) * cellH
                frames.append(PositionedFrame(
                    frame: CGRect(x: CGFloat(c) * cellW, y: y, width: cellW, height: cellH)
                ))
            }
        }
        return frames
    }

    /// Horizontal strip: photos at canvas height, widths proportional to aspect.
    /// Note: total width may exceed 1.0 — CollageCanvas wraps in a horizontal
    /// ScrollView for this layout.
    private func horizontalStrip(canvasAspect: CGFloat, inputs: [CollageInput]) -> [PositionedFrame] {
        var frames: [PositionedFrame] = []
        var x: CGFloat = 0
        for input in inputs {
            let a = clampedAspect(input.aspect)
            // height = 1 (full canvas); width in canvas-normalized = a / canvasAspect.
            let w = a / canvasAspect
            frames.append(PositionedFrame(frame: CGRect(x: x, y: 0, width: w, height: 1)))
            x += w
        }
        return frames
    }

    /// Vertical strip: photos at canvas width, heights proportional. May
    /// overflow vertically — canvas wraps in vertical ScrollView.
    private func verticalStrip(canvasAspect: CGFloat, inputs: [CollageInput]) -> [PositionedFrame] {
        var frames: [PositionedFrame] = []
        var y: CGFloat = 0
        for input in inputs {
            let a = clampedAspect(input.aspect)
            // width = 1, height = canvasAspect / a in normalized coords.
            let h = canvasAspect / a
            frames.append(PositionedFrame(frame: CGRect(x: 0, y: y, width: 1, height: h)))
            y += h
        }
        return frames
    }

    /// Diagonal: photos arranged along TL→BR axis with slight rotations.
    private func diagonal(angle: CGFloat, count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        guard count > 0 else { return [] }
        let cellSize: CGFloat = 0.35
        var frames: [PositionedFrame] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(max(1, count - 1))
            let x = (1 - cellSize) * t
            let y = (1 - cellSize) * t
            let rotation: CGFloat = (i % 2 == 0) ? angle : -angle
            frames.append(PositionedFrame(
                frame: CGRect(x: x, y: y, width: cellSize, height: cellSize),
                rotation: rotation,
                zIndex: i
            ))
        }
        return frames
    }

    /// Cascade: stacked with small offsets + alternating rotations.
    private func cascade(count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        guard count > 0 else { return [] }
        let cellSize: CGFloat = 0.6
        let stepX: CGFloat = 0.04
        let stepY: CGFloat = 0.04
        let totalSpread = stepX * CGFloat(count - 1)
        let baseX = max(0, (1 - cellSize - totalSpread) / 2)
        let baseY = max(0, (1 - cellSize - totalSpread) / 2)
        var frames: [PositionedFrame] = []
        for i in 0..<count {
            let rotations: [CGFloat] = [2, -1, 3, -2, 1, -3]
            frames.append(PositionedFrame(
                frame: CGRect(
                    x: baseX + CGFloat(i) * stepX,
                    y: baseY + CGFloat(i) * stepY,
                    width: cellSize,
                    height: cellSize
                ),
                rotation: rotations[i % rotations.count],
                zIndex: i
            ))
        }
        return frames
    }

    /// Freeform: initial layout is a sparse 2-column grid the user can then
    /// drag/resize. Each frame stays inside the canvas.
    private func freeformDefault(count: Int, canvasAspect: CGFloat) -> [PositionedFrame] {
        let cols = 2
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))
        let cellW: CGFloat = 0.4
        let cellH: CGFloat = 0.4
        let gapX = (1 - CGFloat(cols) * cellW) / CGFloat(cols + 1)
        let gapY = (1 - CGFloat(rows) * cellH) / CGFloat(rows + 1)
        var frames: [PositionedFrame] = []
        for i in 0..<count {
            let c = i % cols
            let r = i / cols
            frames.append(PositionedFrame(
                frame: CGRect(
                    x: gapX + CGFloat(c) * (cellW + gapX),
                    y: gapY + CGFloat(r) * (cellH + gapY),
                    width: cellW,
                    height: cellH
                ),
                zIndex: i
            ))
        }
        return frames
    }

    // MARK: - Utility

    private func clampedAspect(_ raw: CGFloat) -> CGFloat {
        // Same clamp as JustifiedLayout in TimelineGridView — keeps a single
        // panoramic photo from blowing up its row.
        guard raw.isFinite, raw > 0 else { return 1.5 }
        return min(max(raw, 0.3), 4.0)
    }
}
