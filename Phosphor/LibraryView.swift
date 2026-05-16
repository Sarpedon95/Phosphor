import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @EnvironmentObject private var session: SessionState
    @State private var showYears = false
    @State private var showSearch = false
    @State private var continueAsset: ImmichAsset?
    @State private var deepLink: PhotoSelection?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    FilterBar(viewModel: viewModel)
                    TimelineGridView(viewModel: viewModel) {
                        VStack(spacing: 0) {
                            if session.hasFreshContinue {
                                continueBanner
                            }
                            if !session.recentlyViewedAssetIds.isEmpty {
                                RecentlyViewedRow()
                            }
                            MemoriesView()
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    GridLayoutControls(viewModel: viewModel) { showYears = true }
                }
                ToolbarItem(placement: .principal) {
                    libraryHeader
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                }
            }
        }
        .tint(.phosphorAccent)
        .task {
            if viewModel.groupedAssets.isEmpty {
                await viewModel.loadInitial()
            }
            resolveContinue()
        }
        .onChange(of: session.scrollToTopSignal) { _, _ in
            // Scroll-to-top on Library tab re-tap: re-routes the timeline's
            // existing scroll-restore mechanism to the first section. The
            // user perceives this as "snapped to the top".
            if session.scrollToTopTab == 0,
               let first = viewModel.groupedAssets.first {
                session.lastScrollSectionId = first.id
            }
        }
        .sheet(isPresented: $showYears) {
            YearsOverviewView(viewModel: viewModel) { year in
                jumpToYear(year)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        .fullScreenCover(item: $deepLink) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                switch change {
                case .favorited(let asset): viewModel.applyExternalUpdate(asset)
                case .trashed(let id): viewModel.removeExternally(id: id)
                }
            }
        }
    }

    private var continueAssetID: String { session.lastViewedAssetId }

    @ViewBuilder
    private var continueBanner: some View {
        if let asset = continueAsset {
            HStack(spacing: Spacing.md) {
                Image(systemName: "play.circle")
                    .foregroundStyle(.phosphorAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue where you left off")
                        .font(Typography.captionBold)
                        .foregroundStyle(.phosphorAccent)
                    Text(asset.originalFileName)
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Open") {
                    deepLink = PhotoSelection(assets: [asset], index: 0)
                }
                .font(Typography.captionBold)
                .foregroundStyle(.phosphorAccent)
                Button {
                    session.clearContinue()
                    continueAsset = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.phosphorSecondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.phosphorSurface)
        }
    }

    private var libraryHeader: some View {
        VStack(spacing: 0) {
            Text("Library").font(Typography.headline).foregroundStyle(.phosphorAccent)
            Text(headerSubtitle)
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
    }

    private var headerSubtitle: String {
        let total = viewModel.totalAssetCount
        if viewModel.activeFilters.isEmpty {
            return "\(total) \(total == 1 ? "photo" : "photos")"
        }
        return "\(viewModel.filteredAssetCount) of \(total)"
    }

    private func resolveContinue() {
        guard session.hasFreshContinue else { continueAsset = nil; return }
        let id = session.lastViewedAssetId
        guard let asset = viewModel.allFlatAssets().first(where: { $0.id == id })
        else { continueAsset = nil; return }
        continueAsset = asset
    }

    private func jumpToYear(_ year: Int) {
        // Find the first group whose id starts with that year and route to it
        // via SessionState's scroll-position field — TimelineGridView reads it
        // in its ScrollViewReader onAppear.
        if let group = viewModel.groupedAssets.first(where: { $0.id.hasPrefix("\(year)") }) {
            session.lastScrollSectionId = group.id
        }
    }
}

// MARK: - Recently Viewed row

private struct RecentlyViewedRow: View {
    @EnvironmentObject private var session: SessionState
    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Recently Viewed")
                    .font(Typography.captionBold)
                    .foregroundStyle(.phosphorAccent)
                Spacer()
                Button("Clear") {
                    session.clearRecentlyViewed()
                    assets = []
                }
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
            }
            .padding(.horizontal, Spacing.md)

            if assets.isEmpty {
                if isLoading {
                    HStack { Spacer(); ProgressView().tint(.phosphorAccent); Spacer() }
                        .frame(height: 80)
                } else {
                    EmptyView()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(assets) { asset in
                            RecentThumb(asset: asset)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
        .padding(.vertical, Spacing.sm)
        .task(id: session.recentlyViewedAssetIds) { await load() }
    }

    private func load() async {
        let ids = session.recentlyViewedAssetIds
        guard !ids.isEmpty else { assets = []; return }
        isLoading = true
        defer { isLoading = false }
        var fetched: [ImmichAsset] = []
        for id in ids {
            if let asset = try? await ImmichAPI.shared.fetchAsset(id: id) {
                fetched.append(asset)
            }
        }
        assets = fetched
    }
}

private struct RecentThumb: View {
    let asset: ImmichAsset
    @State private var thumb: UIImage?
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
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
        .accessibilityLabel("Recently viewed: \(asset.originalFileName)")
        .task(id: asset.id) {
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail)
        }
        .fullScreenCover(isPresented: $open) {
            PhotoDetailView(assets: [asset], selectedIndex: 0)
        }
    }
}
