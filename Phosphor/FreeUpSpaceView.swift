import SwiftUI
import Photos
import UIKit

/// Lists local camera-roll assets confirmed present on the server and lets
/// the user delete them in bulk (or individually) to reclaim device space.
struct FreeUpSpaceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = BackupManager.shared

    @State private var assets: [PHAsset] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var isDeleting = false
    @State private var showDeleteAllConfirm = false

    private var totalBytes: Int64 {
        assets.reduce(Int64(0)) { partial, asset in
            partial + assetByteEstimate(asset)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Free Up Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !assets.isEmpty {
                        Button("Delete All", role: .destructive) {
                            showDeleteAllConfirm = true
                        }
                        .disabled(isDeleting)
                    }
                }
            }
            .task { if assets.isEmpty { await scan() } }
            .alert("Delete \(assets.count) local copies?",
                   isPresented: $showDeleteAllConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteAll() }
                }
            } message: {
                Text("Reclaims \(formattedBytes). These photos remain on your Immich server.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: Spacing.md) {
                ProgressView().tint(.phosphorAccent)
                Text("Checking which local photos are already on your server…")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
        } else if let scanError {
            VStack(spacing: Spacing.md) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text(scanError)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await scan() } }
                    .foregroundStyle(.phosphorAccent)
            }
            .padding(Spacing.xl)
        } else if assets.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("Nothing to free up — no local photos match what's on the server.")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xl)
        } else {
            List {
                Section {
                    HStack {
                        Text("Total reclaimable")
                            .foregroundStyle(.phosphorSecondary)
                        Spacer()
                        Text(formattedBytes)
                            .font(Typography.headline)
                            .foregroundStyle(.phosphorPrimary)
                    }
                    .listRowBackground(Color.phosphorSurface)
                }
                Section {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        FreeUpRow(asset: asset)
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            let asset = assets[offset]
                            Task { await deleteIndividual(asset) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var formattedBytes: String {
        StorageFormatter.string(fromBytes: totalBytes)
    }

    private func assetByteEstimate(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        for resource in resources {
            if let value = resource.value(forKey: "fileSize") as? Int64 {
                return value
            }
        }
        return 0
    }

    private func scan() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        let status = await BackupManager.requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else {
            scanError = "Photos access is required to scan local copies."
            return
        }
        assets = await manager.findLocalAssetsAlreadyOnServer()
    }

    private func deleteAll() async {
        guard !assets.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let snapshot = assets
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(snapshot as NSArray)
            }
            HapticManager.notification(.success)
            assets = []
            dismiss()
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func deleteIndividual(_ asset: PHAsset) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            assets.removeAll { $0.localIdentifier == asset.localIdentifier }
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

private struct FreeUpRow: View {
    let asset: PHAsset
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color.phosphorPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .lineLimit(1)
                Text(StorageFormatter.string(fromBytes: byteSize))
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            Spacer()
        }
        .listRowBackground(Color.phosphorSurface)
        .task(id: asset.localIdentifier) { await loadThumb() }
    }

    private var displayName: String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename
            ?? asset.localIdentifier
    }

    private var byteSize: Int64 {
        for resource in PHAssetResource.assetResources(for: asset) {
            if let value = resource.value(forKey: "fileSize") as? Int64 {
                return value
            }
        }
        return 0
    }

    private func loadThumb() async {
        let manager = PHCachingImageManager()
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isSynchronous = false
        options.resizeMode = .fast
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 112, height: 112),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                thumb = image
                cont.resume()
            }
        }
    }
}
