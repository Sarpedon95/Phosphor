import SwiftUI

/// Two-row editing toolbar. Row 1 = category tabs, row 2 = the active panel.
struct EditingToolbar: View {
    @ObservedObject var viewModel: EditingViewModel
    @Binding var cropPanelActive: Bool

    enum Category: String, CaseIterable, Identifiable {
        case presets = "Presets"
        case light = "Light"
        case color = "Color"
        case detail = "Detail"
        case toneCurve = "Tone Curve"
        case hsl = "HSL"
        case crop = "Crop"
        case effects = "Effects"
        var id: String { rawValue }
    }

    @State private var category: Category = .presets
    @State private var presetIntensity: Double = 1.0
    @State private var hslChannel = 0

    var body: some View {
        VStack(spacing: 0) {
            categoryRow
            Divider().background(Color.phosphorSeparator)
            panel
                .frame(maxHeight: 280)
        }
        .background(Color.phosphorBackground)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.lg) {
                ForEach(Category.allCases) { c in
                    Button {
                        if c == .crop {
                            // Crop opens a full-screen editor; keep the
                            // previously-selected category beneath it.
                            cropPanelActive = true
                        } else {
                            category = c
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(c.rawValue)
                                .font(Typography.subheadline)
                                .foregroundStyle(category == c ? .phosphorAccent : .phosphorSecondary)
                            Rectangle()
                                .fill(category == c ? Color.phosphorAccent : .clear)
                                .frame(height: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch category {
        case .presets: presetsPanel
        case .light: lightPanel
        case .color: colorPanel
        case .detail: detailPanel
        case .toneCurve: ToneCurveEditor(viewModel: viewModel)
        case .hsl: hslPanel
        case .crop:
            // Crop is presented as a full-screen sheet by EditingView; no
            // inline panel is rendered for this category.
            EmptyView()
        case .effects: effectsPanel
        }
    }

    // MARK: - Panels

    private var presetsPanel: some View {
        VStack {
            presetsScrollView
            intensityControl
        }
        .padding(.vertical, Spacing.sm)
    }

    private var presetsScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(viewModel.allPresets) { preset in
                    presetButton(for: preset)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
    }

    private func presetButton(for preset: EditPreset) -> some View {
        Button {
            viewModel.applyPreset(preset, intensity: presetIntensity)
        } label: {
            presetLabel(for: preset)
        }
        .contextMenu {
            if !preset.isBuiltIn {
                Button(role: .destructive) {
                    viewModel.deleteUserPreset(preset)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func presetLabel(for preset: EditPreset) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: CornerRadius.small)
                .fill(Color.phosphorSurface)
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.phosphorSecondary)
                }
                .overlay {
                    if viewModel.selectedPreset == preset.name {
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .strokeBorder(Color.phosphorAccent, lineWidth: 2)
                    }
                }
            Text(preset.name)
                .font(Typography.caption)
                .foregroundStyle(.phosphorAccent)
        }
    }

    @ViewBuilder
    private var intensityControl: some View {
        if viewModel.selectedPreset != nil {
            VStack(alignment: .leading) {
                Text("Intensity \(Int(presetIntensity * 100))%")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                Slider(value: $presetIntensity, in: 0...1)
                    .tint(.phosphorAccent)
                    .onChange(of: presetIntensity) { _, _ in
                        if let name = viewModel.selectedPreset,
                           let p = viewModel.allPresets.first(where: { $0.name == name }) {
                            viewModel.applyPreset(p, intensity: presetIntensity)
                        }
                    }
            }
            .padding(.horizontal, Spacing.md)
        }
    }

    private var lightPanel: some View {
        sliderList([
            ("Exposure", \.exposure, -2, 2, 0),
            ("Brightness", \.brightness, -1, 1, 0),
            ("Contrast", \.contrast, 0.5, 2, 1),
            ("Highlights", \.highlights, -1, 1, 0),
            ("Shadows", \.shadows, -1, 1, 0),
            ("Whites", \.whites, -0.5, 0.5, 0),
            ("Blacks", \.blacks, -0.5, 0.5, 0)
        ])
    }

    private var colorPanel: some View {
        sliderList([
            ("Saturation", \.saturation, 0, 2, 1),
            ("Vibrance", \.vibrance, -1, 1, 0),
            ("Warmth", \.warmth, 2000, 10000, 6500),
            ("Tint", \.tint, -100, 100, 0)
        ])
    }

    private var detailPanel: some View {
        sliderList([
            ("Sharpness", \.sharpness, 0, 1, 0),
            ("Noise Reduction", \.noiseReduction, 0, 1, 0)
        ])
    }

    private var effectsPanel: some View {
        sliderList([
            ("Vignette", \.vignette, -1, 1, 0),
            ("Grain", \.grain, 0, 1, 0),
            ("Fade", \.fade, 0, 0.5, 0)
        ])
    }

    private var hslPanel: some View {
        VStack(spacing: Spacing.sm) {
            let dots: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(0..<8, id: \.self) { i in
                        Button {
                            hslChannel = i
                        } label: {
                            Circle()
                                .fill(dots[i])
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if hslChannel == i {
                                        Circle().strokeBorder(Color.phosphorAccent, lineWidth: 2)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
            }
            hslSlider("Hue", channel: hslChannel, key: \.hue, range: -0.5...0.5)
            hslSlider("Saturation", channel: hslChannel, key: \.sat, range: -1...1)
            hslSlider("Luminance", channel: hslChannel, key: \.lum, range: -1...1)
        }
        .padding(Spacing.md)
    }

    // MARK: - Slider helpers

    private func sliderList(
        _ items: [(String, WritableKeyPath<EditAdjustments, Double>, Double, Double, Double)]
    ) -> some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                ForEach(items, id: \.0) { item in
                    adjustSlider(label: item.0, keyPath: item.1,
                                 range: item.2...item.3, defaultValue: item.4)
                }
            }
            .padding(Spacing.md)
        }
    }

    private func adjustSlider(
        label: String,
        keyPath: WritableKeyPath<EditAdjustments, Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        let binding = Binding<Double>(
            get: { viewModel.adjustments[keyPath: keyPath] },
            set: { newVal in
                var adj = viewModel.adjustments
                adj[keyPath: keyPath] = newVal
                viewModel.updateAdjustments(adj)
            }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .onTapGesture(count: 2) {
                        var adj = viewModel.adjustments
                        adj[keyPath: keyPath] = defaultValue
                        viewModel.updateAdjustments(adj)
                    }
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.phosphorAccent)
            }
            Slider(value: binding, in: range)
                .tint(.phosphorAccent)
        }
    }

    private func hslSlider(
        _ label: String,
        channel: Int,
        key: WritableKeyPath<HSLAdjustment, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        let binding = Binding<Double>(
            get: { viewModel.adjustments.hsl[channel][keyPath: key] },
            set: { newVal in
                var adj = viewModel.adjustments
                adj.hsl[channel][keyPath: key] = newVal
                viewModel.updateAdjustments(adj)
            }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Typography.caption).foregroundStyle(.phosphorSecondary)
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.phosphorAccent)
            }
            Slider(value: binding, in: range).tint(.phosphorAccent)
        }
    }
}

/// 5-point Catmull-Rom-ish tone curve editor. Only the composite RGB curve is
/// editable; per-channel R/G/B curves show a "coming soon" overlay.
private struct ToneCurveEditor: View {
    @ObservedObject var viewModel: EditingViewModel
    @State private var channel = "RGB"

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                ForEach(["RGB", "R", "G", "B"], id: \.self) { ch in
                    Button(ch) { channel = ch }
                        .font(Typography.caption)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .background(channel == ch ? Color.phosphorAccent : Color.phosphorSurface,
                                    in: Capsule())
                        .foregroundStyle(channel == ch ? .black : .phosphorAccent)
                }
                Spacer()
                Button("Reset") {
                    var adj = viewModel.adjustments
                    adj.toneCurve = EditAdjustments.identity.toneCurve
                    viewModel.updateAdjustments(adj)
                }
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
            }
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.5)
                    grid(in: geo.size)
                    curve(in: geo.size)
                    if channel != "RGB" {
                        Color.black.opacity(0.6)
                        Text("Per-channel curves coming soon")
                            .font(Typography.caption)
                            .foregroundStyle(.phosphorSecondary)
                    } else {
                        controlPoints(in: geo.size)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .padding(Spacing.md)
    }

    private func grid(in size: CGSize) -> some View {
        Path { p in
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(i) / 4
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
    }

    private func curve(in size: CGSize) -> some View {
        let pts = viewModel.adjustments.toneCurve
        return Path { p in
            guard let first = pts.first else { return }
            p.move(to: point(first, in: size))
            for pt in pts.dropFirst() { p.addLine(to: point(pt, in: size)) }
        }
        .stroke(Color.white, lineWidth: 2)
    }

    private func controlPoints(in size: CGSize) -> some View {
        ForEach(0..<viewModel.adjustments.toneCurve.count, id: \.self) { idx in
            let pt = viewModel.adjustments.toneCurve[idx]
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .position(point(pt, in: size))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            var adj = viewModel.adjustments
                            var pts = adj.toneCurve
                            let nx = max(0, min(1, value.location.x / size.width))
                            let ny = max(0, min(1, 1 - value.location.y / size.height))
                            // Endpoints keep their x; interior points clamp
                            // between neighbours so they can't cross.
                            let clampedX: CGFloat
                            if idx == 0 { clampedX = 0 }
                            else if idx == pts.count - 1 { clampedX = 1 }
                            else {
                                clampedX = max(pts[idx-1].x + 0.01,
                                               min(pts[idx+1].x - 0.01, nx))
                            }
                            pts[idx] = CGPoint(x: clampedX, y: ny)
                            adj.toneCurve = pts
                            viewModel.updateAdjustments(adj)
                        }
                )
        }
    }

    private func point(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: pt.x * size.width, y: (1 - pt.y) * size.height)
    }
}
