import SwiftUI
import UIKit
import Photos

@MainActor
final class CollageViewModel: ObservableObject {

    @Published private(set) var selectedAssets: [ImmichAsset]
    @Published private(set) var spec: CollageSpec?
    @Published private(set) var isGenerating = false
    @Published var renderProgress: Double = 0
    @Published var error: String?

    @Published var currentLayout: CollageLayout = .justified(targetRowHeight: 120)
    @Published var canvasAspect: CGFloat = 1.0
    @Published var gapWidth: CGFloat = 4
    @Published var blendMode: CollageBlendMode = .hardEdge
    @Published var backgroundColor: Color = .black
    @Published var cornerRadius: CGFloat = 0

    /// Loaded source UIImages keyed by Immich asset id. Used by both the
    /// layout engine (smart crop runs on these) and the cell views (live
    /// preview displays them).
    @Published private(set) var imagesByAsset: [String: UIImage] = [:]

    init(assets: [ImmichAsset]) {
        self.selectedAssets = assets
    }

    // MARK: - Generation

    /// Loads thumbnails and computes the initial spec. Subsequent layout
    /// changes call `switchLayout` which reuses the loaded images.
    func generate() async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }

        // Load preview-resolution images for layout maths (full res only at
        // export time — see CollageRenderer).
        await loadImages()
        await rebuildSpec()
    }

    func switchLayout(_ layout: CollageLayout) async {
        currentLayout = layout
        await rebuildSpec()
    }

    func replaceAsset(in cell: CollageCell, with asset: ImmichAsset) async {
        guard var spec = spec,
              let idx = spec.cells.firstIndex(where: { $0.id == cell.id })
        else { return }
        // Load the replacement image, then re-run smart crop for that cell only.
        let image = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
            ?? UIImage()
        imagesByAsset[asset.id] = image
        let targetAspect = max(0.0001, spec.cells[idx].frame.width / spec.cells[idx].frame.height)
        let crop = await IntelligentCropEngine.shared.smartCrop(
            assetId: asset.id, image: image, targetAspect: targetAspect
        )
        spec.cells[idx].assetId = asset.id
        spec.cells[idx].cropRect = crop
        spec.cells[idx].aspectRatio = CGFloat(image.size.width / max(1, image.size.height))
        self.spec = spec
        if !selectedAssets.contains(where: { $0.id == asset.id }) {
            selectedAssets.append(asset)
        }
    }

    func removeCell(_ cell: CollageCell) async {
        selectedAssets.removeAll { $0.id == cell.assetId }
        await rebuildSpec()
    }

    func updateCell(_ cell: CollageCell) {
        guard var spec = spec,
              let idx = spec.cells.firstIndex(where: { $0.id == cell.id })
        else { return }
        spec.cells[idx] = cell
        self.spec = spec
    }

    // MARK: - Export

    /// Renders at the requested quality and saves to Immich + camera roll as
    /// requested by the caller. Returns the rendered image so the caller
    /// (CollageExportView) can present it / share it.
    func renderForExport(quality: ExportQuality) async -> UIImage? {
        guard let spec else { return nil }
        renderProgress = 0
        let size = exportSize(for: spec, quality: quality)
        let image = await CollageRenderer.shared.render(
            spec: spec,
            outputSize: size
        ) { [weak self] done, total in
            Task { @MainActor in
                guard let self else { return }
                self.renderProgress = total == 0 ? 1 : Double(done) / Double(total)
            }
        }
        return image
    }

    /// Save to the user's camera roll. Returns success/failure.
    func saveToPhotos(_ image: UIImage) async -> Bool {
        let status = await BackupManager.requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    /// Persist the sidecar and record the local→uploaded mapping. The actual
    /// upload to Immich is done by the caller via `ImmichAPI.uploadAsset`.
    func writeSidecar(for image: UIImage, uploadedAssetId: String?) async {
        guard let spec else { return }
        guard let canvasPx = exportSize(for: spec, quality: .high) else { return }
        let cells: [SidecarCell] = spec.cells.map { cell in
            let canvasFrame = CGRect(
                x: cell.frame.minX * canvasPx.width,
                y: cell.frame.minY * canvasPx.height,
                width: cell.frame.width * canvasPx.width,
                height: cell.frame.height * canvasPx.height
            )
            return SidecarCell(
                assetId: cell.assetId,
                canvasFrame: canvasFrame,
                salientRegion: cell.cropRect,
                cropRect: cell.cropRect,
                originalSize: (imagesByAsset[cell.assetId]?.size ?? .zero)
            )
        }
        let sidecar = CollageSidecar(
            collageId: spec.id,
            createdAt: Date(),
            canvasSize: canvasPx,
            cells: cells
        )
        _ = CollageSidecarStore.save(sidecar)
        if let assetId = uploadedAssetId {
            CollageSidecarStore.recordUploadedAsset(assetId, for: spec.id)
        }
    }

    // MARK: - Internals

    private func loadImages() async {
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for asset in selectedAssets where imagesByAsset[asset.id] == nil {
                let id = asset.id
                group.addTask {
                    let img = await ImageLoader.shared.thumbnail(for: id, size: .preview)
                    return (id, img)
                }
            }
            for await (id, img) in group {
                if let img { imagesByAsset[id] = img }
            }
        }
    }

    private func rebuildSpec() async {
        let inputs: [CollageInput] = selectedAssets.compactMap { asset in
            guard let img = imagesByAsset[asset.id] else { return nil }
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            return CollageInput(assetId: asset.id, image: img, aspect: aspect)
        }
        guard !inputs.isEmpty else { spec = nil; return }
        let bgColor = CodableColor(backgroundColor)
        var produced = await CollageLayoutEngine.shared.generateLayout(
            assets: inputs,
            layout: currentLayout,
            canvasAspect: canvasAspect,
            gapWidth: gapWidth
        )
        produced.backgroundColor = bgColor
        produced.blendMode = blendMode
        produced.cornerRadius = cornerRadius
        spec = produced
    }

    private func exportSize(for spec: CollageSpec, quality: ExportQuality) -> CGSize? {
        guard let longest = quality.longestSide else { return nil }
        if spec.canvasAspect >= 1 {
            return CGSize(width: longest, height: longest / spec.canvasAspect)
        } else {
            return CGSize(width: longest * spec.canvasAspect, height: longest)
        }
    }
}
