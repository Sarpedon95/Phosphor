import SwiftUI
import UIKit

struct TimelineGridView<Header: View>: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject private var session: SessionState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selection: PhotoSelection?
    @State private var showReadOnlyAlert = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var pinchStartDensity: Int?
    @State private var collageAssets: CollageAssetSelection?
    @State private var exportAssets: CollageAssetSelection?
    @State private var pickerAssetIds: PickerAssetIds?
    @State private var sharedImage: TimelineSharedImage?
    @State private var isLoadingShare = false
    @State private var shareFailed = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode
    @AppStorage(AppSettings.Keys.gridDensity) private var gridDensity: Int = AppSettings.Defaults.gridDensity
    @AppStorage(AppSettings.Keys.timelineViewMode) private var viewModeRaw: String = AppSettings.Defaults.timelineViewMode.rawValue

    private let header: Header

    private var mode: TimelineViewMode {
        TimelineViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var groups: [TimelineGroup] {
        viewModel.filteredGroupedAssets
    }

    init(
        viewModel: LibraryViewModel,
        @ViewBuilder header: () -> Header
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.header = header()
    }

    private var columnCount: Int {
        let bounded = max(2, min(5, gridDensity))
        // Compact (iPhone) uses density directly; regular (iPad) gets +1.
        return horizontalSizeClass == .regular ? min(6, bounded + 1) : bounded
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    private var flatAssets: [ImmichAsset] {
        groups.flatMap(\.assets)
    }

    private var lastAssetID: String? {
        groups.last?.assets.last?.id
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onChanged { value in
                if pinchStartDensity == nil { pinchStartDensity = gridDensity }
                guard let start = pinchStartDensity else { return }
                // Pinch IN (magnification > 1) → more columns (more dense).
                // Pinch OUT (< 1) → fewer columns.
                let step = Int((value.magnification - 1.0) * 3)
                let target = max(2, min(5, start + step))
                if target != gridDensity {
                    HapticManager.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        gridDensity = target
                    }
                }
            }
            .onEnded { _ in pinchStartDensity = nil }
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content

            if isSelecting {
                BulkActionsToolbar(
                    selectedIDs: selectedIDs,
                    onCancel: exitSelection,
                    onOutcome: handleBulk,
                    resolveAssets: { resolveSelectedAssets() },
                    onCollage: { assets in
                        collageAssets = CollageAssetSelection(assets: assets)
                        exitSelection()
                    },
                    onExport: { assets in
                        exportAssets = CollageAssetSelection(assets: assets)
                        exitSelection()
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $collageAssets) { selection in
            CollageView(assets: selection.assets)
        }
        .sheet(item: $exportAssets) { selection in
            BatchExportView(assets: selection.assets)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isSelecting)
        .overlay(alignment: .topTrailing) {
            if !groups.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    HapticManager.selection()
                    if isSelecting { exitSelection() } else { isSelecting = true }
                }
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.m)
                .accessibilityHint(isSelecting ? "Exits selection mode." : "Select multiple photos for bulk actions.")
                .accessibilityLabel(isSelecting ? "Done selecting" : "Select")
            }
        }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(
                assets: sel.assets,
                selectedIndex: sel.index
            ) { change in
                switch change {
                case .favorited(let asset): viewModel.applyExternalUpdate(asset)
                case .trashed(let id): viewModel.removeExternally(id: id)
                }
            }
        }
        .alert("Read-only mode is on", isPresented: $showReadOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Disable read-only mode in Profile to perform this action.")
        }
        .sheet(item: $pickerAssetIds) { ids in
            AlbumPickerView(assetIds: ids.ids)
        }
        .sheet(item: $sharedImage) { wrapper in
            ActivityShareSheet(items: [wrapper.image])
        }
        .alert("Could not load image", isPresented: $shareFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.error, groups.isEmpty {
            errorState(error)
        } else if groups.isEmpty && viewModel.isLoading {
            ProgressView().tint(.phosphorPrimary)
        } else if groups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                Group {
                    switch mode {
                    case .grid: gridBody
                    case .list: listBody
                    case .justified: justifiedBody
                    }
                }
                .onAppear {
                    let target = session.lastScrollSectionId
                    if !target.isEmpty,
                       groups.contains(where: { $0.id == target }) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var gridBody: some View {
        ScrollView {
            header
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.assets) { asset in
                            cellView(asset)
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .gesture(pinchGesture)
        .scrollIndicators(.hidden)
        .refreshable {
            HapticManager.impact(.light)
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private var listBody: some View {
        ScrollView {
            header
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.assets) { asset in
                            TimelineListRow(asset: asset)
                                .onTapGesture {
                                    if isSelecting { toggleSelect(asset.id) } else { open(asset) }
                                }
                                .contextMenu {
                                    if !isSelecting {
                                        listContextMenu(for: asset)
                                    }
                                }
                                .onAppear {
                                    if asset.id == lastAssetID {
                                        Task { await viewModel.loadNextPage() }
                                    }
                                }
                            Divider().background(Color.phosphorSeparator)
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            HapticManager.impact(.light)
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private var justifiedBody: some View {
        ScrollView {
            header
            LazyVStack(spacing: Spacing.sm, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        JustifiedLayout(rowHeight: 160, spacing: 2) {
                            ForEach(group.assets) { asset in
                                JustifiedCell(asset: asset)
                                    .onTapGesture {
                                        if isSelecting { toggleSelect(asset.id) } else { open(asset) }
                                    }
                                    .contextMenu {
                                        if !isSelecting {
                                            listContextMenu(for: asset)
                                        }
                                    }
                                    .onAppear {
                                        if asset.id == lastAssetID {
                                            Task { await viewModel.loadNextPage() }
                                        }
                                    }
                            }
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            HapticManager.impact(.light)
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private func cellView(_ asset: ImmichAsset) -> some View {
        AssetGridCell(
            asset: asset,
            onContextAction: isSelecting ? nil : { handleContext($0, asset: asset) }
        )
            .overlay {
                if isSelecting {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(selectedIDs.contains(asset.id) ? 0.45 : 0.001)
                        Image(systemName: selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            }
            .onTapGesture {
                if isSelecting { toggleSelect(asset.id) } else { open(asset) }
            }
            .onAppear {
                if asset.id == lastAssetID {
                    Task { await viewModel.loadNextPage() }
                }
            }
    }

    private func sectionHeader(_ group: TimelineGroup) -> some View {
        HStack {
            Text(group.title)
                .font(Typography.title2)
                .foregroundStyle(.phosphorPrimary)
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s + 2)
        .background(Color.phosphorBackground)
        .id(group.id)
        .accessibilityAddTraits(.isHeader)
        .onAppear { session.saveScrollPosition(sectionId: group.id) }
    }

    private func handleContext(_ action: AssetContextAction, asset: ImmichAsset) {
        switch action {
        case .favorite:
            HapticManager.impact(.medium)
            HapticManager.notification(.success)
            Task { await viewModel.toggleFavorite(asset) }
        case .archive:
            Task {
                do {
                    _ = try await ImmichAPI.shared.toggleArchive(asset: asset)
                    HapticManager.notification(.success)
                } catch {
                    HapticManager.notification(.error)
                }
            }
        case .addToAlbum:
            pickerAssetIds = PickerAssetIds(ids: [asset.id])
        case .share:
            startShare(asset)
        case .trash:
            guard !isReadOnly else {
                showReadOnlyAlert = true
                return
            }
            HapticManager.impact(.heavy)
            HapticManager.notification(.warning)
            Task { await viewModel.trashAsset(asset) }
        }
    }

    private func startShare(_ asset: ImmichAsset) {
        guard !isLoadingShare else { return }
        isLoadingShare = true
        Task {
            let image = await ImageLoader.shared.fullImage(for: asset.id)
            isLoadingShare = false
            if let image {
                sharedImage = TimelineSharedImage(image: image)
            } else {
                shareFailed = true
                HapticManager.notification(.error)
            }
        }
    }

    /// Same actions as the grid cell's built-in context menu, used by list /
    /// justified rows where `AssetGridCell` isn't the underlying view.
    @ViewBuilder
    private func listContextMenu(for asset: ImmichAsset) -> some View {
        Button { handleContext(.favorite, asset: asset) } label: {
            Label(asset.isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: asset.isFavorite ? "heart.slash" : "heart")
        }
        Button { handleContext(.archive, asset: asset) } label: {
            Label(asset.isArchived ? "Unarchive" : "Archive",
                  systemImage: asset.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
        Button { handleContext(.addToAlbum, asset: asset) } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
        Button { handleContext(.share, asset: asset) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) { handleContext(.trash, asset: asset) } label: {
            Label(
                isReadOnly ? "Trash (Locked)" : "Trash",
                systemImage: isReadOnly ? "lock" : "trash"
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.m + 2) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.phosphorSecondary)
            Text("No photos yet")
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorState(_ error: ImmichError) -> some View {
        VStack(spacing: Spacing.m + 2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.yellow)
            Text(error.localizedDescription)
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl + Spacing.s)
            Button {
                Task { await viewModel.loadInitial() }
            } label: {
                Text("Retry")
                    .font(Typography.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.s + 2)
                    .background(.phosphorPrimary, in: Capsule())
            }
            .accessibilityHint("Tries loading the timeline again.")
        }
    }

    private func open(_ asset: ImmichAsset) {
        let assets = flatAssets
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.impact(.light)
        selection = PhotoSelection(assets: assets, index: index)
    }

    private func resolveSelectedAssets() -> [ImmichAsset] {
        let assets = viewModel.allFlatAssets()
        return assets.filter { selectedIDs.contains($0.id) }
    }

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func handleBulk(_ outcome: BulkOutcome) {
        switch outcome {
        case .favorited, .archived:
            // Favoriting/archiving doesn't remove from the timeline; refetch
            // lazily on next appear. Just exit selection.
            break
        case .trashed(let ids):
            ids.forEach { viewModel.removeExternally(id: $0) }
        }
        exitSelection()
    }
}

/// Identifiable wrapper so a non-Identifiable `[ImmichAsset]` can drive a
/// `.fullScreenCover(item:)` for the collage editor.
struct CollageAssetSelection: Identifiable {
    let id = UUID()
    let assets: [ImmichAsset]
}

/// Identifiable wrapper for driving the AlbumPickerView sheet.
struct PickerAssetIds: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// Local Identifiable wrapper for ActivityShareSheet (the one in
/// PhotoDetailView.swift is fileprivate).
struct TimelineSharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension TimelineGridView where Header == EmptyView {
    init(viewModel: LibraryViewModel) {
        self.init(viewModel: viewModel) { EmptyView() }
    }
}

/// Identifiable wrapper so the full-screen viewer can be driven by `.fullScreenCover(item:)`.
struct PhotoSelection: Identifiable {
    let id = UUID()
    let assets: [ImmichAsset]
    let index: Int
}

// AssetGridCell + ShimmerView now live in AssetGridCell.swift (shared).

// MARK: - List view row

private struct TimelineListRow: View {
    let asset: ImmichAsset
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color.phosphorPlaceholder
                }
                if asset.isVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.5), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(asset.originalFileName)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .lineLimit(1)
                HStack(spacing: Spacing.sm) {
                    Text(asset.localDateTime.formatted(date: .abbreviated, time: .shortened))
                    if let size = asset.fileSizeInByte {
                        Text(StorageFormatter.string(fromBytes: size))
                    }
                }
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
                .lineLimit(1)
            }
            Spacer()
            if asset.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.phosphorDestructive)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .task(id: asset.id) {
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .thumbnail)
        }
    }
}

// MARK: - Justified layout

/// Variable-width row layout: each row's items scale to fill row height while
/// preserving aspect ratio. Aspect comes from EXIF when available, otherwise
/// we assume 4:3 (photo) or 16:9 (video).
struct JustifiedLayout: Layout {
    var rowHeight: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // `proposal.width` can be unspecified (.unspecified -> nil) or 0 while
        // SwiftUI measures; in those cases the layout can't be meaningful, so
        // we return a single-row placeholder height to keep the view stable.
        let width = proposal.width ?? 0
        guard width > 1, rowHeight > 0 else {
            return CGSize(width: width, height: rowHeight)
        }
        let rows = layoutRows(subviews: subviews, containerWidth: width)
        let h = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: max(rowHeight, h))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(subviews: subviews, containerWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: entry.width, height: rowHeight)
                )
                x += entry.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    // MARK: row packing

    private struct RowEntry { let index: Int; let width: CGFloat }
    private struct Row { let entries: [RowEntry] }

    /// Aspect ratio for one subview, clamped to a sane band so a single
    /// degenerate cell (zero size, or panoramic placeholder) can't blow up the
    /// row scale and push neighbours off-screen.
    private func aspect(for subview: LayoutSubview) -> CGFloat {
        let s = subview.sizeThatFits(.unspecified)
        guard s.width > 0, s.height > 0 else { return 1.5 }
        let raw = s.width / s.height
        return min(max(raw, 0.3), 4.0)
    }

    private func layoutRows(subviews: Subviews, containerWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current: [(index: Int, aspect: CGFloat)] = []
        var aspectSum: CGFloat = 0

        for i in subviews.indices {
            let a = aspect(for: subviews[i])
            current.append((i, a))
            aspectSum += a
            let projectedWidth = aspectSum * rowHeight + CGFloat(current.count - 1) * spacing
            if projectedWidth >= containerWidth {
                rows.append(makeRow(current: current, containerWidth: containerWidth))
                current.removeAll()
                aspectSum = 0
            }
        }
        if !current.isEmpty {
            rows.append(makeRow(current: current, containerWidth: containerWidth, ragged: true))
        }
        return rows
    }

    private func makeRow(
        current: [(index: Int, aspect: CGFloat)],
        containerWidth: CGFloat,
        ragged: Bool = false
    ) -> Row {
        let totalSpacing = CGFloat(max(0, current.count - 1)) * spacing
        let aspectSum = current.reduce(0) { $0 + $1.aspect }
        let scale: CGFloat
        if ragged || aspectSum <= 0 || containerWidth - totalSpacing <= 0 {
            // Last row OR degenerate input: keep natural row height, don't
            // stretch. Avoids division-by-zero and pathological scales.
            scale = rowHeight
        } else {
            scale = (containerWidth - totalSpacing) / aspectSum
        }
        let entries = current.map { item in
            RowEntry(index: item.index, width: max(1, item.aspect * scale))
        }
        return Row(entries: entries)
    }
}

private struct JustifiedCell: View {
    let asset: ImmichAsset
    @State private var thumb: UIImage?

    private var aspectRatio: CGFloat {
        // Best-effort: EXIF resolution if available, else type heuristic.
        if let info = asset.exifInfo {
            _ = info // ExifInfo doesn't carry pixel dims in our model; fall through.
        }
        return asset.isVideo ? (16.0 / 9.0) : (3.0 / 2.0)
    }

    var body: some View {
        ZStack {
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                ShimmerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fill)
        .clipped()
        .task(id: asset.id) {
            thumb = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
        }
        .accessibilityElement()
        .accessibilityLabel(asset.originalFileName)
    }
}
