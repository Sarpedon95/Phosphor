import SwiftUI

/// Inline crop panel embedded in `EditingToolbar` (not a sheet). Edits the
/// view model's `adjustments.cropRect` + `straightenAngle` directly.
struct CropEditView: View {
    @ObservedObject var viewModel: EditingViewModel
    let onDone: () -> Void

    @State private var cropRect: CGRect
    @State private var angle: Double
    @State private var lockedAspect: CGFloat?
    @State private var dragStart: CGRect?

    private let aspects: [(String, CGFloat?)] = [
        ("Free", nil), ("1:1", 1), ("4:3", 4.0/3.0),
        ("16:9", 16.0/9.0), ("3:2", 3.0/2.0)
    ]

    init(viewModel: EditingViewModel, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDone = onDone
        _cropRect = State(initialValue: viewModel.adjustments.cropRect)
        _angle = State(initialValue: viewModel.adjustments.straightenAngle)
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            preview
            aspectRow
            straightenRow
            actionRow
        }
        .padding(Spacing.md)
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if let img = viewModel.previewImage ?? viewModel.originalImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(angle))
                    let r = pixelRect(in: geo.size)
                    Rectangle()
                        .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .gesture(dragGesture(in: geo.size))
                    // Rule-of-thirds overlay while interacting.
                    thirdsGrid(in: r)
                }
            }
        }
        .frame(height: 240)
    }

    private func thirdsGrid(in r: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY))
                p.addLine(to: CGPoint(x: x, y: r.maxY))
                let y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: r.minX, y: y))
                p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
    }

    private var aspectRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(aspects, id: \.0) { entry in
                    Button {
                        lockedAspect = entry.1
                        applyAspect(entry.1)
                    } label: {
                        Text(entry.0)
                            .font(Typography.caption)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(
                                lockedAspect == entry.1 ? Color.phosphorAccent : Color.phosphorSurface,
                                in: Capsule()
                            )
                            .foregroundStyle(lockedAspect == entry.1 ? .black : .phosphorAccent)
                    }
                }
                Button {
                    angle = (angle == 0) ? 90 : angle  // 90° rotate via straighten clamp
                    let r = cropRect
                    cropRect = CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
                } label: {
                    Image(systemName: "rotate.right")
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.phosphorSurface, in: Capsule())
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
    }

    private var straightenRow: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Straighten").font(Typography.caption).foregroundStyle(.phosphorSecondary)
                Spacer()
                Text("\(Int(angle))°").font(Typography.caption).foregroundStyle(.phosphorAccent)
                Button {
                    Task { await autoStraighten() }
                } label: {
                    Image(systemName: "wand.and.stars").foregroundStyle(.phosphorAccent)
                }
                .accessibilityLabel("Auto-straighten")
            }
            Slider(value: $angle, in: -45...45, step: 0.5)
                .tint(.phosphorAccent)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Reset") {
                cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                angle = 0
                lockedAspect = nil
            }
            .foregroundStyle(.phosphorSecondary)
            Spacer()
            Button("Done") {
                var adj = viewModel.adjustments
                adj.cropRect = cropRect
                adj.straightenAngle = angle
                viewModel.updateAdjustments(adj)
                onDone()
            }
            .foregroundStyle(.phosphorAccent)
        }
    }

    // MARK: - Helpers

    private func pixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: cropRect.minX * size.width,
            y: cropRect.minY * size.height,
            width: cropRect.width * size.width,
            height: cropRect.height * size.height
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var r = start
                r.origin.x = max(0, min(1 - r.width, start.minX + dx))
                r.origin.y = max(0, min(1 - r.height, start.minY + dy))
                cropRect = r
            }
            .onEnded { _ in dragStart = nil }
    }

    private func applyAspect(_ aspect: CGFloat?) {
        guard let aspect else { return }
        // Fit the largest centered rect of `aspect` inside the image.
        let cx = cropRect.midX, cy = cropRect.midY
        var w = cropRect.width
        var h = w / aspect
        if h > 1 { h = 1; w = h * aspect }
        let r = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
        cropRect = CGRect(
            x: max(0, min(1 - w, r.minX)),
            y: max(0, min(1 - h, r.minY)),
            width: w, height: h
        )
    }

    private func autoStraighten() async {
        guard let img = viewModel.originalImage else { return }
        let degrees = await PhotoIntelligenceEngine.shared.detectHorizon(image: img)
        angle = max(-45, min(45, degrees))
    }
}
