import SwiftUI

struct StackDetailView: View {
    let stackId: String
    let primaryAsset: ImmichAsset

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var selection: PhotoSelection?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorPrimary)
                }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && assets.isEmpty {
            ProgressView().tint(.phosphorPrimary)
        } else if let loadError, assets.isEmpty {
            VStack(spacing: Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(loadError.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorPrimary)
            }
        } else {
            List {
                ForEach(assets) { asset in
                    Button {
                        open(asset)
                    } label: {
                        HStack(spacing: Spacing.m) {
                            StackRowThumbnail(assetId: asset.id)
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(asset.originalFileName)
                                    .font(Typography.subheadline)
                                    .foregroundStyle(.phosphorPrimary)
                                    .lineLimit(1)
                                Text(asset.localDateTime.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                            }
                            Spacer()
                            if asset.id == primaryAsset.id {
                                Text("Primary")
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.phosphorSurface)
                }
                .onMove(perform: moveAssets)
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard let idx = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.impact(.light)
        selection = PhotoSelection(assets: assets, index: idx)
    }

    private func moveAssets(from source: IndexSet, to destination: Int) {
        // Local reorder only. Immich has no public stack-reorder endpoint, so
        // we don't fake a network round-trip — the order is presentational
        // within this session.
        assets.move(fromOffsets: source, toOffset: destination)
        HapticManager.selection()
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchStack(stackId: stackId)
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }
}

private struct StackRowThumbnail: View {
    let assetId: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ShimmerView()
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        .task(id: assetId) {
            image = await ImageLoader.shared.thumbnail(for: assetId, size: .thumbnail)
        }
    }
}
