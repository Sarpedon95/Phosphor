import SwiftUI
import Photos
import UIKit

/// Browseable iOS Photos library — all photos and smart albums including
/// Hidden, grouped by month. Multi-select → manual upload via the existing
/// BackupManager pipeline. Mirrors the look of the Immich timeline so the
/// two halves of the app feel like one library.
struct PhonePhotosView: View {
    @StateObject private var model = PhonePhotosModel()
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var showAlbumPicker = false
    @State private var isUploading = false
    @State private var uploadMessage: String?

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            switch model.permission {
            case .authorized, .limited:
                content
            default:
                permissionView
            }
        }
        .navigationTitle(model.currentAlbumTitle ?? "Device Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if model.permission == .authorized || model.permission == .limited {
                    Button {
                        showAlbumPicker = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("Choose album")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !model.assets.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        HapticManager.selection()
                        if isSelecting {
                            isSelecting = false
                            selectedIds.removeAll()
                        } else {
                            isSelecting = true
                        }
                    }
                }
            }
        }
        .task { await model.bootstrap() }
        .sheet(isPresented: $showAlbumPicker) {
            albumPicker
        }
        .overlay(alignment: .bottom) {
            if isSelecting && !selectedIds.isEmpty {
                uploadBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: isSelecting && !selectedIds.isEmpty)
        .alert("Upload",
               isPresented: Binding(
                get: { uploadMessage != nil },
                set: { if !$0 { uploadMessage = nil } }
               ),
               presenting: uploadMessage) { _ in
            Button("OK", role: .cancel) { uploadMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.phosphorSecondary)
            Text("Photos access needed")
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)
            Text("Grant Phosphor Full Library access to see and upload your iOS Photos, including the Hidden album.")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(Typography.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.sm)
            .background(Color.phosphorAccent, in: Capsule())
        }
    }

    // MARK: - Content

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.assets.isEmpty {
            ProgressView().tint(.phosphorAccent)
        } else if model.assets.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No photos here")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups, id: \.id) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(group.assets, id: \.localIdentifier) { asset in
                                    cell(asset)
                                }
                            }
                            .padding(.bottom, Spacing.md)
                        } header: {
                            sectionHeader(group)
                        }
                    }
                }
                .padding(.bottom, isSelecting && !selectedIds.isEmpty ? 80 : 0)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func cell(_ asset: PHAsset) -> some View {
        let isSel = selectedIds.contains(asset.localIdentifier)
        PHAssetThumb(asset: asset)
            .overlay {
                if isSelecting {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(isSel ? 0.45 : 0.001)
                        Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            }
            .onTapGesture {
                if isSelecting { toggle(asset.localIdentifier) }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                if !isSelecting {
                    HapticManager.impact(.medium)
                    isSelecting = true
                    selectedIds.insert(asset.localIdentifier)
                }
            }
    }

    private func sectionHeader(_ group: PhonePhotosModel.Group) -> some View {
        HStack {
            Text(group.title)
                .font(Typography.title3)
                .foregroundStyle(.phosphorPrimary)
            Spacer()
            Text("\(group.assets.count)")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.phosphorBackground)
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    // MARK: - Upload bar

    private var uploadBar: some View {
        HStack {
            Text("\(selectedIds.count) selected")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
            Spacer()
            Button {
                Task { await upload() }
            } label: {
                ZStack {
                    Capsule().fill(Color.phosphorAccent)
                    if isUploading {
                        ProgressView().tint(.black)
                    } else {
                        Text("Upload")
                            .font(Typography.headline)
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 110, height: 40)
            }
            .disabled(isUploading)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func upload() async {
        guard !selectedIds.isEmpty else { return }
        let ids = Array(selectedIds)
        isUploading = true
        defer { isUploading = false }
        let (ok, fail) = await BackupManager.shared.uploadAssets(withLocalIDs: ids)
        let okWord = ok == 1 ? "photo" : "photos"
        if fail == 0 {
            uploadMessage = "Uploaded \(ok) \(okWord)."
            HapticManager.notification(.success)
        } else {
            uploadMessage = "Uploaded \(ok) \(okWord). \(fail) failed."
            HapticManager.notification(.warning)
        }
        selectedIds.removeAll()
        isSelecting = false
    }

    // MARK: - Album picker

    private var albumPicker: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                List {
                    Section {
                        albumRow(title: "All Photos", symbol: "photo.stack", id: nil)
                    }
                    if !userAlbums.isEmpty {
                        Section("My Albums") {
                            ForEach(userAlbums, id: \.localIdentifier) { coll in
                                albumRow(title: coll.localizedTitle ?? "Untitled",
                                         symbol: "rectangle.stack",
                                         id: coll.localIdentifier)
                            }
                        }
                    }
                    if !smartAlbums.isEmpty {
                        Section("Smart Albums") {
                            ForEach(smartAlbums, id: \.localIdentifier) { coll in
                                albumRow(title: coll.localizedTitle ?? "Untitled",
                                         symbol: PhonePhotosView.symbol(for: coll),
                                         id: coll.localIdentifier)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Choose album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAlbumPicker = false }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func albumRow(title: String, symbol: String, id: String?) -> some View {
        Button {
            model.selectedAlbumId = id
            model.load()
            showAlbumPicker = false
        } label: {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(.phosphorAccent)
                Text(title)
                    .foregroundStyle(.phosphorPrimary)
                Spacer()
                if model.selectedAlbumId == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .listRowBackground(Color.phosphorSurface)
    }

    private var userAlbums: [PHAssetCollection] {
        model.albumChoices.filter { $0.assetCollectionType == .album }
    }
    private var smartAlbums: [PHAssetCollection] {
        model.albumChoices.filter { $0.assetCollectionType == .smartAlbum }
    }

    static func symbol(for coll: PHAssetCollection) -> String {
        switch coll.assetCollectionSubtype {
        case .smartAlbumHidden: return "eye.slash"
        case .smartAlbumFavorites: return "heart"
        case .smartAlbumScreenshots: return "camera.viewfinder"
        case .smartAlbumSelfPortraits: return "person.crop.square"
        case .smartAlbumLivePhotos: return "livephoto"
        case .smartAlbumVideos: return "video"
        case .smartAlbumSlomoVideos: return "slowmo"
        case .smartAlbumTimelapses: return "timelapse"
        case .smartAlbumPanoramas: return "pano"
        case .smartAlbumLongExposures: return "circle.dashed"
        case .smartAlbumAnimated: return "play.rectangle"
        case .smartAlbumBursts: return "square.stack.3d.up"
        case .smartAlbumDepthEffect: return "cube"
        case .smartAlbumRecentlyAdded: return "clock"
        default: return "rectangle.stack"
        }
    }
}

// MARK: - Model

@MainActor
final class PhonePhotosModel: ObservableObject {
    struct Group: Identifiable {
        let id: String
        let title: String
        let assets: [PHAsset]
    }

    @Published var selectedAlbumId: String?
    @Published private(set) var albumChoices: [PHAssetCollection] = []
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var groups: [Group] = []
    @Published private(set) var permission: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading = false

    var currentAlbumTitle: String? {
        guard let id = selectedAlbumId,
              let coll = albumChoices.first(where: { $0.localIdentifier == id })
        else { return nil }
        return coll.localizedTitle
    }

    func bootstrap() async {
        permission = await BackupManager.requestPhotoLibraryAccess()
        guard permission == .authorized || permission == .limited else { return }
        loadAlbumChoices()
        load()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.includeHiddenAssets = true
        let result: PHFetchResult<PHAsset>
        if let id = selectedAlbumId,
           let coll = albumChoices.first(where: { $0.localIdentifier == id }) {
            result = PHAsset.fetchAssets(in: coll, options: opts)
        } else {
            result = PHAsset.fetchAssets(with: opts)
        }
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        regroup()
    }

    private func loadAlbumChoices() {
        var albums: [PHAssetCollection] = []
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        userAlbums.enumerateObjects { coll, _, _ in albums.append(coll) }
        let smartTypes: [PHAssetCollectionSubtype] = [
            .smartAlbumHidden, .smartAlbumFavorites, .smartAlbumScreenshots,
            .smartAlbumSelfPortraits, .smartAlbumLivePhotos, .smartAlbumVideos,
            .smartAlbumSlomoVideos, .smartAlbumTimelapses,
            .smartAlbumPanoramas, .smartAlbumLongExposures,
            .smartAlbumAnimated, .smartAlbumBursts, .smartAlbumDepthEffect,
            .smartAlbumRecentlyAdded
        ]
        for s in smartTypes {
            let r = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: s, options: nil
            )
            r.enumerateObjects { c, _, _ in albums.append(c) }
        }
        albumChoices = albums
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private func regroup() {
        let cal = Calendar.current
        var order: [String] = []
        var byKey: [String: [PHAsset]] = [:]
        var titleByKey: [String: String] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let comps = cal.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = []
                titleByKey[key] = Self.monthFormatter.string(from: date)
            }
            byKey[key]?.append(asset)
        }
        groups = order.map { key in
            Group(id: key, title: titleByKey[key] ?? key, assets: byKey[key] ?? [])
        }
    }
}

// MARK: - Thumbnail cell

private struct PHAssetThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?

    private static let manager = PHCachingImageManager()

    /// `PHImageRequestOptions.deliveryMode = .opportunistic` calls the
    /// callback 1+ times (blurry then sharp). We let SwiftUI re-render on
    /// each `image` change rather than wrap it in an awaited continuation,
    /// which would risk a leak if the cell unmounts mid-fetch.
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.phosphorPlaceholder
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                }
                badges
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
            .contentShape(Rectangle())
            .onAppear { request(size: geo.size.width) }
            .onDisappear { cancel() }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var badges: some View {
        VStack {
            HStack {
                if asset.isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                Spacer()
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            Spacer()
            HStack {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                Spacer()
            }
        }
        .padding(5)
    }

    private func request(size: CGFloat) {
        let scale = UIScreen.main.scale
        let target = CGSize(width: size * scale, height: size * scale)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        requestID = Self.manager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: opts
        ) { result, _ in
            // Fires once for the blurry preview, once for the sharp result.
            self.image = result
        }
    }

    private func cancel() {
        if let requestID {
            Self.manager.cancelImageRequest(requestID)
        }
        requestID = nil
    }
}
