import SwiftUI
import Accelerate

enum HistogramMode { case rgb, luminance, hidden }

/// 80pt RGB/luminance histogram computed off-main via vImage. Recomputes
/// debounced (200ms) when `image` changes.
struct HistogramView: View {
    let image: UIImage?
    @Binding var mode: HistogramMode

    @State private var bins: HistogramBins?
    @State private var computeTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch mode {
            case .hidden:
                Color.clear.frame(height: 0)
            case .rgb, .luminance:
                Canvas { ctx, size in
                    guard let bins else { return }
                    if mode == .rgb {
                        draw(bins.red, color: .red, size: size, ctx: &ctx)
                        draw(bins.green, color: .green, size: size, ctx: &ctx)
                        draw(bins.blue, color: .blue, size: size, ctx: &ctx)
                    } else {
                        draw(bins.luminance, color: .white, size: size, ctx: &ctx)
                    }
                }
                .frame(height: 80)
                .background(Color.black.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { cycleMode() }
        .animation(.easeInOut(duration: 0.2), value: mode == .hidden)
        .task(id: image) { scheduleCompute() }
    }

    private func cycleMode() {
        switch mode {
        case .rgb: mode = .luminance
        case .luminance: mode = .hidden
        case .hidden: mode = .rgb
        }
    }

    private func scheduleCompute() {
        computeTask?.cancel()
        guard mode != .hidden, let image else { return }
        computeTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let computed = await Self.compute(image)
            if Task.isCancelled { return }
            await MainActor.run { self.bins = computed }
        }
    }

    private func draw(_ data: [UInt], color: Color, size: CGSize, ctx: inout GraphicsContext) {
        let maxV = max(data.max() ?? 1, 1)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        let step = size.width / 256
        for i in 0..<256 {
            let h = size.height * CGFloat(Double(data[i]) / Double(maxV))
            path.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.4)))
    }

    struct HistogramBins { let red: [UInt]; let green: [UInt]; let blue: [UInt]; let luminance: [UInt] }

    nonisolated static func compute(_ image: UIImage) async -> HistogramBins? {
        await Task.detached(priority: .utility) {
            guard let cg = image.cgImage else { return nil }
            // Downsample to ~200px wide for speed.
            let w = 200
            let h = max(1, Int(200 * CGFloat(cg.height) / CGFloat(max(1, cg.width))))
            let bpr = w * 4
            var px = [UInt8](repeating: 0, count: bpr * h)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: &px, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bpr, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            var red = [vImagePixelCount](repeating: 0, count: 256)
            var green = [vImagePixelCount](repeating: 0, count: 256)
            var blue = [vImagePixelCount](repeating: 0, count: 256)
            var alpha = [vImagePixelCount](repeating: 0, count: 256)

            var buffer = vImage_Buffer(
                data: &px, height: vImagePixelCount(h),
                width: vImagePixelCount(w), rowBytes: bpr
            )
            let ok: vImage_Error = red.withUnsafeMutableBufferPointer { rp in
                green.withUnsafeMutableBufferPointer { gp in
                    blue.withUnsafeMutableBufferPointer { bp in
                        alpha.withUnsafeMutableBufferPointer { ap in
                            var hist = [rp.baseAddress, gp.baseAddress, bp.baseAddress, ap.baseAddress]
                            return hist.withUnsafeMutableBufferPointer { hp in
                                guard let base = hp.baseAddress else {
                                    return vImage_Error(kvImageNullPointerArgument)
                                }
                                return vImageHistogramCalculation_ARGB8888(&buffer, base, vImage_Flags(kvImageNoFlags))
                            }
                        }
                    }
                }
            }
            guard ok == kvImageNoError else { return nil }
            // Real per-pixel Rec.601 luminance histogram. Per-channel
            // histograms can't be recombined into luminance (they lack joint
            // pixel data), so we make a direct pass over the same RGBA buffer.
            var lum = [UInt](repeating: 0, count: 256)
            var idx = 0
            while idx + 3 < px.count {
                let r = Double(px[idx])
                let g = Double(px[idx + 1])
                let b = Double(px[idx + 2])
                let y = 0.299 * r + 0.587 * g + 0.114 * b
                let bin = min(255, max(0, Int(y.rounded())))
                lum[bin] += 1
                idx += 4
            }
            return HistogramBins(
                red: red.map { UInt($0) },
                green: green.map { UInt($0) },
                blue: blue.map { UInt($0) },
                luminance: lum
            )
        }.value
    }
}
