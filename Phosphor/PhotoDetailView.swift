import SwiftUI
import UIKit
import MapKit
import CoreLocation
import Photos
import PhotosUI

/// Reported back to whichever screen presented the viewer so it can keep its
/// own asset list in sync without a second network round-trip.
enum PhotoDetailChange {
    case favorited(ImmichAsset)
    case trashed(String)
}

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [ImmichAsset]
    @State private var currentIndex: Int
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0
    @State private var showReadOnlyAlert = false
    @State private var stackToShow: StackPresentation?
    @State private var showSharedLinkSheet = false
    @State private var editingAsset: ImmichAsset?
    @State private var printAsset: ImmichAsset?
    @State private var similarAsset: ImmichAsset?
    @State private var showCompactExif = false
    @State private var documentExportURL: URL?
    @State private var shareImage: SharedImage?
    @State private var isLoadingShare = false
    @State private var shareFailed = false
    /// Bumped to a new UUID when the user taps "Motion" in the toolbar; the
    /// currently-visible `LivePhotoPage` observes this and triggers playback.
    @State private var livePlayRequested: UUID = UUID()
    @EnvironmentObject private var session: SessionState
    @AppStorage(AppSettings.Keys.readOnlyMode) private var isReadOnly: Bool = AppSettings.Defaults.readOnlyMode

    private let onChange: ((PhotoDetailChange) -> Void)?

    init(
        assets: [ImmichAsset],
        selectedIndex: Int,
        onChange: ((PhotoDetailChange) -> Void)? = nil
    ) {
        _assets = State(initialValue: assets)
        // Clamp into a valid range so a stale selectedIndex (asset removed
        // between selection and presentation) can't desync the TabView.
        let safeIndex = assets.isEmpty
            ? 0
            : min(max(0, selectedIndex), assets.count - 1)
        _currentIndex = State(initialValue: safeIndex)
        self.onChange = onChange
    }

    private var currentAsset: ImmichAsset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    private var backgroundOpacity: Double {
        max(0, 1 - Double(abs(dismissOffset) / 400))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                // `assets.indices` avoids the `Array(assets.enumerated())`
                // allocation that would fire on every body render. Length is
                // stable during viewing (trash dismisses the viewer); favorite
                // toggle mutates in place so SwiftUI diffs the same page view.
                ForEach(assets.indices, id: \.self) { index in
                    let asset = assets[index]
                    Group {
                        if asset.isVideo {
                            VideoPlayerView(asset: asset)
                        } else if asset.isLivePhoto {
                            LivePhotoPage(asset: asset, onTap: toggleChrome, playSignal: livePlayRequested)
                        } else {
                            ZoomablePhotoPage(
                                asset: asset,
                                isZoomed: $isZoomed,
                                onTap: toggleChrome
                            )
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissOffset)

            if chromeVisible {
                chrome
                    .transition(.opacity)
                navigationChevrons
                    .transition(.opacity)
            }
            if showCompactExif, let asset = currentAsset {
                compactExifPill(asset)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .onChange(of: currentIndex) { _, _ in
            if let asset = currentAsset {
                session.saveLastViewedAsset(id: asset.id)
            }
        }
        .onAppear {
            if let asset = currentAsset {
                session.saveLastViewedAsset(id: asset.id)
            }
        }
        // Simultaneous (not high-priority) so TabView's internal horizontal
        // paging gesture still wins horizontal swipes. The dismiss gesture
        // only engages when the user drags vertically and is not zoomed.
        .simultaneousGesture(dismissDrag)
        .sheet(isPresented: $showInfo) {
            if let asset = currentAsset {
                ExifSheet(asset: asset)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.black)
            }
        }
        .alert("Read-only mode is on", isPresented: $showReadOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Disable read-only mode in Profile to perform this action.")
        }
        .fullScreenCover(item: $stackToShow) { presentation in
            StackDetailView(stackId: presentation.stackId, primaryAsset: presentation.asset)
        }
        .sheet(item: $documentExportURL) { url in
            DocumentPicker(fileURL: url)
        }
        .sheet(item: $shareImage) { wrapper in
            ActivityShareSheet(items: [wrapper.image])
        }
        .alert("Could not load image", isPresented: $shareFailed) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showSharedLinkSheet) {
            if let asset = currentAsset {
                SharedLinkCreateView(linkType: .individual, assetIds: [asset.id])
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.black)
            }
        }
        .fullScreenCover(item: $editingAsset) { asset in
            EditingView(asset: asset)
        }
        .fullScreenCover(item: $similarAsset) { asset in
            SimilarPhotosView(reference: asset)
        }
        .sheet(item: $printAsset) { asset in
            PrintPrepView(asset: asset)
                .presentationDetents([.large])
                .presentationBackground(.black)
        }
    }

    // MARK: - Gestures

    private var dismissDrag: some Gesture {
        // `minimumDistance: 30` gives TabView's internal paging a chance to
        // claim horizontal swipes before this gesture engages.
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard !isZoomed,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { _ in
                if abs(dismissOffset) > 100 {
                    dismiss()
                } else {
                    withAnimation(.spring) { dismissOffset = 0 }
                }
            }
    }

    // MARK: - Navigation chevrons (prev/next)

    @ViewBuilder
    private var navigationChevrons: some View {
        HStack {
            Button { advance(-1) } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(currentIndex > 0 ? 0.6 : 0.15))
            }
            .disabled(currentIndex == 0)
            .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .accessibilityLabel("Previous photo")

            Spacer()

            Button { advance(1) } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(currentIndex < assets.count - 1 ? 0.6 : 0.15))
            }
            .disabled(currentIndex >= assets.count - 1)
            .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .accessibilityLabel("Next photo")
        }
        .padding(.horizontal, Spacing.md)
    }

    private func advance(_ delta: Int) {
        let target = currentIndex + delta
        guard assets.indices.contains(target) else { return }
        HapticManager.selection()
        withAnimation(.easeInOut(duration: 0.2)) { currentIndex = target }
    }

    // MARK: - Compact EXIF pill

    private func compactExifPill(_ asset: ImmichAsset) -> some View {
        VStack {
            Spacer()
            Text(compactExifText(asset))
                .font(Typography.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity)
    }

    private func compactExifText(_ asset: ImmichAsset) -> String {
        var parts: [String] = []
        if let exif = asset.exifInfo {
            if let m = exif.model { parts.append(m) }
            if let f = exif.focalLength { parts.append("\(Int(f))mm") }
            if let n = exif.fNumber { parts.append("f/\(String(format: "%.1f", n))") }
            if let iso = exif.iso { parts.append("ISO \(iso)") }
        }
        return parts.isEmpty ? "No EXIF" : parts.joined(separator: " · ")
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            VStack(spacing: Spacing.sm) {
                if let asset = currentAsset, !asset.isVideo {
                    starRatingRow(asset)
                }
                bottomBar
            }
        }
    }

    /// Five tappable stars. Tapping star N sets the rating to N; tapping the
    /// current rating clears it (sends 0). Optimistic, reverts on API failure.
    private func starRatingRow(_ asset: ImmichAsset) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    setRating(for: asset, to: star == asset.ratingValue ? 0 : star)
                } label: {
                    Image(systemName: star <= asset.ratingValue ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(star <= asset.ratingValue
                                         ? Color(.systemYellow) : Color.phosphorSecondary)
                        .scaleEffect(star == asset.ratingValue ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6),
                                   value: asset.ratingValue)
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star <= asset.ratingValue ? .isSelected : [])
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.sm)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    private func setRating(for asset: ImmichAsset, to value: Int) {
        guard let i = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let previous = assets[i].rating
        HapticManager.selection()
        withAnimation { assets[i].rating = value }
        Task {
            do {
                _ = try await ImmichAPI.shared.setRating(assetId: asset.id, rating: value)
            } catch {
                if let j = assets.firstIndex(where: { $0.id == asset.id }) {
                    assets[j].rating = previous   // revert on failure
                }
                HapticManager.notification(.error)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: Spacing.l) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .accessibilityLabel("Close")

            Spacer()

            if let asset = currentAsset {
                Text(asset.originalFileName)
                    .font(Typography.subheadline)
                    .lineLimit(1)
                    .accessibilityLabel("Current photo: \(asset.originalFileName)")
            }

            Spacer()

            if let asset = currentAsset {
                if let stackId = asset.stackId {
                    Button {
                        stackToShow = StackPresentation(stackId: stackId, asset: asset)
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                    .accessibilityLabel("View stack")
                }

                Button {
                    startShare(asset)
                } label: {
                    if isLoadingShare {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.phosphorPrimary)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .disabled(isLoadingShare)
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                .accessibilityLabel("Share")

                Menu {
                    favoriteButton(asset)
                    Button {
                        Task { await toggleArchive(asset) }
                    } label: {
                        Label(
                            asset.isArchived ? "Unarchive" : "Archive",
                            systemImage: asset.isArchived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    Button {
                        Task { await downloadOriginal(asset) }
                    } label: {
                        Label("Download Original", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showSharedLinkSheet = true
                    } label: {
                        Label("Share Link", systemImage: "link")
                    }
                    Button { Task { await copyToClipboard(asset) } } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button { Task { await useAsWallpaper(asset) } } label: {
                        Label("Use as Wallpaper", systemImage: "photo.tv")
                    }
                    Button { Task { await saveToFiles(asset) } } label: {
                        Label("Save to Files", systemImage: "folder")
                    }
                    if !asset.isVideo {
                        Button { editingAsset = asset } label: {
                            Label("Edit Photo", systemImage: "slider.horizontal.3")
                        }
                        Button { printAsset = asset } label: {
                            Label("Prepare for Print", systemImage: "printer")
                        }
                    }
                    Button { similarAsset = asset } label: {
                        Label("Find Similar", systemImage: "rectangle.on.rectangle")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showCompactExif.toggle()
                        }
                    } label: {
                        Label(showCompactExif ? "Hide EXIF" : "Show EXIF", systemImage: "info.circle")
                    }
                    Button(role: .destructive) {
                        guard !isReadOnly else {
                            showReadOnlyAlert = true
                            return
                        }
                        HapticManager.impact(.heavy)
                        HapticManager.notification(.warning)
                        trash(asset)
                    } label: {
                        Label(
                            isReadOnly ? "Trash (Locked)" : "Trash",
                            systemImage: isReadOnly ? "lock" : "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                .accessibilityLabel("More options")
            }
        }
        .foregroundStyle(.phosphorPrimary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            if let asset = currentAsset {
                favoriteToolbarButton(asset)
                Button {
                    startShare(asset)
                } label: {
                    if isLoadingShare {
                        VStack(spacing: 2) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.phosphorPrimary)
                            Text("Share")
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorPrimary)
                        }
                        .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                    } else {
                        toolbarIcon("square.and.arrow.up", label: "Share")
                    }
                }
                .disabled(isLoadingShare)
                .accessibilityLabel("Share")
                contextualMiddleButton(asset)
                Button { showInfo = true } label: {
                    toolbarIcon("info.circle", label: "Info")
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                .accessibilityLabel("Photo info")
                .accessibilityHint("Shows EXIF metadata and location.")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    // MARK: - Contextual toolbar pieces

    private func favoriteToolbarButton(_ asset: ImmichAsset) -> some View {
        Button {
            HapticManager.impact(.medium)
            HapticManager.notification(.success)
            flipFavorite(asset)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(asset.isFavorite ? .phosphorDanger : .phosphorPrimary)
                    .scaleEffect(asset.isFavorite ? 1.15 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.55),
                               value: asset.isFavorite)
                Text(asset.isFavorite ? "Saved" : "Favorite")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorPrimary)
            }
        }
        .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
        .accessibilityLabel(asset.isFavorite ? "Unfavorite" : "Favorite")
    }

    private func toolbarIcon(_ symbol: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.phosphorPrimary)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(.phosphorPrimary)
        }
        .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
    }

    /// Middle slot adapts to asset type. **Only buttons whose action is
    /// fully implemented appear here** — no Trim/Edit dead buttons.
    @ViewBuilder
    private func contextualMiddleButton(_ asset: ImmichAsset) -> some View {
        if asset.isVideo {
            // "Save" — promoted from More menu.
            Button {
                Task { await downloadOriginal(asset) }
            } label: {
                toolbarIcon("square.and.arrow.down", label: "Save")
            }
            .accessibilityLabel("Save video to camera roll")
        } else if asset.isLivePhoto {
            // "Play Motion" — taps a published flag that LivePhotoPage listens
            // to via `livePlayRequested` env value.
            Button {
                livePlayRequested = UUID()
            } label: {
                toolbarIcon("livephoto.play", label: "Motion")
            }
            .accessibilityLabel("Play live photo motion")
        } else if asset.stackId != nil {
            Button {
                if let stackId = asset.stackId {
                    stackToShow = StackPresentation(stackId: stackId, asset: asset)
                }
            } label: {
                toolbarIcon("square.stack.3d.up", label: "Stack")
            }
            .accessibilityLabel("View stack")
        } else {
            // Plain photo — promote Copy from More menu.
            Button {
                Task { await copyToClipboard(asset) }
            } label: {
                toolbarIcon("doc.on.doc", label: "Copy")
            }
            .accessibilityLabel("Copy photo to clipboard")
        }
    }

    private func favoriteButton(_ asset: ImmichAsset) -> some View {
        Button {
            flipFavorite(asset)
        } label: {
            Label(
                asset.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: asset.isFavorite ? "heart.slash" : "heart"
            )
        }
    }

    // MARK: - Actions

    private func flipFavorite(_ asset: ImmichAsset) {
        guard let i = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let original = assets[i]
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            assets[i].isFavorite.toggle()
        }
        Task {
            do {
                let updated = try await ImmichAPI.shared.toggleFavorite(asset: original)
                if let j = assets.firstIndex(where: { $0.id == updated.id }) {
                    assets[j] = updated
                }
                onChange?(.favorited(updated))
            } catch {
                if let j = assets.firstIndex(where: { $0.id == original.id }) {
                    assets[j] = original
                }
                HapticManager.notify(.error)
            }
        }
    }

    private func toggleArchive(_ asset: ImmichAsset) async {
        guard let i = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let original = assets[i]
        do {
            let updated = try await ImmichAPI.shared.toggleArchive(asset: original)
            if let j = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[j] = updated
            }
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func trash(_ asset: ImmichAsset) {
        Task {
            do {
                try await ImmichAPI.shared.trashAssets(ids: [asset.id])
                onChange?(.trashed(asset.id))
                dismiss()
            } catch {
                HapticManager.notify(.error)
            }
        }
    }

    private func downloadOriginal(_ asset: ImmichAsset) async {
        guard let image = await ImageLoader.shared.fullImage(for: asset.id) else {
            HapticManager.notify(.error)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            HapticManager.notify(.success)
        } catch {
            HapticManager.notify(.error)
        }
    }

    private func copyToClipboard(_ asset: ImmichAsset) async {
        if let image = await ImageLoader.shared.fullImage(for: asset.id) {
            UIPasteboard.general.image = image
            HapticManager.notification(.success)
        } else {
            HapticManager.notification(.error)
        }
    }

    /// Saves to the camera roll then opens Settings → Wallpaper. iOS no longer
    /// permits direct wallpaper setting from third-party apps.
    private func useAsWallpaper(_ asset: ImmichAsset) async {
        guard let image = await ImageLoader.shared.fullImage(for: asset.id) else {
            HapticManager.notification(.error)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            if let settings = URL(string: "App-Prefs:Wallpaper") {
                await UIApplication.shared.open(settings)
            }
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func startShare(_ asset: ImmichAsset) {
        guard !isLoadingShare else { return }
        isLoadingShare = true
        Task {
            let image = await ImageLoader.shared.fullImage(for: asset.id)
            isLoadingShare = false
            if let image {
                shareImage = SharedImage(image: image)
            } else {
                shareFailed = true
                HapticManager.notification(.error)
            }
        }
    }

    private func saveToFiles(_ asset: ImmichAsset) async {
        guard let image = await ImageLoader.shared.fullImage(for: asset.id),
              let data = image.jpegData(compressionQuality: 0.95)
        else {
            HapticManager.notification(.error); return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(asset.originalFileName.isEmpty ? "photo.jpg" : asset.originalFileName)
        do {
            try data.write(to: tmp)
            documentExportURL = tmp
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func exifSummary(_ asset: ImmichAsset) -> String {
        guard let exif = asset.exifInfo else { return asset.originalFileName }
        var parts: [String] = []
        if let model = exif.model { parts.append(model) }
        if let focal = exif.focalLength { parts.append("\(Int(focal))mm") }
        if let f = exif.fNumber { parts.append("f/\(String(format: "%.1f", f))") }
        return parts.isEmpty ? asset.originalFileName : parts.joined(separator: " · ")
    }
}

// MARK: - Zoomable page

private struct ZoomablePhotoPage: View {
    let asset: ImmichAsset
    @Binding var isZoomed: Bool
    let onTap: () -> Void

    @State private var thumbImage: UIImage?
    @State private var fullImage: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Deep-zoom (collage) state. All additive — the gesture priority stack is
    // untouched; this only swaps the displayed image past a zoom threshold.
    @State private var collageSidecar: CollageSidecar?
    @State private var deepZoomImage: UIImage?
    @State private var isLoadingDeepZoom = false
    @State private var viewSize: CGSize = .zero

    /// Best image we have so far: deep-zoom cell image when active, then
    /// full-res, then thumbnail.
    private var displayImage: UIImage? { deepZoomImage ?? fullImage ?? thumbImage }

    var body: some View {
        ZStack {
            Color.phosphorBackground
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    // Crossfade thumb → full → deep-zoom cell without a flash.
                    .animation(.easeInOut(duration: 0.2), value: fullImage != nil)
                    .animation(.easeInOut(duration: 0.25), value: deepZoomImage != nil)
                    .gesture(magnification.simultaneously(with: pan))
                    .simultaneousGesture(doubleTapZoom)
                    .onTapGesture { onTap() }
                    .accessibilityLabel(asset.originalFileName)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityHint("Pinch to zoom, double-tap area to show or hide controls.")
                    .accessibilityZoomAction { action in
                        switch action.direction {
                        case .zoomIn:
                            withAnimation(.spring) { scale = min(scale * 2, 10) }
                        case .zoomOut:
                            withAnimation(.spring) {
                                scale = max(scale / 2, 1)
                                if scale == 1 { offset = .zero; lastOffset = .zero }
                            }
                        @unknown default:
                            break
                        }
                        lastScale = scale
                        isZoomed = scale > 1
                    }
            } else {
                ProgressView().tint(.phosphorPrimary)
            }
        }
        .ignoresSafeArea()
        // Additive: capture the view's pixel size so the deep-zoom anchor
        // (view-space UnitPoint) can be corrected for the .scaledToFit
        // letterbox before mapping into image coordinates.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { _, new in viewSize = new }
            }
        )
        .task(id: asset.id) {
            // Progressive: paint the (usually cached) thumbnail first, then
            // upgrade to full resolution.
            thumbImage = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
            fullImage = await ImageLoader.shared.fullImage(for: asset.id)
            // If this asset is an exported collage, it has a sidecar — enable
            // deep zoom into its cells.
            collageSidecar = CollageSidecarStore.sidecarForUploadedAsset(asset.id)
            deepZoomImage = nil
        }
    }

    /// Loads the full-resolution source image for whichever collage cell sits
    /// under `anchor` (a UnitPoint in the visible image), cropped to that
    /// cell's region. Guards against concurrent loads.
    private func loadDeepZoom(anchor: UnitPoint) async {
        guard let sidecar = collageSidecar,
              deepZoomImage == nil,
              !isLoadingDeepZoom
        else { return }
        isLoadingDeepZoom = true
        defer { isLoadingDeepZoom = false }

        // `anchor` is a UnitPoint in VIEW space. The collage is drawn
        // .scaledToFit, so it's letterboxed inside the view. Convert:
        //   view-unit → view-px → subtract letterbox origin → fitted-image
        //   normalized → canvas px.
        let imgAspect = sidecar.canvasSize.width / max(sidecar.canvasSize.height, 1)
        let vw = max(viewSize.width, 1)
        let vh = max(viewSize.height, 1)
        let viewAspect = vw / vh
        let fitted: CGRect
        if imgAspect >= viewAspect {
            let fh = vw / imgAspect
            fitted = CGRect(x: 0, y: (vh - fh) / 2, width: vw, height: fh)
        } else {
            let fw = vh * imgAspect
            fitted = CGRect(x: (vw - fw) / 2, y: 0, width: fw, height: vh)
        }
        let viewPoint = CGPoint(x: anchor.x * vw, y: anchor.y * vh)
        // Reject taps on the letterbox bars (no cell there).
        guard fitted.contains(viewPoint), fitted.width > 0, fitted.height > 0 else { return }
        let normX = (viewPoint.x - fitted.minX) / fitted.width
        let normY = (viewPoint.y - fitted.minY) / fitted.height
        let point = CGPoint(
            x: normX * sidecar.canvasSize.width,
            y: normY * sidecar.canvasSize.height
        )
        guard let resolved = CollageDeepZoom.resolve(sidecar: sidecar, pointInImage: point),
              let source = await ImageLoader.shared.fullImage(for: resolved.assetId),
              let cg = source.cgImage
        else { return }

        // Crop the source to the cell's normalized crop rect.
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let cropPx = CGRect(
            x: resolved.cropRect.minX * w,
            y: resolved.cropRect.minY * h,
            width: resolved.cropRect.width * w,
            height: resolved.cropRect.height * h
        ).integral
        guard cropPx.width >= 1, cropPx.height >= 1,
              let cropped = cg.cropping(to: cropPx)
        else { return }
        // Only commit if the user is still zoomed in (they may have released).
        guard scale >= 3.0 else { return }
        deepZoomImage = UIImage(cgImage: cropped, scale: source.scale, orientation: source.imageOrientation)
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 10)
                isZoomed = scale > 1
                // --- Deep-zoom switching (additive; gesture stack untouched) ---
                if collageSidecar != nil {
                    if scale >= 3.0, deepZoomImage == nil, !isLoadingDeepZoom {
                        let anchor = value.startAnchor
                        Task { await loadDeepZoom(anchor: anchor) }
                    } else if scale < 2.5, deepZoomImage != nil {
                        deepZoomImage = nil   // crossfade back to the collage
                    }
                }
            }
            .onEnded { _ in
                if scale <= 1 {
                    withAnimation(.spring) {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                    lastScale = 1
                } else {
                    lastScale = scale
                }
                isZoomed = scale > 1
                if scale < 2.5, deepZoomImage != nil {
                    deepZoomImage = nil
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                lastOffset = offset
            }
    }

    /// Double-tap to toggle between 1× and 3× zoom. When zooming in, centers
    /// the tap location by translating the image so the tapped point ends up
    /// where the view's center was.
    private var doubleTapZoom: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if scale > 1 {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                        lastScale = 1
                    } else {
                        let viewCenter = CGPoint(
                            x: viewSize.width / 2,
                            y: viewSize.height / 2
                        )
                        let zoomedScale: CGFloat = 3
                        let dx = (viewCenter.x - value.location.x) * (zoomedScale - 1)
                        let dy = (viewCenter.y - value.location.y) * (zoomedScale - 1)
                        offset = CGSize(width: dx, height: dy)
                        lastOffset = offset
                        scale = zoomedScale
                        lastScale = zoomedScale
                    }
                }
                isZoomed = scale > 1
            }
    }
}

// MARK: - Share helpers

private struct SharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Stack presentation

/// Identifiable wrapper so the stack viewer can be driven by
/// `.fullScreenCover(item:)`.
struct StackPresentation: Identifiable {
    let id = UUID()
    let stackId: String
    let asset: ImmichAsset
}

// MARK: - Live Photo page

/// Renders an Immich Live Photo by downloading both the still and the paired
/// video to temp files and composing a `PHLivePhoto`. Falls back to the still
/// image if composition fails. Long-press plays the motion.
private struct LivePhotoPage: View {
    let asset: ImmichAsset
    let onTap: () -> Void
    /// Changes whenever the parent's "Motion" toolbar button is tapped.
    let playSignal: UUID

    @State private var livePhoto: PHLivePhoto?
    @State private var stillImage: UIImage?
    @State private var isLoading = true
    @State private var playToken: UUID = UUID()

    var body: some View {
        ZStack {
            Color.phosphorBackground
            if let livePhoto {
                LivePhotoRepresentable(livePhoto: livePhoto, playToken: playToken)
                    .accessibilityLabel("Live Photo: \(asset.originalFileName)")
                    .accessibilityHint("Touch and hold to play the motion.")
            } else if let stillImage {
                Image(uiImage: stillImage)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView().tint(.phosphorPrimary)
            }

            VStack {
                HStack {
                    Label("LIVE", systemImage: "livephoto")
                        .font(Typography.captionBold)
                        .foregroundStyle(.phosphorPrimary)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xs)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                }
                Spacer()
            }
            .padding(Spacing.l)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: asset.id) { await loadLivePhoto() }
        .onChange(of: playSignal) { _, new in
            playToken = new
        }
    }

    private func loadLivePhoto() async {
        isLoading = true
        defer { isLoading = false }

        // Still first so something paints immediately.
        stillImage = await ImageLoader.shared.fullImage(for: asset.id)

        guard let videoId = asset.livePhotoVideoId,
              let stillURL = ImmichAPI.shared.originalURL(id: asset.id),
              let videoURL = ImmichAPI.shared.videoPlaybackURL(for: videoId)
        else { return }

        do {
            let imageFile = try await downloadToTemp(stillURL, ext: "heic", authHeader: true)
            let videoFile = try await downloadToTemp(videoURL, ext: "mov", authHeader: false)
            livePhoto = await composeLivePhoto(imageURL: imageFile, videoURL: videoFile)
        } catch {
            // Fall back to the still image already shown.
        }
    }

    private func downloadToTemp(_ url: URL, ext: String, authHeader: Bool) async throws -> URL {
        var request = URLRequest(url: url)
        if authHeader {
            request = try ImmichAPI.shared.authorizedImageRequest(for: url)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: dest)
        return dest
    }

    private func composeLivePhoto(imageURL: URL, videoURL: URL) async -> PHLivePhoto? {
        await withCheckedContinuation { cont in
            PHLivePhoto.request(
                withResourceFileURLs: [imageURL, videoURL],
                placeholderImage: stillImage,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { live, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.resume(returning: live) }
            }
        }
    }
}

private struct LivePhotoRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    /// Changes whenever the parent wants the motion to play again (via the
    /// "Motion" toolbar button or a long-press).
    let playToken: UUID

    final class Coordinator { var lastToken: UUID = UUID() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        context.coordinator.lastToken = playToken
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
        if context.coordinator.lastToken != playToken {
            context.coordinator.lastToken = playToken
            view.startPlayback(with: .full)
        }
    }
}

// MARK: - EXIF sheet

private struct ExifSheet: View {
    let asset: ImmichAsset

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                listContent
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: asset.id) { await computeHistogram() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var listContent: some View {
        if let coordinate {
            locationSection(coordinate: coordinate)
        }
        captureSection
        fileSection
        if let histogram {
            histogramSection(histogram: histogram)
        }
        if let city = asset.exifInfo?.city, !city.isEmpty {
            nearbySection(city: city)
        }
        onThisDaySection
    }

    @ViewBuilder
    private func locationSection(coordinate: CLLocationCoordinate2D) -> some View {
        Section {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker("Location", coordinate: coordinate)
            }
            .frame(height: 160)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        Section { captureSectionContent } header: { Text("Capture") }
    }

    @ViewBuilder
    private var captureSectionContent: some View {
        if hasCaptureMetadata {
            row("Camera", camera)
            row("Lens", asset.exifInfo?.lensModel)
            row("Focal Length", asset.exifInfo?.focalLength.map { "\(Int($0))mm" })
            row("Aperture", asset.exifInfo?.fNumber.map { "f/\(String(format: "%.1f", $0))" })
            row("ISO", asset.exifInfo?.iso.map(String.init))
            row("Exposure", asset.exifInfo?.exposureTime)
        } else {
            Text("No metadata available")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .listRowBackground(Color.phosphorSurface)
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        Section {
            row("Name", asset.originalFileName)
            row("Taken", Self.dateFormatter.string(from: asset.localDateTime))
            row("Location", [asset.exifInfo?.city, asset.exifInfo?.state, asset.exifInfo?.country]
                .compactMap { $0 }
                .joined(separator: ", ")
                .nilIfEmpty)
        } header: {
            Text("File")
        }
    }

    @ViewBuilder
    private func histogramSection(histogram: Histogram.Data) -> some View {
        Section {
            InlineHistogramView(data: histogram)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.phosphorSurface)
        } header: {
            Text("Histogram")
        }
    }

    @ViewBuilder
    private func nearbySection(city: String) -> some View {
        Section {
            NearbyPhotosView(city: city, excludeAssetId: asset.id)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.phosphorSurface)
        }
    }

    @ViewBuilder
    private var onThisDaySection: some View {
        Section {
            OnThisDayRow(date: asset.localDateTime, excludeAssetId: asset.id)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.phosphorSurface)
        }
    }

    @State private var histogram: Histogram.Data?

    private func computeHistogram() async {
        guard histogram == nil,
              let image = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
        else { return }
        let computed = await Task.detached(priority: .utility) {
            Histogram.compute(from: image)
        }.value
        histogram = computed
    }

    private var camera: String? {
        let make = asset.exifInfo?.make
        let model = asset.exifInfo?.model
        return [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    private var hasCaptureMetadata: Bool {
        guard let e = asset.exifInfo else { return false }
        return camera != nil || e.lensModel != nil || e.focalLength != nil
            || e.fNumber != nil || e.iso != nil || (e.exposureTime?.isEmpty == false)
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = asset.exifInfo?.latitude,
              let lon = asset.exifInfo?.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.phosphorSecondary)
                Spacer()
                Text(value)
                    .foregroundStyle(.phosphorPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(Color.phosphorSurface)
            .accessibilityElement(children: .combine)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Compact RGB histogram visualization used in the photo info sheet. Reads
/// pre-computed bins rather than recomputing from a UIImage.
private struct InlineHistogramView: View {
    let data: Histogram.Data

    var body: some View {
        Canvas { ctx, size in
            draw(data.red, color: .red, size: size, ctx: &ctx)
            draw(data.green, color: .green, size: size, ctx: &ctx)
            draw(data.blue, color: .blue, size: size, ctx: &ctx)
        }
        .frame(height: 80)
        .background(Color.black.opacity(0.6))
        .accessibilityElement()
        .accessibilityLabel("RGB histogram")
        .accessibilityHint("Shows the tonal distribution of the image")
    }

    private func draw(_ bins: [UInt], color: Color, size: CGSize, ctx: inout GraphicsContext) {
        let maxV = max(bins.max() ?? 1, 1)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        let step = size.width / CGFloat(max(bins.count, 1))
        for i in 0..<bins.count {
            let h = size.height * CGFloat(Double(bins[i]) / Double(maxV))
            path.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.4)))
    }
}

// MARK: - Document picker bridge

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
