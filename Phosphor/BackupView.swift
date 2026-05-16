import SwiftUI
import Photos

struct BackupView: View {
    @StateObject private var manager = BackupManager.shared
    @State private var albums: [PHAssetCollection] = []
    @State private var selectedAlbumIDs: Set<String> = []
    @State private var showFreeUpAlert = false
    @State private var localAssetCount = 0
    @AppStorage(AppSettings.Keys.wifiOnlyBackup) private var wifiOnly: Bool = AppSettings.Defaults.wifiOnlyBackup
    @AppStorage(AppSettings.Keys.showStorageIndicator) private var showStorageIndicator: Bool = AppSettings.Defaults.showStorageIndicator
    @AppStorage(AppSettings.Keys.uploadThrottleKBps) private var throttleKBps: Int = AppSettings.Defaults.uploadThrottleKBps

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            List {
                resumeBanner
                statusSection
                controlsSection
                albumsSection
                settingsSection
                freeUpSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await loadAlbums()
            selectedAlbumIDs = manager.selectedAlbumIDs
        }
        .alert("Free up space?", isPresented: $showFreeUpAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Local Copies", role: .destructive) {
                Task { await freeUpSpace() }
            }
        } message: {
            Text("Local copies of \(manager.progress.completed) backed-up photos will be removed from this device. They remain on your Immich server.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var resumeBanner: some View {
        let pendingCount = manager.resumableQueue.count
        if pendingCount > 0, !manager.progress.isRunning {
            Section {
                Button {
                    Task { await manager.startForegroundBackup() }
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.phosphorAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upload paused")
                                .font(Typography.captionBold)
                                .foregroundStyle(.phosphorAccent)
                            Text("\(pendingCount) \(pendingCount == 1 ? "photo" : "photos") remaining — tap to resume.")
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.phosphorSurface)
                .accessibilityHint("Resume the paused backup run.")
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            row("Local Assets", value: "\(localAssetCount)")
            row("Backed Up", value: "\(manager.progress.completed)")
            row("Failed", value: "\(manager.progress.failed)")
            if let last = manager.lastBackupDate {
                row("Last Backup", value: last.formatted(.relative(presentation: .named)))
            }
            if manager.progress.isRunning {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ProgressView(value: manager.progress.fraction)
                        .tint(.phosphorPrimary)
                    HStack {
                        if let file = manager.progress.currentFileName {
                            Text("Uploading: \(file)")
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("↑ \(manager.bytesUploadedInLastSecond / 1024) KB/s")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(.phosphorSecondary)
                    }
                }
                .listRowBackground(Color.phosphorSurface)
            }
            if let error = manager.lastError {
                Text(error.localizedDescription)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorDanger)
                    .listRowBackground(Color.phosphorSurface)
            }
        }
    }

    private var controlsSection: some View {
        Section {
            if manager.progress.isRunning {
                Button(role: .destructive) {
                    manager.cancelBackup()
                } label: {
                    Label("Cancel Backup", systemImage: "stop.circle")
                }
                .listRowBackground(Color.phosphorSurface)
                .accessibilityHint("Stops the in-progress upload run.")
            } else {
                Button {
                    Task { await startBackup() }
                } label: {
                    Label("Start Backup", systemImage: "arrow.up.circle")
                }
                .listRowBackground(Color.phosphorSurface)
                .accessibilityHint("Uploads selected camera roll albums to the server.")
            }
        }
    }

    private var albumsSection: some View {
        Section("Albums") {
            if albums.isEmpty {
                Text("Grant Photos access to choose albums to back up.")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .listRowBackground(Color.phosphorSurface)
            } else {
                ForEach(albums, id: \.localIdentifier) { coll in
                    Toggle(coll.localizedTitle ?? "Untitled", isOn: Binding(
                        get: { selectedAlbumIDs.contains(coll.localIdentifier) },
                        set: { isOn in
                            if isOn { selectedAlbumIDs.insert(coll.localIdentifier) }
                            else { selectedAlbumIDs.remove(coll.localIdentifier) }
                            manager.selectedAlbumIDs = selectedAlbumIDs
                        }
                    ))
                    .tint(.phosphorPrimary)
                    .listRowBackground(Color.phosphorSurface)
                }
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Toggle(isOn: $wifiOnly) {
                Label("Wi-Fi Only", systemImage: "wifi")
            }
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)

            Toggle(isOn: $showStorageIndicator) {
                Label("Show Storage Indicator", systemImage: "externaldrive")
            }
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)

            ThrottleRow(value: $throttleKBps)
                .listRowBackground(Color.phosphorSurface)
        }
    }

    private var freeUpSection: some View {
        Section {
            Button(role: .destructive) {
                showFreeUpAlert = true
            } label: {
                Label("Free Up Space", systemImage: "trash.slash")
            }
            .listRowBackground(Color.phosphorSurface)
            .accessibilityHint("Deletes local copies of photos already uploaded to the server.")
        } footer: {
            Text("Removes local camera roll copies of photos that exist on your server.")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.phosphorSecondary)
            Spacer()
            Text(value).foregroundStyle(.phosphorPrimary).font(Typography.monoStat)
        }
        .listRowBackground(Color.phosphorSurface)
    }

    // MARK: - Actions

    private func startBackup() async {
        let status = await BackupManager.requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else { return }
        await manager.startForegroundBackup()
    }

    private func loadAlbums() async {
        let status = await BackupManager.requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else { return }

        var result: [PHAssetCollection] = []
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        userAlbums.enumerateObjects { coll, _, _ in result.append(coll) }
        albums = result

        let countResult = PHAsset.fetchAssets(with: nil)
        localAssetCount = countResult.count
    }

    private func freeUpSpace() async {
        // SAFETY: only delete a local copy after the server confirms (by SHA1
        // checksum) that it actually holds that asset. Never blanket-delete.
        let all = PHAsset.fetchAssets(with: nil)
        var candidates: [PHAsset] = []
        all.enumerateObjects { asset, _, _ in candidates.append(asset) }
        guard !candidates.isEmpty else { return }

        let confirmed = await manager.confirmedOnServer(candidates)
        guard !confirmed.isEmpty else {
            HapticManager.notification(.warning)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(confirmed as NSArray)
            }
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

/// Stepped throttle picker: snaps to a small set of meaningful values rather
/// than a continuous slider. 0 = unlimited.
private struct ThrottleRow: View {
    @Binding var value: Int

    private static let steps: [Int] = [0, 128, 256, 512, 1024, 2048, 5000, 10000]

    private var label: String {
        if value == 0 { return "Unlimited" }
        return "\(value) KB/s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label("Upload Speed", systemImage: "speedometer")
                    .foregroundStyle(.phosphorAccent)
                Spacer()
                Text(label)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.phosphorSecondary)
            }
            // Snap-to-step via Picker (segmented would crowd; menu is compact).
            Picker("Upload Speed", selection: $value) {
                ForEach(Self.steps, id: \.self) { step in
                    Text(step == 0 ? "Unlimited" : "\(step) KB/s").tag(step)
                }
            }
            .pickerStyle(.menu)
            .tint(.phosphorAccent)
            .accessibilityLabel("Upload speed limit")
        }
    }
}
