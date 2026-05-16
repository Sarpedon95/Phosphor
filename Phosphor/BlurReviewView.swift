import SwiftUI

struct BlurReviewView: View {
    @StateObject private var engine = BlurDetectionEngine.shared
    @State private var allAssets: [ImmichAsset] = []
    @State private var isLoadingAssets = false
    @State private var showTrashAllConfirm = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    private var blurry: [BlurResult] { engine.results.filter { $0.isBlurry } }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Blurry Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await scan() }
                } label: {
                    if engine.isScanning {
                        ProgressView().controlSize(.small).tint(.phosphorAccent)
                    } else {
                        Text("Scan Library")
                    }
                }
                .disabled(engine.isScanning)
                .foregroundStyle(.phosphorAccent)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .alert("Trash blurry photos?", isPresented: $showTrashAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Trash \(blurry.count)", role: .destructive) {
                Task { await trashAll() }
            }
        } message: {
            Text("Permanently move \(blurry.count) blurry photos to trash? You can restore them from Trash later.")
        }
        .task {
            if allAssets.isEmpty { await loadAssets() }
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if engine.isScanning {
            VStack(spacing: Spacing.md) {
                ProgressView(value: engine.progress)
                    .tint(.phosphorAccent)
                    .padding(.horizontal, Spacing.xl)
                Text("Scanning \(Int(engine.progress * 100))%")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
            }
        } else if engine.results.isEmpty {
            emptyState(symbol: "eye", title: "Tap Scan to analyze your library")
        } else if blurry.isEmpty {
            emptyState(symbol: "checkmark.circle", title: "All photos are sharp")
        } else {
            List {
                ForEach(blurry) { result in
                    BlurRow(result: result)
                        .listRowBackground(Color.phosphorSurface)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                engine.remove(assetId: result.assetId)
                            } label: {
                                Label("Keep", systemImage: "checkmark")
                            }
                            .tint(.phosphorSuccess)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                guard !isReadOnly else { return }
                                Task { await trash(result) }
                            } label: {
                                Label(isReadOnly ? "Locked" : "Trash",
                                      systemImage: isReadOnly ? "lock" : "trash")
                            }
                            .tint(isReadOnly ? .gray : .red)
                        }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func emptyState(symbol: String, title: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.phosphorSecondary)
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(.phosphorAccent)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !blurry.isEmpty && !engine.isScanning {
            HStack(spacing: Spacing.md) {
                Button("Keep All") { engine.clearResults() }
                    .foregroundStyle(.phosphorSecondary)
                Spacer()
                Button(role: .destructive) {
                    guard !isReadOnly else { return }
                    showTrashAllConfirm = true
                } label: {
                    Text(isReadOnly ? "Trash All (Locked)" : "Trash All (\(blurry.count))")
                }
                .foregroundStyle(isReadOnly ? .phosphorSecondary : .phosphorDestructive)
                .disabled(isReadOnly)
            }
            .padding(Spacing.md)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Actions

    private func loadAssets() async {
        isLoadingAssets = true
        defer { isLoadingAssets = false }
        do {
            allAssets = try await ImmichAPI.shared.fetchTimeline(page: 1, pageSize: 500)
        } catch {
            allAssets = []
        }
    }

    private func scan() async {
        if allAssets.isEmpty { await loadAssets() }
        await engine.scan(assets: allAssets)
    }

    private func trash(_ result: BlurResult) async {
        do {
            try await ImmichAPI.shared.trashAssets(ids: [result.assetId])
            engine.remove(assetId: result.assetId)
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func trashAll() async {
        let ids = blurry.map(\.assetId)
        guard !ids.isEmpty else { return }
        do {
            try await ImmichAPI.shared.trashAssets(ids: ids)
            ids.forEach { engine.remove(assetId: $0) }
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

private struct BlurRow: View {
    let result: BlurResult
    @State private var thumb: UIImage?

    private var label: String {
        switch result.blurScore {
        case 0.8...: return "Very Blurry"
        case 0.65..<0.8: return "Blurry"
        default: return "Slightly Blurry"
        }
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    ShimmerView()
                }
                LinearGradient(
                    colors: [.blue.opacity(result.blurScore * 0.5), .clear],
                    startPoint: .bottom, endPoint: .top
                )
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(label)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorAccent)
                Text("\(Int(result.blurScore * 100))% blur")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            Spacer()
        }
        .task(id: result.assetId) {
            thumb = await ImageLoader.shared.thumbnail(for: result.assetId, size: .thumbnail)
        }
    }
}
