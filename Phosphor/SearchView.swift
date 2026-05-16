import SwiftUI
import UIKit

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText: String
    @State private var selection: PhotoSelection?
    @State private var showFilters = false
    @State private var showSaved = false
    @State private var showSaveDialog = false
    @State private var saveName = ""
    let albumScope: ImmichAlbum?

    init(initialQuery: String = "", albumScope: ImmichAlbum? = nil) {
        _searchText = State(initialValue: initialQuery)
        self.albumScope = albumScope
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 2),
            count: horizontalSizeClass == .regular ? 4 : 3
        )
    }

    private var exploreColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 2)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Spacing.m + Spacing.xs + 2) {
                        PeopleView()

                        Picker("Mode", selection: $viewModel.searchMode) {
                            ForEach(SearchMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Spacing.l)
                        .accessibilityLabel("Search mode")
                        .accessibilityHint("Smart search uses AI; metadata searches filenames and tags.")

                        if showFilters { filtersPanel }
                        if viewModel.hasActiveFilters { activeFilterChips }

                        bodyContent
                    }
                    .padding(.top, Spacing.s)
                    .padding(.bottom, Spacing.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Search")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            withAnimation { showFilters.toggle() }
                        } label: {
                            Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Filters")
                        Button { showSaved = true } label: {
                            Image(systemName: "bookmark")
                        }
                        .accessibilityLabel("Saved searches")
                        if viewModel.hasActiveFilters || !searchText.isEmpty {
                            Button { showSaveDialog = true } label: {
                                Image(systemName: "plus.circle")
                            }
                            .accessibilityLabel("Save this search")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search photos")
            .task(id: searchInputs) { await viewModel.search(query: searchText) }
            .task { await viewModel.loadExplore() }
            .task {
                if let scope = albumScope { viewModel.albumScopeId = scope.id }
            }
            .sheet(isPresented: $showSaved) {
                SavedSearchesView(viewModel: viewModel) { restoredQuery in
                    searchText = restoredQuery
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
            }
            .alert("Save Search", isPresented: $showSaveDialog) {
                TextField("Name", text: $saveName)
                Button("Cancel", role: .cancel) { saveName = "" }
                Button("Save") {
                    viewModel.saveCurrentSearch(name: saveName, query: searchText)
                    saveName = ""
                }
            }
            .navigationDestination(for: Person.self) { person in
                PersonDetailView(person: person)
            }
        }
        .tint(.white)
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                switch change {
                case .favorited(let asset): viewModel.applyExternalUpdate(asset)
                case .trashed(let id): viewModel.removeExternally(id: id)
                }
            }
        }
    }

    /// Single hashable surface for `.task(id:)` so filter changes re-run search.
    private var searchInputs: String {
        [
            searchText,
            viewModel.dateFrom.map(\.timeIntervalSince1970.description) ?? "-",
            viewModel.dateTo.map(\.timeIntervalSince1970.description) ?? "-",
            viewModel.locationFilter ?? "-",
            viewModel.cameraFilter ?? "-",
            viewModel.albumScopeId ?? "-"
        ].joined(separator: "|")
    }

    // MARK: - Filter panel

    private var filtersPanel: some View {
        VStack(spacing: Spacing.md) {
            HStack {
                Text("From")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                Spacer()
                DatePicker(
                    "From",
                    selection: Binding(
                        get: { viewModel.dateFrom ?? Date(timeIntervalSince1970: 0) },
                        set: { viewModel.dateFrom = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                if viewModel.dateFrom != nil {
                    Button { viewModel.dateFrom = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Clear from date")
                }
            }
            HStack {
                Text("To")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                Spacer()
                DatePicker(
                    "To",
                    selection: Binding(
                        get: { viewModel.dateTo ?? Date() },
                        set: { viewModel.dateTo = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                if viewModel.dateTo != nil {
                    Button { viewModel.dateTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Clear to date")
                }
            }
            TextField("Location (city)", text: Binding(
                get: { viewModel.locationFilter ?? "" },
                set: { viewModel.locationFilter = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TextField("Camera (make and model)", text: Binding(
                get: { viewModel.cameraFilter ?? "" },
                set: { viewModel.cameraFilter = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
        .padding(Spacing.md)
        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        .padding(.horizontal, Spacing.md)
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                if let from = viewModel.dateFrom {
                    chip("From \(from.formatted(date: .abbreviated, time: .omitted))") {
                        viewModel.dateFrom = nil
                    }
                }
                if let to = viewModel.dateTo {
                    chip("To \(to.formatted(date: .abbreviated, time: .omitted))") {
                        viewModel.dateTo = nil
                    }
                }
                if let city = viewModel.locationFilter {
                    chip(city) { viewModel.locationFilter = nil }
                }
                if let cam = viewModel.cameraFilter {
                    chip(cam) { viewModel.cameraFilter = nil }
                }
                if viewModel.albumScopeId != nil {
                    chip("In album") { viewModel.albumScopeId = nil }
                }
                Button("Clear all") { viewModel.clearFilters() }
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorDestructive)
                    .padding(.horizontal, Spacing.sm)
            }
            .padding(.horizontal, Spacing.md)
        }
    }

    private func chip(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(Typography.caption).foregroundStyle(.phosphorAccent)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.phosphorSecondary)
            }
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.phosphorSurface))
    }

    @ViewBuilder
    private var bodyContent: some View {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.hasActiveFilters {
            exploreSection
            recentSection
        } else if viewModel.isSearching {
            shimmerGrid
        } else if viewModel.results.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No results for \"\(searchText)\"")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .padding(.top, 60)
            .accessibilityElement(children: .combine)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(viewModel.results) { asset in
                    AssetGridCell(asset: asset)
                        .onTapGesture {
                            HapticManager.impact(.light)
                            open(asset)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var exploreSection: some View {
        if !viewModel.exploreItems.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s + 2) {
                Text("Explore")
                    .font(Typography.title3)
                    .foregroundStyle(.phosphorPrimary)
                    .padding(.horizontal, Spacing.l)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: exploreColumns, spacing: Spacing.m) {
                    ForEach(viewModel.exploreItems) { item in
                        Button {
                            HapticManager.impact(.light)
                            searchText = item.label
                        } label: {
                            ExploreCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search for \(item.label)")
                    }
                }
                .padding(.horizontal, Spacing.l)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !viewModel.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Recent")
                        .font(Typography.title3)
                        .foregroundStyle(.phosphorPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear") { viewModel.clearRecentSearches() }
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorSecondary)
                        .accessibilityHint("Clears your recent search history.")
                }
                .padding(.horizontal, Spacing.l)

                ForEach(viewModel.recentSearches, id: \.self) { term in
                    Button {
                        HapticManager.selection()
                        searchText = term
                    } label: {
                        HStack(spacing: Spacing.s + 2) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.phosphorSecondary)
                            Text(term)
                                .foregroundStyle(.phosphorPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.s + 2)
                        .frame(minHeight: TapTarget.minimum)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Re-run search for \(term)")
                }
            }
        }
    }

    private var shimmerGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 2) {
            ForEach(0..<12, id: \.self) { _ in
                ShimmerView().aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard let index = viewModel.results.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.selection()
        selection = PhotoSelection(assets: viewModel.results, index: index)
    }
}

private struct ExploreCard: View {
    let item: ExploreItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } else {
                        ShimmerView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
            }
            .aspectRatio(1, contentMode: .fit)

            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(item.label)
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.m)
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small + 2, style: .continuous))
        .task(id: item.id) {
            image = await ImageLoader.shared.thumbnail(for: item.asset.id, size: .preview)
        }
    }
}
