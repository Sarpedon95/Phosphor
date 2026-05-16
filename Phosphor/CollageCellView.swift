import SwiftUI

/// Renders one `CollageCell` on the canvas. The hot-path during interactive
/// editing uses `Image(uiImage:)` with `clipped()` + a corner-radius
/// `clipShape` — fast and good enough for a live preview. Final export uses
/// the GPU pipeline in `CollageRenderer`.
struct CollageCellView: View {
    let cell: CollageCell
    let canvasSize: CGSize
    let image: UIImage?
    let blendMode: CollageBlendMode
    let gapWidth: CGFloat
    let cornerRadius: CGFloat
    let isSelected: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack {
                content
                if isSelected {
                    RoundedRectangle(cornerRadius: cellCornerRadius)
                        .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                }
            }
        }
        // Inset the cell by half the gap on each side so adjacent cells reveal
        // the background between them. Full-bleed mode forces gap to zero.
        .padding(effectiveGap / 2)
        .frame(width: pixelFrame.width, height: pixelFrame.height)
        .position(x: pixelFrame.midX, y: pixelFrame.midY)
        .rotationEffect(.degrees(cell.rotation))
        .zIndex(Double(cell.zIndex))
    }

    private var effectiveGap: CGFloat {
        blendMode == .fullBleed ? 0 : gapWidth
    }

    private var cellCornerRadius: CGFloat {
        blendMode == .fullBleed ? 0 : cornerRadius
    }

    private var pixelFrame: CGRect {
        CGRect(
            x: cell.frame.minX * canvasSize.width,
            y: cell.frame.minY * canvasSize.height,
            width: cell.frame.width * canvasSize.width,
            height: cell.frame.height * canvasSize.height
        )
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            CroppedImageView(image: image, cropRect: cell.cropRect, cornerRadius: cellCornerRadius)
                .opacity(blendMode == .feathered ? 0.98 : 1.0)
        } else {
            ShimmerView()
                .clipShape(RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous))
        }
    }
}

/// Applies a normalized crop rect to a UIImage by scaling + offsetting the
/// rendered Image. Cheaper than allocating a new UIImage per frame.
struct CroppedImageView: View {
    let image: UIImage
    let cropRect: CGRect    // normalized 0–1
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geo in
            let imgSize = image.size
            // Scale factor so the crop region exactly fills the cell.
            let scaleX = geo.size.width / max(1, cropRect.width * imgSize.width)
            let scaleY = geo.size.height / max(1, cropRect.height * imgSize.height)
            let scale = max(scaleX, scaleY)
            let scaled = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
            let offsetX = -cropRect.minX * imgSize.width * scale
                + (geo.size.width - cropRect.width * imgSize.width * scale) / 2
            let offsetY = -cropRect.minY * imgSize.height * scale
                + (geo.size.height - cropRect.height * imgSize.height * scale) / 2
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: scaled.width, height: scaled.height)
                .offset(x: offsetX, y: offsetY)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
