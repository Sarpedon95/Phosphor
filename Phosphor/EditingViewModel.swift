import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

// MARK: - Model

struct HSLAdjustment: Codable, Equatable, Hashable {
    var hue: Double = 0    // -0.5…+0.5
    var sat: Double = 0    // -1…+1
    var lum: Double = 0    // -1…+1
}

struct EditAdjustments: Codable, Equatable, Hashable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1.0
    var saturation: Double = 1.0
    var vibrance: Double = 0
    var warmth: Double = 6500
    var tint: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var blacks: Double = 0
    var whites: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0
    var vignette: Double = 0
    var grain: Double = 0
    var fade: Double = 0
    var toneCurve: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.25, y: 0.25),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75),
        CGPoint(x: 1, y: 1)
    ]
    var hsl: [HSLAdjustment] = Array(repeating: HSLAdjustment(), count: 8)
    var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var straightenAngle: Double = 0

    static let identity = EditAdjustments()
}

struct EditPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var adjustments: EditAdjustments
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, adjustments: EditAdjustments, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.isBuiltIn = isBuiltIn
    }

    static let builtIns: [EditPreset] = [
        EditPreset(name: "Identity", adjustments: .identity, isBuiltIn: true),
        EditPreset(name: "Vivid", adjustments: {
            var a = EditAdjustments(); a.saturation = 1.3; a.vibrance = 0.2; a.contrast = 1.1; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Matte", adjustments: {
            var a = EditAdjustments(); a.fade = 0.3; a.shadows = 0.1; a.saturation = 0.9; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Noir", adjustments: {
            var a = EditAdjustments(); a.saturation = 0.0; a.contrast = 1.2; a.sharpness = 0.2; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Warm", adjustments: {
            var a = EditAdjustments(); a.warmth = 7200; a.saturation = 1.1; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Cool", adjustments: {
            var a = EditAdjustments(); a.warmth = 5800; a.tint = -10; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Cinematic", adjustments: {
            var a = EditAdjustments(); a.contrast = 1.15; a.saturation = 0.9; a.fade = 0.15; a.vignette = -0.2; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Fade", adjustments: {
            var a = EditAdjustments(); a.fade = 0.4; a.saturation = 0.8; a.shadows = 0.15; return a
        }(), isBuiltIn: true),
        EditPreset(name: "Punch", adjustments: {
            var a = EditAdjustments(); a.contrast = 1.25; a.saturation = 1.2; a.sharpness = 0.15; return a
        }(), isBuiltIn: true)
    ]
}

// MARK: - View model

@MainActor
final class EditingViewModel: ObservableObject {
    @Published var adjustments: EditAdjustments = .identity
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var isProcessing = false
    @Published private(set) var editHistory: [EditAdjustments] = []
    @Published private(set) var redoStack: [EditAdjustments] = []
    @Published var selectedPreset: String?
    @Published private(set) var userPresets: [EditPreset] = []

    private var screenResImage: UIImage?
    private var previewTask: Task<Void, Never>?
    private let maxHistory = 50
    private static let userPresetsKey = "editing_user_presets"

    var canUndo: Bool { !editHistory.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var allPresets: [EditPreset] { EditPreset.builtIns + userPresets }

    init() {
        loadUserPresets()
    }

    // MARK: - Load

    func loadImage(asset: ImmichAsset) async {
        isProcessing = true
        defer { isProcessing = false }
        guard let full = await ImageLoader.shared.fullImage(for: asset.id) else { return }
        originalImage = full
        // Screen-resolution working copy for live preview.
        let screenScale = UIScreen.main.scale
        let target = UIScreen.main.bounds.size
        let longest = max(target.width, target.height) * screenScale
        screenResImage = Self.downsample(full, longest: longest)
        previewImage = screenResImage
    }

    // MARK: - Adjustment mutation

    func updateAdjustments(_ new: EditAdjustments) {
        // Snapshot the state *before* the change for undo.
        if editHistory.last != adjustments {
            editHistory.append(adjustments)
            if editHistory.count > maxHistory { editHistory.removeFirst() }
        }
        redoStack.removeAll()
        adjustments = new
        schedulePreview()
    }

    func undo() {
        guard let previous = editHistory.popLast() else { return }
        redoStack.append(adjustments)
        adjustments = previous
        schedulePreview()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        editHistory.append(adjustments)
        adjustments = next
        schedulePreview()
    }

    func reset() {
        editHistory.append(adjustments)
        redoStack.removeAll()
        adjustments = .identity
        selectedPreset = nil
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let base = screenResImage else { return }
        let adj = adjustments
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let result = await Self.applyPipeline(to: base, adj: adj, finalCrop: false)
            if Task.isCancelled { return }
            await MainActor.run { self?.previewImage = result }
        }
    }

    // MARK: - Presets

    func applyPreset(_ preset: EditPreset, intensity: Double) {
        selectedPreset = preset.name
        let blended = Self.lerp(.identity, preset.adjustments, t: intensity)
        updateAdjustments(blended)
    }

    func saveCurrentAsPreset(name: String) {
        let preset = EditPreset(name: name, adjustments: adjustments, isBuiltIn: false)
        userPresets.append(preset)
        persistUserPresets()
    }

    func deleteUserPreset(_ preset: EditPreset) {
        userPresets.removeAll { $0.id == preset.id }
        persistUserPresets()
    }

    private func loadUserPresets() {
        guard let data = UserDefaults.phosphor.data(forKey: Self.userPresetsKey),
              let decoded = try? JSONDecoder().decode([EditPreset].self, from: data)
        else { return }
        userPresets = decoded
    }

    private func persistUserPresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.phosphor.set(data, forKey: Self.userPresetsKey)
        }
    }

    // MARK: - Auto-enhance (vImage histogram heuristics)

    func autoEnhance() async {
        guard let image = originalImage,
              let stats = await Self.histogramStats(image) else { return }
        var adj = EditAdjustments()
        // Mean luminance → exposure correction toward 0.5.
        let meanL = stats.meanLuminance
        adj.exposure = max(-1.5, min(1.5, (0.5 - meanL) * 1.8))
        // Highlight clipping → pull highlights.
        if stats.highlightClip > 0.02 { adj.highlights = -0.4 }
        // Shadow clipping → lift shadows.
        if stats.shadowClip > 0.02 { adj.shadows = 0.4 }
        // Low colour variance → boost vibrance.
        if stats.colorVariance < 0.02 { adj.vibrance = 0.25 }
        updateAdjustments(adj)
    }

    // MARK: - Export

    func exportEdited(asset: ImmichAsset) async -> UIImage? {
        guard let original = originalImage else { return nil }
        return await Self.applyPipeline(to: original, adj: adjustments, finalCrop: true)
    }

    func saveToImmich(image: UIImage, originalAsset: ImmichAsset) async -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return false }
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            _ = try await ImmichAPI.shared.uploadAsset(
                data: data,
                deviceAssetId: "edit-\(UUID().uuidString)",
                deviceId: "phosphor-editor",
                fileName: "Edited-\((originalAsset.originalFileName as NSString).deletingPathExtension)-\(stamp).jpg",
                fileCreatedAt: Date(),
                fileModifiedAt: Date()
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Pipeline (Task.detached, GPU)

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated static func applyPipeline(
        to image: UIImage,
        adj: EditAdjustments,
        finalCrop: Bool
    ) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return image }
            var ci = CIImage(cgImage: cg)
            let fullExtent = ci.extent

            // 1. Exposure (first — before contrast/saturation amplify clipping)
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = ci
            exposure.ev = Float(adj.exposure)
            ci = exposure.outputImage ?? ci

            // 2. Brightness / contrast / saturation
            let controls = CIFilter.colorControls()
            controls.inputImage = ci
            controls.brightness = Float(adj.brightness)
            controls.contrast = Float(adj.contrast)
            controls.saturation = Float(adj.saturation)
            ci = controls.outputImage ?? ci

            // 3. Vibrance
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = ci
            vibrance.amount = Float(adj.vibrance)
            ci = vibrance.outputImage ?? ci

            // 4. Temperature & tint
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = ci
            temp.neutral = CIVector(x: adj.warmth, y: adj.tint)
            temp.targetNeutral = CIVector(x: 6500, y: 0)
            ci = temp.outputImage ?? ci

            // 5. Highlights & shadows
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = ci
            hs.highlightAmount = Float(1 + adj.highlights)
            hs.shadowAmount = Float(adj.shadows)
            ci = hs.outputImage ?? ci

            // 6. Blacks / whites via CIColorMatrix (bias for blacks, scale for whites)
            let cm = CIFilter.colorMatrix()
            cm.inputImage = ci
            let whiteScale = Float(1 + adj.whites)
            let blackBias = Float(adj.blacks)
            cm.rVector = CIVector(x: CGFloat(whiteScale), y: 0, z: 0, w: 0)
            cm.gVector = CIVector(x: 0, y: CGFloat(whiteScale), z: 0, w: 0)
            cm.bVector = CIVector(x: 0, y: 0, z: CGFloat(whiteScale), w: 0)
            cm.biasVector = CIVector(x: CGFloat(blackBias), y: CGFloat(blackBias), z: CGFloat(blackBias), w: 0)
            ci = cm.outputImage ?? ci

            // 7. Tone curve — CIVector(x:y:) per point, NOT NSValue.
            if adj.toneCurve.count == 5 {
                let tc = CIFilter.toneCurve()
                tc.inputImage = ci
                tc.point0 = CGPoint(x: adj.toneCurve[0].x, y: adj.toneCurve[0].y)
                tc.point1 = CGPoint(x: adj.toneCurve[1].x, y: adj.toneCurve[1].y)
                tc.point2 = CGPoint(x: adj.toneCurve[2].x, y: adj.toneCurve[2].y)
                tc.point3 = CGPoint(x: adj.toneCurve[3].x, y: adj.toneCurve[3].y)
                tc.point4 = CGPoint(x: adj.toneCurve[4].x, y: adj.toneCurve[4].y)
                ci = tc.outputImage ?? ci
            }

            // 8. HSL custom kernel
            if adj.hsl.contains(where: { $0.hue != 0 || $0.sat != 0 || $0.lum != 0 }) {
                let hslFilter = HSLFilter()
                hslFilter.inputImage = ci
                var packed: [Float] = []
                for ch in adj.hsl {
                    packed.append(Float(ch.hue))
                    packed.append(Float(ch.sat))
                    packed.append(Float(ch.lum))
                }
                hslFilter.hslValues = packed
                ci = hslFilter.outputImage ?? ci
            }

            // 9. Sharpen
            if adj.sharpness > 0 {
                let sharpen = CIFilter.unsharpMask()
                sharpen.inputImage = ci
                sharpen.radius = 2.5
                sharpen.intensity = Float(adj.sharpness)
                ci = sharpen.outputImage ?? ci
            }

            // 10. Noise reduction
            if adj.noiseReduction > 0 {
                let nr = CIFilter.noiseReduction()
                nr.inputImage = ci
                nr.noiseLevel = Float(adj.noiseReduction * 0.1)
                nr.sharpness = 0.4
                ci = nr.outputImage ?? ci
            }

            // 11. Vignette
            if adj.vignette != 0 {
                let vig = CIFilter.vignette()
                vig.inputImage = ci
                vig.intensity = Float(adj.vignette)
                vig.radius = 1.0
                ci = vig.outputImage ?? ci
            }

            // 12. Grain
            if adj.grain > 0 {
                let noise = CIFilter.randomGenerator()
                if let noiseImg = noise.outputImage?.cropped(to: ci.extent) {
                    let gray = CIFilter.colorMatrix()
                    gray.inputImage = noiseImg
                    let g = CGFloat(adj.grain)
                    gray.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
                    gray.gVector = CIVector(x: g, y: 0, z: 0, w: 0)
                    gray.bVector = CIVector(x: g, y: 0, z: 0, w: 0)
                    gray.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(adj.grain) * 0.4)
                    if let grainLayer = gray.outputImage {
                        ci = grainLayer.composited(over: ci)
                    }
                }
            }

            // 13. Fade (matte — lift blacks)
            if adj.fade > 0 {
                let fadeM = CIFilter.colorMatrix()
                fadeM.inputImage = ci
                let lift = CGFloat(adj.fade * 0.3)
                fadeM.biasVector = CIVector(x: lift, y: lift, z: lift, w: 0)
                ci = fadeM.outputImage ?? ci
            }

            // 14. Straighten + crop (last — tonal work was on uncropped data)
            if adj.straightenAngle != 0 {
                let radians = adj.straightenAngle * .pi / 180
                let center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
                ci = ci
                    .transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
                    .transformed(by: CGAffineTransform(rotationAngle: -radians))
                    .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            }
            if finalCrop, adj.cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
                let e = fullExtent
                let cropPx = CGRect(
                    x: e.minX + adj.cropRect.minX * e.width,
                    y: e.minY + (1 - adj.cropRect.maxY) * e.height,
                    width: adj.cropRect.width * e.width,
                    height: adj.cropRect.height * e.height
                )
                ci = ci.cropped(to: cropPx)
            }

            guard let outCG = await context.createCGImage(ci, from: ci.extent) else { return image }
            return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
        }.value
    }

    // MARK: - Helpers

    nonisolated static func lerp(_ a: EditAdjustments, _ b: EditAdjustments, t: Double) -> EditAdjustments {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var r = EditAdjustments()
        r.exposure = l(a.exposure, b.exposure)
        r.brightness = l(a.brightness, b.brightness)
        r.contrast = l(a.contrast, b.contrast)
        r.saturation = l(a.saturation, b.saturation)
        r.vibrance = l(a.vibrance, b.vibrance)
        r.warmth = l(a.warmth, b.warmth)
        r.tint = l(a.tint, b.tint)
        r.highlights = l(a.highlights, b.highlights)
        r.shadows = l(a.shadows, b.shadows)
        r.blacks = l(a.blacks, b.blacks)
        r.whites = l(a.whites, b.whites)
        r.sharpness = l(a.sharpness, b.sharpness)
        r.noiseReduction = l(a.noiseReduction, b.noiseReduction)
        r.vignette = l(a.vignette, b.vignette)
        r.grain = l(a.grain, b.grain)
        r.fade = l(a.fade, b.fade)

        // Tone curve: lerp every control point's x and y separately.
        if a.toneCurve.count == b.toneCurve.count {
            r.toneCurve = zip(a.toneCurve, b.toneCurve).map { pa, pb in
                CGPoint(x: pa.x + (pb.x - pa.x) * t,
                        y: pa.y + (pb.y - pa.y) * t)
            }
        } else {
            r.toneCurve = b.toneCurve
        }

        // HSL: lerp each channel's hue/sat/lum separately.
        if a.hsl.count == b.hsl.count {
            r.hsl = zip(a.hsl, b.hsl).map { ca, cb in
                HSLAdjustment(hue: l(ca.hue, cb.hue),
                              sat: l(ca.sat, cb.sat),
                              lum: l(ca.lum, cb.lum))
            }
        } else {
            r.hsl = b.hsl
        }

        // Crop / straighten are geometric, not tonal — a preset's intensity
        // slider never reshapes them; keep the base composition.
        r.cropRect = a.cropRect
        r.straightenAngle = a.straightenAngle
        return r
    }

    nonisolated private static func downsample(_ image: UIImage, longest: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longest, longest > 0 else { return image }
        let scale = longest / maxSide
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    struct HistStats { let meanLuminance: Double; let highlightClip: Double; let shadowClip: Double; let colorVariance: Double }

    nonisolated private static func histogramStats(_ image: UIImage) async -> HistStats? {
        await Task.detached(priority: .utility) {
            guard let cg = image.cgImage else { return nil }
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

            var sumL = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0
            var highClip = 0, lowClip = 0
            let n = w * h
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Double(px[i]) / 255, g = Double(px[i+1]) / 255, b = Double(px[i+2]) / 255
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                sumL += l; sumR += r; sumG += g; sumB += b
                if l > 0.95 { highClip += 1 }
                if l < 0.05 { lowClip += 1 }
            }
            let meanL = sumL / Double(n)
            let mR = sumR / Double(n), mG = sumG / Double(n), mB = sumB / Double(n)
            let chanMean = (mR + mG + mB) / 3
            let variance = (pow(mR - chanMean, 2) + pow(mG - chanMean, 2) + pow(mB - chanMean, 2)) / 3
            return HistStats(
                meanLuminance: meanL,
                highlightClip: Double(highClip) / Double(n),
                shadowClip: Double(lowClip) / Double(n),
                colorVariance: variance
            )
        }.value
    }
}
