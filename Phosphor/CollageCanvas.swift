import SwiftUI

/// Interactive editing surface. Mounts inside a `GeometryReader` so cell
/// frames can convert from normalized to pixel coordinates at the actual
/// view size.
struct CollageCanvas: View {
    @ObservedObject var viewModel: CollageViewModel
    @State private var selectedCellID: CollageCell.ID?
    @State private var cropEditingCell: CollageCell?
    @State private var pinchStartFrame: CGRect?
    @State private var dragStartFrame: CGRect?
    @State private var replacePicker: CollageCell?

    var body: some View {
        VStack(spacing: 0) {
            canvas
            layoutSwitcher
        }
        .background(viewModel.backgroundColor)
        .fullScreenCover(item: $cropEditingCell) { cell in
            CellCropEditor(viewModel: viewModel, cell: cell)
        }
        .sheet(item: $replacePicker) { cell in
            CollageAssetPicker { picked in
                Task {
                    await viewModel.replaceAsset(in: cell, with: picked)
                }
                replacePicker = nil
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.black)
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        GeometryReader { geo in
            let canvasSize = sizedToFit(aspect: viewModel.canvasAspect, in: geo.size)
            ZStack {
                viewModel.backgroundColor
                if let spec = viewModel.spec {
                    ZStack {
                        ForEach(spec.cells) { cell in
                            cellView(cell, canvasSize: canvasSize)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                } else if viewModel.isGenerating {
                    ProgressView().tint(.phosphorAccent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedCellID = nil
            }
        }
        .padding(Spacing.md)
    }

    @ViewBuilder
    private func cellView(_ cell: CollageCell, canvasSize: CGSize) -> some View {
        CollageCellView(
            cell: cell,
            canvasSize: canvasSize,
            image: viewModel.imagesByAsset[cell.assetId],
            blendMode: viewModel.blendMode,
            gapWidth: viewModel.gapWidth,
            cornerRadius: viewModel.cornerRadius,
            isSelected: cell.id == selectedCellID
        )
        .onTapGesture { selectedCellID = cell.id }
        .onTapGesture(count: 2) { cropEditingCell = cell }
        .contextMenu {
            Button {
                replacePicker = cell
            } label: {
                Label("Replace Photo", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) {
                Task { await viewModel.removeCell(cell) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                rotate(cell)
            } label: {
                Label("Rotate 90°", systemImage: "rotate.right")
            }
        }
        .gesture(freeformGestures(for: cell, canvasSize: canvasSize))
        .accessibilityLabel(accessibilityLabel(for: cell))
    }

    // MARK: - Gestures (freeform only)

    private func freeformGestures(for cell: CollageCell, canvasSize: CGSize) -> some Gesture {
        // Drag + pinch only when freeform; other layouts are algorithmic and
        // shouldn't be hand-edited.
        let isFreeform: Bool = {
            if case .freeform = viewModel.currentLayout { return true }
            return false
        }()
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isFreeform else { return }
                if dragStartFrame == nil { dragStartFrame = cell.frame }
                guard let start = dragStartFrame else { return }
                let dx = value.translation.width / canvasSize.width
                let dy = value.translation.height / canvasSize.height
                var newFrame = start
                newFrame.origin.x = max(0, min(1 - newFrame.width, start.minX + dx))
                newFrame.origin.y = max(0, min(1 - newFrame.height, start.minY + dy))
                var updated = cell
                updated.frame = newFrame
                viewModel.updateCell(updated)
            }
            .onEnded { _ in dragStartFrame = nil }
            .simultaneously(with:
                MagnifyGesture(minimumScaleDelta: 0.05)
                    .onChanged { value in
                        guard isFreeform else { return }
                        if pinchStartFrame == nil { pinchStartFrame = cell.frame }
                        guard let start = pinchStartFrame else { return }
                        let scale = max(0.1, min(2.0, CGFloat(value.magnification)))
                        let newW = max(0.05, min(1, start.width * scale))
                        let newH = max(0.05, min(1, start.height * scale))
                        var frame = CGRect(
                            x: start.midX - newW / 2,
                            y: start.midY - newH / 2,
                            width: newW,
                            height: newH
                        )
                        frame.origin.x = max(0, min(1 - frame.width, frame.minX))
                        frame.origin.y = max(0, min(1 - frame.height, frame.minY))
                        var updated = cell
                        updated.frame = frame
                        viewModel.updateCell(updated)
                    }
                    .onEnded { _ in pinchStartFrame = nil }
            )
    }

    private func rotate(_ cell: CollageCell) {
        var updated = cell
        updated.rotation = (cell.rotation + 90).truncatingRemainder(dividingBy: 360)
        viewModel.updateCell(updated)
    }

    private func accessibilityLabel(for cell: CollageCell) -> String {
        "Cell \(cell.assetId). Double-tap to crop, long-press for more actions."
    }

    // MARK: - Layout switcher

    private var layoutSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(CollageLayout.presetCatalog, id: \.self) { layout in
                    Button {
                        HapticManager.selection()
                        Task { await viewModel.switchLayout(layout) }
                    } label: {
                        VStack(spacing: Spacing.xs) {
                            Image(systemName: layout.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    Color.phosphorSurface,
                                    in: RoundedRectangle(cornerRadius: CornerRadius.small)
                                )
                                .overlay {
                                    if isCurrent(layout) {
                                        RoundedRectangle(cornerRadius: CornerRadius.small)
                                            .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                                    }
                                }
                            Text(layout.label)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.phosphorAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Layout: \(layout.label)")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
        .background(Color.phosphorBackground)
    }

    private func isCurrent(_ layout: CollageLayout) -> Bool {
        // Compare by case identity (ignore associated-value drift between
        // catalog defaults and active state).
        switch (layout, viewModel.currentLayout) {
        case (.justified, .justified),
             (.quilt, .quilt),
             (.mosaic, .mosaic),
             (.magazine, .magazine),
             (.horizontalStrip, .horizontalStrip),
             (.verticalStrip, .verticalStrip),
             (.freeform, .freeform),
             (.diagonal, .diagonal),
             (.cascade, .cascade):
            return true
        default:
            return false
        }
    }

    // MARK: - Sizing helper

    /// Fits a rect of the given aspect into the available size.
    private func sizedToFit(aspect: CGFloat, in available: CGSize) -> CGSize {
        let usable = CGSize(
            width: max(1, available.width - Spacing.lg * 2),
            height: max(1, available.height - Spacing.lg * 2)
        )
        let availAspect = usable.width / max(1, usable.height)
        if aspect >= availAspect {
            return CGSize(width: usable.width, height: usable.width / aspect)
        } else {
            return CGSize(width: usable.height * aspect, height: usable.height)
        }
    }
}

// MARK: - Cell crop editor

/// Double-tapping a cell opens this sheet. Shows the full source image with a
/// draggable crop rect; saving updates `cell.cropRect` on the spec.
struct CellCropEditor: View {
    @ObservedObject var viewModel: CollageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftCrop: CGRect
    @State private var dragStart: CGRect?
    @State private var pinchStart: CGRect?

    private let cell: CollageCell

    init(viewModel: CollageViewModel, cell: CollageCell) {
        self.viewModel = viewModel
        self.cell = cell
        _draftCrop = State(initialValue: cell.cropRect)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                if let img = viewModel.imagesByAsset[cell.assetId] {
                    GeometryReader { geo in
                        let displayed = fittedImageRect(image: img, in: geo.size)
                        ZStack {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .opacity(0.45)
                            // Crop window
                            let rect = pixelRect(draftCrop, in: displayed)
                            CropRectangleOverlay(rect: rect, container: displayed)
                                .gesture(dragGesture(in: displayed))
                                .gesture(pinchGesture(in: displayed))
                        }
                    }
                    .padding(Spacing.md)
                } else {
                    ProgressView().tint(.phosphorAccent)
                }
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button("Reset") {
                            Task {
                                guard let img = viewModel.imagesByAsset[cell.assetId] else { return }
                                let aspect = max(0.0001, cell.frame.width / cell.frame.height)
                                let smart = await IntelligentCropEngine.shared.smartCrop(
                                    assetId: cell.assetId, image: img, targetAspect: aspect
                                )
                                draftCrop = smart
                            }
                        }
                        .foregroundStyle(.phosphorSecondary)
                        Button("Done") {
                            var updated = cell
                            updated.cropRect = draftCrop
                            viewModel.updateCell(updated)
                            dismiss()
                        }
                        .foregroundStyle(.phosphorAccent)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func fittedImageRect(image: UIImage, in available: CGSize) -> CGRect {
        let imgAspect = image.size.width / max(1, image.size.height)
        let availAspect = available.width / max(1, available.height)
        if imgAspect >= availAspect {
            let w = available.width
            let h = w / imgAspect
            return CGRect(x: 0, y: (available.height - h) / 2, width: w, height: h)
        } else {
            let h = available.height
            let w = h * imgAspect
            return CGRect(x: (available.width - w) / 2, y: 0, width: w, height: h)
        }
    }

    private func pixelRect(_ normalized: CGRect, in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + normalized.minX * container.width,
            y: container.minY + normalized.minY * container.height,
            width: normalized.width * container.width,
            height: normalized.height * container.height
        )
    }

    private func dragGesture(in container: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = draftCrop }
                guard let start = dragStart else { return }
                let dx = value.translation.width / container.width
                let dy = value.translation.height / container.height
                var rect = start
                rect.origin.x = max(0, min(1 - rect.width, start.minX + dx))
                rect.origin.y = max(0, min(1 - rect.height, start.minY + dy))
                draftCrop = rect
            }
            .onEnded { _ in dragStart = nil }
    }

    private func pinchGesture(in container: CGRect) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onChanged { value in
                if pinchStart == nil { pinchStart = draftCrop }
                guard let start = pinchStart else { return }
                let scale = max(0.2, min(2.0, CGFloat(value.magnification)))
                let newW = max(0.05, min(1, start.width / scale))
                let newH = max(0.05, min(1, start.height / scale))
                var rect = CGRect(
                    x: start.midX - newW / 2,
                    y: start.midY - newH / 2,
                    width: newW,
                    height: newH
                )
                rect.origin.x = max(0, min(1 - rect.width, rect.minX))
                rect.origin.y = max(0, min(1 - rect.height, rect.minY))
                draftCrop = rect
            }
            .onEnded { _ in pinchStart = nil }
    }
}

private struct CropRectangleOverlay: View {
    let rect: CGRect
    let container: CGRect

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            // Punch a clear hole using a path that subtracts the rect.
            Path { p in
                p.addRect(container)
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.7), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: container.width, height: container.height)
        .position(x: container.midX, y: container.midY)
    }
}

// MARK: - Asset picker for replace

/// Lightweight picker presented when the user taps "Replace Photo".
struct CollageAssetPicker: View {
    let onPick: (ImmichAsset) -> Void
    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Choose Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && assets.isEmpty {
            ProgressView().tint(.phosphorAccent)
        } else if assets.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "photo")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No photos available")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorAccent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(assets) { asset in
                        AssetGridCell(asset: asset)
                            .onTapGesture { onPick(asset) }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchTimeline(page: 1, pageSize: 200)
        } catch {
            assets = []
        }
    }
}
