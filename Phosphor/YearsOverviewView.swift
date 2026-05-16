import SwiftUI

/// 2-column grid showing one card per year. Tap a year to scroll the
/// underlying timeline to that year's first section.
struct YearsOverviewView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onYearSelected: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @Namespace private var yearZoom

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.md), count: 2)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(viewModel.years, id: \.self) { year in
                            Button {
                                onYearSelected(year)
                                dismiss()
                            } label: {
                                YearCard(
                                    year: year,
                                    count: viewModel.assetCount(forYear: year),
                                    asset: viewModel.representative(forYear: year),
                                    namespace: yearZoom
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(year), \(viewModel.assetCount(forYear: year)) photos")
                        }
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle("Years")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct YearCard: View {
    let year: Int
    let count: Int
    let asset: ImmichAsset?
    let namespace: Namespace.ID
    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                ZStack {
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } else {
                        ShimmerView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))

            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .center, endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))

            HStack(alignment: .bottom) {
                Text(verbatim: "\(year)")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.phosphorAccent)
                Spacer()
                Text("\(count)")
                    .font(Typography.captionBold)
                    .foregroundStyle(.phosphorAccent)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
            }
            .padding(Spacing.md)
        }
        .matchedGeometryEffect(id: "year-\(year)", in: namespace)
        .task(id: asset?.id ?? "") {
            guard let asset else { return }
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
        }
    }
}
