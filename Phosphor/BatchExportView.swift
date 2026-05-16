import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct BatchExportView: View {
    let assets: [ImmichAsset]
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", png = "PNG", heic = "HEIC"
        var id: String { rawValue }
        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            }
        }
        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            }
        }
    }

    enum SizeOption: String, CaseIterable, Identifiable {
        case original = "Original"
        case px2048 = "2048px"
        case px1080 = "1080px"
        var id: String { rawValue }
        var longest: CGFloat? {
            switch self {
            case .original: return nil
            case .px2048: return 2048
            case .px1080: return 1080
            }
        }
    }

    enum Destination: String, CaseIterable, Identifiable {
        case cameraRoll = "Camera Roll"
        case files = "Files"
        case share = "Share"
        var id: String { rawValue }
    }

    @State private var format: Format = .jpeg
    @State private var jpegQuality: Double = 85
    @State private var size: SizeOption = .original
    @State private var destination: Destination = .cameraRoll
    @State private var isExporting = false
    @State private var progressText = ""
    @State private var exportedURLs: [URL] = []
    @State private var showFilesPicker = false
    @State private var showShare = false
    @State private var pendingCleanupDir: URL?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                Form {
                    Section("Format") {
                        Picker("Format", selection: $format) {
                            ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.phosphorSurface)
                        if format == .jpeg {
                            VStack(alignment: .leading) {
                                Text("Quality \(Int(jpegQuality))%")
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                                Slider(value: $jpegQuality, in: 60...100, step: 1)
                                    .tint(.phosphorAccent)
                            }
                            .listRowBackground(Color.phosphorSurface)
                        }
                    }
                    Section("Size") {
                        Picker("Size", selection: $size) {
                            ForEach(SizeOption.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.phosphorSurface)
                    }
                    Section("Destination") {
                        Picker("Destination", selection: $destination) {
                            ForEach(Destination.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.phosphorSurface)
                    }
                    Section {
                        if isExporting {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                ProgressView()
                                    .tint(.phosphorAccent)
                                Text(progressText)
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                                Button("Cancel") {
                                    exportTask?.cancel()
                                }
                                .foregroundStyle(.phosphorDestructive)
                            }
                            .listRowBackground(Color.phosphorSurface)
                        } else {
                            Button {
                                exportTask = Task { await runExport() }
                            } label: {
                                Text("Export \(assets.count) Photos")
                                    .font(Typography.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .listRowBackground(Color.phosphorAccent)
                            .foregroundStyle(.black)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        exportTask?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .sheet(isPresented: $showFilesPicker, onDismiss: cleanupPending) {
            DocumentExportPicker(urls: exportedURLs)
        }
        .sheet(isPresented: $showShare, onDismiss: cleanupPending) {
            ActivityShareSheet(items: exportedURLs)
        }
        .preferredColorScheme(.dark)
    }

    private func cleanupPending() {
        if let dir = pendingCleanupDir {
            try? FileManager.default.removeItem(at: dir)
            pendingCleanupDir = nil
        }
    }

    // MARK: - Export

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhosphorExport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        var urls: [URL] = []

        for (idx, asset) in assets.enumerated() {
            if Task.isCancelled { break }
            progressText = "Exporting \(idx + 1) of \(assets.count)…"
            guard let data = try? await ImmichAPI.shared.downloadOriginal(assetId: asset.id),
                  var image = UIImage(data: data) else { continue }

            if let longest = size.longest {
                image = resize(image, longest: longest)
            }
            guard let encoded = encode(image) else { continue }
            let name = "\((asset.originalFileName as NSString).deletingPathExtension).\(format.fileExtension)"
            let fileURL = tmpDir.appendingPathComponent(name)
            try? encoded.write(to: fileURL)
            urls.append(fileURL)
        }

        exportedURLs = urls
        guard !urls.isEmpty else {
            progressText = Task.isCancelled ? "Export cancelled." : "Nothing exported."
            cleanupTempDir(tmpDir)   // nothing to hand off — remove immediately
            return
        }

        switch destination {
        case .cameraRoll:
            await saveToCameraRoll(urls)
            // Files are now in the photo library; the temp copies are dead.
            cleanupTempDir(tmpDir)
        case .files:
            // The document picker copies on export; clean up when it dismisses.
            pendingCleanupDir = tmpDir
            showFilesPicker = true
        case .share:
            // The activity sheet reads the files while presented; clean up on
            // dismiss.
            pendingCleanupDir = tmpDir
            showShare = true
        }
    }

    private func cleanupTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func resize(_ image: UIImage, longest: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longest else { return image }
        let scale = longest / maxSide
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func encode(_ image: UIImage) -> Data? {
        switch format {
        case .jpeg:
            return image.jpegData(compressionQuality: jpegQuality / 100)
        case .png:
            return image.pngData()
        case .heic:
            guard let cg = image.cgImage else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                data, UTType.heic.identifier as CFString, 1, nil
            ) else { return image.jpegData(compressionQuality: 0.9) }
            CGImageDestinationAddImage(dest, cg, [
                kCGImageDestinationLossyCompressionQuality: 0.9
            ] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                return image.jpegData(compressionQuality: 0.9)
            }
            return data as Data
        }
    }

    private func saveToCameraRoll(_ urls: [URL]) async {
        let status = await BackupManager.requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else {
            progressText = "Photo library access denied."
            return
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }
        progressText = "Saved \(urls.count) to Camera Roll."
        HapticManager.notification(.success)
    }
}

// MARK: - UIKit bridges

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
