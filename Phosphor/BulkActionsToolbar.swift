import SwiftUI

/// Result of a bulk operation, reported back to the host view so it can update
/// its local asset list without a refetch.
enum BulkOutcome {
    case favorited([String])
    case archived([String])
    case trashed([String])
}

/// Bottom toolbar shown while a grid is in selection mode. The host view owns
/// the selected-ID set and the asset lookup; this view only renders controls
/// and calls back through `perform`.
struct BulkActionsToolbar: View {
    let selectedIDs: Set<String>
    let onCancel: () -> Void
    /// Invoked with a finished outcome so the host can mutate its list.
    let onOutcome: (BulkOutcome) -> Void
    /// Resolves the selected IDs back to full `ImmichAsset` values for the
    /// Collage action. Hosts that don't support collage can omit this.
    var resolveAssets: (() -> [ImmichAsset])? = nil
    var onCollage: (([ImmichAsset]) -> Void)? = nil
    var onExport: (([ImmichAsset]) -> Void)? = nil

    @State private var showTrashConfirm = false
    @State private var showAlbumPicker = false
    @State private var showReadOnlyAlert = false
    @State private var isWorking = false
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    private var ids: [String] { Array(selectedIDs) }

    /// Runs a bulk op guarding against re-entrancy so a double-tap can't fire
    /// two batch requests.
    private func run(_ work: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            actionBar
        }
        .alert("Trash \(selectedIDs.count) photos?", isPresented: $showTrashConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Trash", role: .destructive) { run { await trash() } }
        }
        .alert("Read-only mode is on", isPresented: $showReadOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Disable read-only mode in Profile to perform this action.")
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerSheet(assetIDs: ids) { onCancel() }
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
    }

    private var actionBar: some View {
        actionButtons
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .disabled(isWorking)
            .opacity(isWorking ? 0.5 : 1)
            .overlay {
                if isWorking {
                    ProgressView().tint(.phosphorPrimary)
                }
            }
            .overlay(alignment: .top) {
                topBar.offset(y: -36)
            }
    }

    private var topBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
            Spacer()
            Button("Cancel") { onCancel() }
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
        }
        .padding(.horizontal, Spacing.l)
    }

    private var actionButtons: some View {
        HStack(spacing: Spacing.l) {
            action("heart", "Favorite") {
                run { await favorite() }
            }
            action("rectangle.stack.badge.plus", "Add to Album") {
                showAlbumPicker = true
            }
            action("archivebox", "Archive") {
                guard !isReadOnly else { showReadOnlyAlert = true; return }
                run { await archive() }
            }
            action(isReadOnly ? "lock" : "trash", "Trash") {
                guard !isReadOnly else { showReadOnlyAlert = true; return }
                showTrashConfirm = true
            }
            shareAction
            collageAction
            exportAction
        }
    }

    @ViewBuilder
    private var shareAction: some View {
        if let shareItems = shareURLs(), !shareItems.isEmpty {
            ShareLink(items: shareItems) {
                labelStack("square.and.arrow.up", "Share")
            }
            .accessibilityLabel("Share \(selectedIDs.count) selected")
        }
    }

    @ViewBuilder
    private var collageAction: some View {
        if let resolveAssets, let onCollage, selectedIDs.count >= 2 {
            action("rectangle.3.group", "Collage") {
                let assets = resolveAssets()
                guard !assets.isEmpty else { return }
                onCollage(assets)
            }
        }
    }

    @ViewBuilder
    private var exportAction: some View {
        if let resolveAssets, let onExport, !selectedIDs.isEmpty {
            action("square.and.arrow.down.on.square", "Export") {
                let assets = resolveAssets()
                guard !assets.isEmpty else { return }
                onExport(assets)
            }
        }
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { labelStack(symbol, title) }
            .accessibilityLabel("\(title) \(selectedIDs.count) selected")
    }

    private func labelStack(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
            Text(title)
                .font(Typography.caption)
        }
        .foregroundStyle(.phosphorPrimary)
        .frame(maxWidth: .infinity, minHeight: TapTarget.minimum)
    }

    private func shareURLs() -> [URL]? {
        let urls = ids.compactMap { ImmichAPI.shared.originalURL(id: $0) }
        return urls.isEmpty ? nil : urls
    }

    private func favorite() async {
        do {
            try await ImmichAPI.shared.bulkUpdate(ids: ids, isFavorite: true)
            HapticManager.notification(.success)
            onOutcome(.favorited(ids))
        } catch { HapticManager.notification(.error) }
    }

    private func archive() async {
        do {
            try await ImmichAPI.shared.bulkUpdate(ids: ids, isArchived: true)
            HapticManager.notification(.success)
            onOutcome(.archived(ids))
        } catch { HapticManager.notification(.error) }
    }

    private func trash() async {
        do {
            try await ImmichAPI.shared.trashAssets(ids: ids)
            HapticManager.notification(.success)
            onOutcome(.trashed(ids))
        } catch { HapticManager.notification(.error) }
    }
}

// MARK: - Album picker

private struct AlbumPickerSheet: View {
    let assetIDs: [String]
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AlbumViewModel()
    @State private var working = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                List {
                    ForEach(viewModel.albums) { album in
                        Button {
                            Task { await add(to: album) }
                        } label: {
                            HStack {
                                Text(album.albumName)
                                    .foregroundStyle(.phosphorPrimary)
                                Spacer()
                                Text("\(album.assetCount)")
                                    .foregroundStyle(.phosphorSecondary)
                            }
                        }
                        .listRowBackground(Color.phosphorSurface)
                    }
                }
                .scrollContentBackground(.hidden)
                .disabled(working)
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorPrimary)
                }
            }
            .task { await viewModel.loadAlbums() }
        }
        .preferredColorScheme(.dark)
    }

    private func add(to album: ImmichAlbum) async {
        working = true
        defer { working = false }
        do {
            try await viewModel.addAssets(assetIDs, to: album)
            HapticManager.notification(.success)
            dismiss()
            onDone()
        } catch {
            HapticManager.notification(.error)
        }
    }
}
