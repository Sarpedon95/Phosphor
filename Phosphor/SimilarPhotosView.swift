import SwiftUI
import Vision

@MainActor
final class SimilarPhotosViewModel: ObservableObject {
    @Published private(set) var results: [(asset: ImmichAsset, similarity: Int)] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = ""
    @Published var error: String?

    private let reference: ImmichAsset
    private let candidateCap = 200
    private let distanceThreshold: Float = 0.8

    init(reference: ImmichAsset) {
        self.reference = reference
    }

    func run() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        statusText = "Loading reference photo…"
        guard let refImage = await ImageLoader.shared.fullImage(for: reference.id),
              let refPrint = await PhotoIntelligenceEngine.shared.computeFeaturePrint(image: refImage)
        else {
            error = "Couldn't analyze the reference photo."
            return
        }

        // Candidate pool: most recent assets, capped.
        let pool: [ImmichAsset]
        do {
            let timeline = try await ImmichAPI.shared.fetchTimeline(page: 1, pageSize: candidateCap)
            pool = Array(timeline.prefix(candidateCap)).filter { $0.id != reference.id }
        } catch {
            self.error = "Couldn't load photos to compare."
            return
        }

        // Concurrent thumbnail download (≤10) then feature prints (≤5).
        statusText = "Analyzing \(pool.count) photos…"
        let prints = await computePrints(for: pool)
        guard !prints.isEmpty else {
            results = []
            return
        }

        let ranked = await PhotoIntelligenceEngine.shared.findSimilar(
            reference: refPrint, candidates: prints
        )
        let byId = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        results = ranked
            .filter { $0.distance <= distanceThreshold }
            .compactMap { scored in
                guard let asset = byId[scored.assetId] else { return nil }
                // Map distance (0 = identical, threshold = cutoff) to a 0–100%
                // similarity score for the badge.
                let pct = Int((1 - min(1, scored.distance / distanceThreshold)) * 100)
                return (asset, pct)
            }
    }

    private func computePrints(
        for assets: [ImmichAsset]
    ) async -> [(assetId: String, observation: VNFeaturePrintObservation)] {
        // Stage 1: download thumbnails, ≤10 concurrent.
        var thumbs: [(String, UIImage)] = []
        for batch in stride(from: 0, to: assets.count, by: 10) {
            let slice = Array(assets[batch..<min(batch + 10, assets.count)])
            let part = await withTaskGroup(of: (String, UIImage?).self,
                                           returning: [(String, UIImage)].self) { group in
                for asset in slice {
                    group.addTask {
                        (asset.id, await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail))
                    }
                }
                var out: [(String, UIImage)] = []
                for await (id, img) in group {
                    if let img { out.append((id, img)) }
                }
                return out
            }
            thumbs.append(contentsOf: part)
        }

        // Stage 2: feature prints, ≤5 concurrent.
        var prints: [(assetId: String, observation: VNFeaturePrintObservation)] = []
        for batch in stride(from: 0, to: thumbs.count, by: 5) {
            let slice = Array(thumbs[batch..<min(batch + 5, thumbs.count)])
            let part = await withTaskGroup(
                of: (String, VNFeaturePrintObservation?).self,
                returning: [(String, VNFeaturePrintObservation)].self
            ) { group in
                for (id, img) in slice {
                    group.addTask {
                        (id, await PhotoIntelligenceEngine.shared.computeFeaturePrint(image: img))
                    }
                }
                var out: [(String, VNFeaturePrintObservation)] = []
                for await (id, obs) in group {
                    if let obs { out.append((id, obs)) }
                }
                return out
            }
            prints.append(contentsOf: part.map { ($0.0, $0.1) })
        }
        return prints
    }
}

struct SimilarPhotosView: View {
    let reference: ImmichAsset
    @StateObject private var viewModel: SimilarPhotosViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: PhotoSelection?

    init(reference: ImmichAsset) {
        self.reference = reference
        _viewModel = StateObject(wrappedValue: SimilarPhotosViewModel(reference: reference))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2),
              count: horizontalSizeClass == .regular ? 4 : 3)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Similar to \(reference.originalFileName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(.phosphorAccent)
                }
            }
        }
        .task { await viewModel.run() }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            VStack(spacing: Spacing.md) {
                ProgressView().tint(.phosphorAccent).scaleEffect(1.4)
                Text("Finding similar photos…")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorAccent)
                Text(viewModel.statusText)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
        } else if let error = viewModel.error {
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                Button("Retry") { Task { await viewModel.run() } }
                    .foregroundStyle(.phosphorAccent)
            }
        } else if viewModel.results.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No similar photos found")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.results, id: \.asset.id) { entry in
                        AssetGridCell(asset: entry.asset)
                            .overlay(alignment: .topTrailing) {
                                Text("\(entry.similarity)%")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(4)
                            }
                            .onTapGesture {
                                if let i = viewModel.results.firstIndex(where: { $0.asset.id == entry.asset.id }) {
                                    selection = PhotoSelection(
                                        assets: viewModel.results.map(\.asset), index: i
                                    )
                                }
                            }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
    }
}
