import SwiftUI

/// Export sheet: pick quality, render, then choose where to send the result.
struct CollageExportView: View {
    @ObservedObject var viewModel: CollageViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var quality: ExportQuality = .standard
    @State private var rendered: UIImage?
    @State private var isRendering = false
    @State private var uploadStatus: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        qualityPicker
                        previewArea
                        actionButtons
                        if let status = uploadStatus {
                            Text(status)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                        }
                    }
                    .padding(Spacing.md)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        renderTask?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Quality").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            Picker("Quality", selection: $quality) {
                ForEach(ExportQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: quality) { _, _ in rendered = nil }

            Text(estimatedSize)
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.medium)
                .fill(Color.phosphorSurface)
                .frame(height: 220)
            if isRendering {
                VStack(spacing: Spacing.sm) {
                    ProgressView(value: viewModel.renderProgress)
                        .tint(.phosphorAccent)
                        .padding(.horizontal, Spacing.xl)
                    Text("Rendering… \(Int(viewModel.renderProgress * 100))%")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            } else if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
            } else {
                Text("Tap Render to preview").foregroundStyle(.phosphorSecondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                renderTask = Task { await render() }
            } label: {
                Label(rendered == nil ? "Render" : "Re-render", systemImage: "wand.and.rays")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(Color.phosphorAccent, in: Capsule())
                    .foregroundStyle(.black)
                    .font(Typography.headline)
            }
            .disabled(isRendering)

            if let rendered {
                Button {
                    Task { await saveToImmich(rendered) }
                } label: {
                    Label("Save to Phosphor", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.phosphorSurface, in: Capsule())
                        .foregroundStyle(.phosphorAccent)
                }
                Button {
                    Task { _ = await viewModel.saveToPhotos(rendered) }
                } label: {
                    Label("Save to Camera Roll", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.phosphorSurface, in: Capsule())
                        .foregroundStyle(.phosphorAccent)
                }
                ShareLink(item: Image(uiImage: rendered), preview: SharePreview("Phosphor Collage", image: Image(uiImage: rendered))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.phosphorSurface, in: Capsule())
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
    }

    // MARK: - Actions

    private var estimatedSize: String {
        switch quality {
        case .screen: return "Approx. 0.5 MB · 1080px longest side"
        case .standard: return "Approx. 3 MB · 3000px longest side"
        case .high: return "Approx. 12 MB · 6000px longest side"
        case .maximum: return "Uncapped · up to 12000px longest side"
        }
    }

    private func render() async {
        isRendering = true
        defer { isRendering = false }
        rendered = await viewModel.renderForExport(quality: quality)
        if rendered == nil {
            uploadStatus = "Render failed. Try a lower quality."
        }
    }

    private func saveToImmich(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        uploadStatus = "Uploading…"
        do {
            let asset = try await ImmichAPI.shared.uploadAsset(
                data: data,
                deviceAssetId: "collage-\(UUID().uuidString)",
                deviceId: "phosphor-collage",
                fileName: "Phosphor-Collage-\(ISO8601DateFormatter().string(from: Date())).jpg",
                fileCreatedAt: Date(),
                fileModifiedAt: Date()
            )
            await viewModel.writeSidecar(for: image, uploadedAssetId: asset.id)
            uploadStatus = "Uploaded — sidecar saved for deep zoom."
            HapticManager.notification(.success)
        } catch {
            uploadStatus = "Upload failed: \(error.localizedDescription)"
            HapticManager.notification(.error)
        }
    }
}
