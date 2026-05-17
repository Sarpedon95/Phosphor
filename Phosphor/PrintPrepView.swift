import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Photos

struct PrintSize: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let widthInches: Double
    let heightInches: Double

    var aspect: CGFloat { CGFloat(widthInches / heightInches) }

    static let presets: [PrintSize] = [
        .init(name: "4 × 6 in", widthInches: 6, heightInches: 4),
        .init(name: "5 × 7 in", widthInches: 7, heightInches: 5),
        .init(name: "8 × 10 in", widthInches: 10, heightInches: 8),
        .init(name: "A4", widthInches: 11.69, heightInches: 8.27),
        .init(name: "Square 12 × 12 in", widthInches: 12, heightInches: 12)
    ]
}

struct PrintPrepView: View {
    let asset: ImmichAsset
    @Environment(\.dismiss) private var dismiss

    @State private var selected: PrintSize = PrintSize.presets[0]
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var useCustom = false
    @State private var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var preview: UIImage?
    @State private var isExporting = false
    @State private var statusText: String?

    private let dpi: Double = 300

    private var activeSize: PrintSize {
        if useCustom,
           let w = Double(customWidth), let h = Double(customHeight),
           w > 0, h > 0 {
            return PrintSize(name: "Custom", widthInches: w, heightInches: h)
        }
        return selected
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        previewArea
                        sizePicker
                        dpiVerdict
                        exportButton
                        if let statusText {
                            Text(statusText)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                        }
                    }
                    .padding(Spacing.md)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Prepare for Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.phosphorAccent)
                }
            }
        }
        .task(id: activeSize) { await recomputeCrop() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.medium)
                .fill(Color.phosphorSurface)
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
            } else {
                ProgressView().tint(.phosphorAccent)
            }
        }
        .aspectRatio(activeSize.aspect, contentMode: .fit)
        .frame(maxHeight: 280)
    }

    private var sizePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Print Size").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(PrintSize.presets) { size in
                        Button {
                            useCustom = false
                            selected = size
                        } label: {
                            Text(size.name)
                                .font(Typography.caption)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(
                                    (!useCustom && selected == size)
                                        ? Color.phosphorAccent : Color.phosphorSurface,
                                    in: Capsule()
                                )
                                .foregroundStyle(
                                    (!useCustom && selected == size) ? .black : .phosphorAccent
                                )
                        }
                    }
                    Button {
                        useCustom = true
                    } label: {
                        Text("Custom")
                            .font(Typography.caption)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(useCustom ? Color.phosphorAccent : Color.phosphorSurface,
                                        in: Capsule())
                            .foregroundStyle(useCustom ? .black : .phosphorAccent)
                    }
                }
            }
            if useCustom {
                HStack {
                    TextField("Width in", text: $customWidth)
                        .keyboardType(.decimalPad)
                        .padding(Spacing.sm)
                        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
                    Text("×").foregroundStyle(.phosphorSecondary)
                    TextField("Height in", text: $customHeight)
                        .keyboardType(.decimalPad)
                        .padding(Spacing.sm)
                        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
                }
                .foregroundStyle(.phosphorAccent)
            }
        }
    }

    private var dpiVerdict: some View {
        let required = requiredMegapixels
        let have = photoMegapixels
        let ok = have >= required
        return HStack(spacing: Spacing.sm) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .phosphorSuccess : .phosphorDestructive)
            VStack(alignment: .leading, spacing: 2) {
                Text("300 DPI requires \(String(format: "%.1f", required)) MP")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorAccent)
                Text(have > 0
                     ? "Your photo has \(String(format: "%.1f", have)) MP"
                     : "Photo resolution unknown")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                if !ok && have > 0 {
                    Text("May appear soft when printed")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorDestructive)
                }
            }
            Spacer()
        }
        .padding(Spacing.md)
        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }

    private var exportButton: some View {
        Button {
            Task { await export() }
        } label: {
            HStack {
                if isExporting {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(isExporting ? "Exporting…" : "Export for Print")
            }
            .font(Typography.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(Color.phosphorAccent, in: Capsule())
        }
        .disabled(isExporting)
    }

    // MARK: - Computed

    private var photoMegapixels: Double {
        guard let w = asset.exifInfo?.exifImageWidth,
              let h = asset.exifInfo?.exifImageHeight,
              w > 0, h > 0 else { return 0 }
        return Double(w) * Double(h) / 1_000_000
    }

    private var requiredMegapixels: Double {
        let wPx = activeSize.widthInches * dpi
        let hPx = activeSize.heightInches * dpi
        return wPx * hPx / 1_000_000
    }

    // MARK: - Actions

    private func recomputeCrop() async {
        preview = nil
        guard let image = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
        else { return }
        let crop = await IntelligentCropEngine.shared.smartCrop(
            assetId: asset.id, image: image, targetAspect: activeSize.aspect
        )
        cropRect = crop
        preview = cropped(image, to: crop)
    }

    private func cropped(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let px = CGRect(x: rect.minX * w, y: rect.minY * h,
                        width: rect.width * w, height: rect.height * h).integral
        guard px.width >= 1, px.height >= 1, let out = cg.cropping(to: px) else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    private func export() async {
        isExporting = true
        statusText = nil
        defer { isExporting = false }

        do {
            let data = try await ImmichAPI.shared.downloadOriginal(assetId: asset.id)
            guard let full = UIImage(data: data),
                  let croppedFull = cropped(full, to: cropRect) else {
                statusText = "Couldn't process the photo."
                return
            }
            // Resize to exact print pixel size at 300 DPI.
            let targetPx = CGSize(
                width: activeSize.widthInches * dpi,
                height: activeSize.heightInches * dpi
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: targetPx, format: format)
            let resized = renderer.image { _ in
                croppedFull.draw(in: CGRect(origin: .zero, size: targetPx))
            }
            // Save with embedded DPI metadata.
            if let saved = saveWithDPI(resized, dpi: dpi) {
                let status = await BackupManager.requestPhotoLibraryAccess()
                if status == .authorized || status == .limited {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAssetFromImage(saved)
                        }
                        statusText = "Saved to Camera Roll at \(Int(dpi)) DPI."
                        HapticManager.notification(.success)
                    } catch {
                        statusText = "Failed to save image."
                        HapticManager.notification(.error)
                    }
                } else {
                    statusText = "Photo library access denied."
                }
            } else {
                statusText = "Export failed."
            }
        } catch {
            statusText = "Download failed: \(error.localizedDescription)"
            HapticManager.notification(.error)
        }
    }

    /// Re-encodes the image as JPEG with `kCGImagePropertyDPIWidth/Height` set,
    /// then decodes it back so the in-memory UIImage carries the DPI when the
    /// system writes it to the photo library.
    private func saveWithDPI(_ image: UIImage, dpi: Double) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return UIImage(data: data as Data)
    }
}
