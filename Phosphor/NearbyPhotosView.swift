import SwiftUI

/// "More from {city}" — horizontal scroll of other assets from the same city.
struct NearbyPhotosView: View {
    let city: String
    let excludeAssetId: String
    @State private var assets: [ImmichAsset] = []
    @State private var open: PhotoSelection?

    var body: some View {
        content
            .task(id: city) { await load() }
            .fullScreenCover(item: $open) { sel in
                PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
            }
    }

    @ViewBuilder
    private var content: some View {
        if assets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("More from \(city)")
                    .font(Typography.captionBold)
                    .foregroundStyle(.phosphorAccent)
                    .padding(.horizontal, Spacing.md)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(assets) { asset in
                            NearbyThumb(asset: asset) {
                                if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                                    open = PhotoSelection(assets: assets, index: i)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
    }

    private func load() async {
        do {
            let results = try await ImmichAPI.shared.searchFiltered(city: city, size: 30)
            assets = results.filter { $0.id != excludeAssetId }
        } catch {
            assets = []
        }
    }
}

private struct NearbyThumb: View {
    let asset: ImmichAsset
    let onTap: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    ShimmerView()
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.originalFileName)
        .task(id: asset.id) {
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail)
        }
    }
}
