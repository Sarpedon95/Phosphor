import SwiftUI

/// Full-screen crop / straighten editor. Edits a local draft, then writes
/// through the `cropRect` and `angle` bindings on "Done". Cancel discards.
struct CropEditView: View {
    let asset: ImmichAsset
    @Binding var cropRect: CGRect
    @Binding var angle: Double
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var draftRect: CGRect
    @State private var draftAngle: Double
    @State private var lockedAspect: CGFloat?
    @State private var dragStart: CGRect?

    private let aspects: [(String, CGFloat?)] = [
        ("Free", nil), ("1:1", 1), ("4:3", 4.0/3.0),
        ("16:9", 16.0/9.0), ("3:2", 3.0/2.0)
    ]

    init(asset: ImmichAsset, cropRect: Binding<CGRect>, angle: Binding<Double>) {
        self.asset = asset
        self._cropRect = cropRect
        self._angle = angle
        self._draftRect = State(initialValue: cropRect.wrappedValue)
        self._draftAngle = State(initialValue: angle.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                VStack(spacing: Spacing.md) {
                    preview
                    aspectRow
                    straightenRow
                    Spacer(minLength: Spacing.md)
                }
                .padding(Spacing.md)
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        cropRect = draftRect
                        angle = draftAngle
                        dismiss()
                    }
                    .bold()
                    .foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") {
                        draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                        draftAngle = 0
                        lockedAspect = nil
                    }
                    .foregroundStyle(.phosphorSecondary)
                }
            }
            .task(id: asset.id) {
                image = await ImageLoader.shared.fullImage(for: asset.id)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(draftAngle))
                    let r = pixelRect(in: geo.size)
                    Color.black.opacity(0.45)
                        .mask {
                            ZStack {
                                Rectangle()
                                Rectangle()
                                    .frame(width: r.width, height: r.height)
                                    .position(x: r.midX, y: r.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                        .allowsHitTesting(false)
                    Rectangle()
                        .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .gesture(dragGesture(in: geo.size))
                    thirdsGrid(in: r)
                } else {
                    ProgressView().tint(.phosphorAccent)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
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
        .allowsHitTesting(false)
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
            }
        }
    }

    private var straightenRow: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Straighten").font(Typography.caption).foregroundStyle(.phosphorSecondary)
                Spacer()
                Text("\(Int(draftAngle))°").font(Typography.caption).foregroundStyle(.phosphorAccent)
            }
            Slider(value: $draftAngle, in: -45...45, step: 0.5)
                .tint(.phosphorAccent)
        }
    }

    // MARK: - Helpers

    private func pixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: draftRect.minX * size.width,
            y: draftRect.minY * size.height,
            width: draftRect.width * size.width,
            height: draftRect.height * size.height
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = draftRect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var r = start
                r.origin.x = max(0, min(1 - r.width, start.minX + dx))
                r.origin.y = max(0, min(1 - r.height, start.minY + dy))
                draftRect = r
            }
            .onEnded { _ in dragStart = nil }
    }

    private func applyAspect(_ aspect: CGFloat?) {
        guard let aspect else { return }
        let cx = draftRect.midX, cy = draftRect.midY
        var w = draftRect.width
        var h = w / aspect
        if h > 1 { h = 1; w = h * aspect }
        let r = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
        draftRect = CGRect(
            x: max(0, min(1 - w, r.minX)),
            y: max(0, min(1 - h, r.minY)),
            width: w, height: h
        )
    }
}
