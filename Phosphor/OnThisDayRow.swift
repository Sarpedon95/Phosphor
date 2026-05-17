import SwiftUI

/// "On this day" — other photos taken on the same month+day across all years.
struct OnThisDayRow: View {
    let date: Date
    let excludeAssetId: String
    @State private var assets: [ImmichAsset] = []
    @State private var open: PhotoSelection?

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy"; return f
    }()

    var body: some View {
        content
            .task(id: date) { await load() }
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
                Text("On This Day")
                    .font(Typography.captionBold)
                    .foregroundStyle(.phosphorAccent)
                    .padding(.horizontal, Spacing.md)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(assets) { asset in
                            OnThisDayCell(asset: asset, yearText: Self.yearFormatter.string(from: asset.localDateTime)) {
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
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.month, .day], from: date)
        guard let month = comps.month, let day = comps.day else { return }
        do {
            let results = try await ImmichAPI.shared.fetchOnThisDay(month: month, day: day)
            assets = results.filter { $0.id != excludeAssetId }
        } catch {
            assets = []
        }
    }
}

private struct OnThisDayCell: View {
    let asset: ImmichAsset
    let yearText: String
    let onTap: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    ShimmerView()
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .center, endPoint: .bottom
                )
                Text(yearText)
                    .font(Typography.captionBold)
                    .foregroundStyle(.phosphorAccent)
                    .padding(6)
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(yearText), \(asset.originalFileName)")
        .task(id: asset.id) {
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail)
        }
    }
}
