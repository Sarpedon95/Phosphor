import Foundation
import Photos
import CryptoKit
import Network
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Progress published by `BackupManager` for the Backup screen.
struct UploadProgress: Equatable {
    var total: Int = 0
    var completed: Int = 0
    var failed: Int = 0
    var currentFileName: String?
    var isRunning: Bool = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed + failed) / Double(total)
    }
}

enum BackupError: Error, LocalizedError {
    case notAuthorized
    case wifiRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Photos access not granted."
        case .wifiRequired: return "Wi-Fi only mode is on but no Wi-Fi connection is available."
        case .cancelled: return "Backup was cancelled."
        }
    }
}

/// Camera-roll backup engine. Runs uploads serially against `ImmichAPI`,
/// skipping assets already present on the server (SHA1-compared).
@MainActor
final class BackupManager: ObservableObject {

    static let shared = BackupManager()

    @Published private(set) var progress = UploadProgress()
    @Published private(set) var lastBackupDate: Date?
    @Published var lastError: Error?
    @Published private(set) var estimatedTimeRemaining: TimeInterval?
    private var runStartDate: Date?

    /// Excluded local album IDs (PHAssetCollection.localIdentifier). Assets
    /// inside these collections are filtered out of every backup run.
    var excludedAlbumIDs: Set<String> {
        get {
            Set(defaults.stringArray(forKey: AppSettings.Keys.excludedBackupAlbums) ?? [])
        }
        set {
            defaults.set(Array(newValue), forKey: AppSettings.Keys.excludedBackupAlbums)
        }
    }

    private var currentTask: Task<Void, Never>?
    private let defaults: UserDefaults = .phosphor
    private let deviceId: String

    private init() {
        // Persist a stable per-install identifier so the server can dedupe
        // `deviceAssetId` reliably even when iOS reinstalls the app.
        let key = "device_id"
        if let existing = UserDefaults.phosphor.string(forKey: key) {
            self.deviceId = existing
        } else {
            let new = UUID().uuidString
            UserDefaults.phosphor.set(new, forKey: key)
            self.deviceId = new
        }
        if let ts = UserDefaults.phosphor.object(forKey: AppSettings.Keys.lastBackupDate) as? Date {
            self.lastBackupDate = ts
        }
    }

    // MARK: - Authorization

    /// Returns the current Photos authorization, only presenting the system
    /// prompt when status is still `.notDetermined`. Once the user has
    /// answered, iOS caches the decision and we never re-request.
    static func requestPhotoLibraryAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Hashing

    /// Base64-encoded SHA1 of the file, matching Immich's
    /// `/assets/bulk-upload-check` checksum contract. `nonisolated` so callers
    /// can hash large media off the main actor via `Task.detached`.
    nonisolated static func sha1Base64(_ data: Data) -> String {
        Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
    }

    // MARK: - Entry points

    /// Kick off a foreground backup pass. Idempotent: if one is already
    /// running, calling again is a no-op.
    func startForegroundBackup() async {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            await self?.runBackup()
            await MainActor.run { self?.currentTask = nil }
        }
        await currentTask?.value
    }

    func cancelBackup() {
        currentTask?.cancel()
        currentTask = nil
        progress.isRunning = false
        // The in-progress run loop also calls `liveActivityEnd(failed: true)`
        // when it sees `Task.isCancelled`, but if the loop was waiting in an
        // upload at the moment of cancel, the run-loop end may be delayed.
        // End here too — `liveActivityEnd` is idempotent against a nil handle.
        liveActivityEnd(failed: true)
    }

    /// User-facing reset: drop the persisted queue and zero the counters.
    func clearQueue() {
        removeQueueKey()
        progress = UploadProgress()
    }

    private func removeQueueKey() {
        defaults.removeObject(forKey: AppSettings.Keys.backupQueue)
    }

    // MARK: - Album selection

    /// Persisted set of `PHAssetCollection.localIdentifier`s the user has
    /// enabled for backup.
    var selectedAlbumIDs: Set<String> {
        get {
            let raw = defaults.stringArray(forKey: AppSettings.Keys.backupAlbums) ?? []
            return Set(raw)
        }
        set {
            defaults.set(Array(newValue), forKey: AppSettings.Keys.backupAlbums)
        }
    }

    // MARK: - Core run loop

    private func runBackup() async {
        progress = UploadProgress(isRunning: true)
        lastError = nil
        runStartDate = Date()
        estimatedTimeRemaining = nil
        liveActivityStart()

        // Authorization.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            lastError = BackupError.notAuthorized
            progress.isRunning = false
            return
        }

        // Wi-Fi gate.
        if AppSettings.bool(AppSettings.Keys.wifiOnlyBackup, default: true) {
            let onWifi = await NetworkMonitor.isOnWiFi()
            guard onWifi else {
                lastError = BackupError.wifiRequired
                progress.isRunning = false
                return
            }
        }

        // Fetch candidate PHAssets.
        let assets = fetchPHAssets()
        progress.total = assets.count

        // Persist the pending queue (asset IDs only) so an interrupted run can
        // be reasoned about / resumed on next launch.
        var pending = assets.map(\.localIdentifier)
        persistQueue(pending)

        for asset in assets {
            if Task.isCancelled {
                lastError = BackupError.cancelled
                progress.isRunning = false
                liveActivityEnd(failed: true)
                return
            }
            let bytes = await uploadOne(asset)
            pending.removeAll { $0 == asset.localIdentifier }
            persistQueue(pending)
            updateETR()
            liveActivityUpdate()
            await applyThrottle(bytesUploaded: bytes)
        }

        removeQueueKey()
        progress.isRunning = false
        lastBackupDate = Date()
        defaults.set(lastBackupDate, forKey: AppSettings.Keys.lastBackupDate)
        liveActivityEnd(failed: false)

        // Backup-complete local notification.
        await NotificationManager.sendBackupComplete(
            uploaded: progress.completed,
            failed: progress.failed
        )
    }

    /// Bytes uploaded in the trailing 1-second window. Updated as
    /// `lastChunkBytes` accumulates and trimmed via `lastChunkAt`. Read by
    /// `BackupView` to render the live ↑ KB/s readout.
    @Published private(set) var bytesUploadedInLastSecond: Int = 0
    private var rateWindow: [(time: Date, bytes: Int)] = []

    /// Per-asset throttle. Walks the asset's bytes through a
    /// `ThrottledUploadStream` which sleeps internally to honour the kbps cap.
    /// This is the throughput accountant — the actual HTTP request was already
    /// performed by `ImmichAPI.uploadAsset`; we just enforce the post-hoc rate
    /// here so the user-visible "upload speed limit" promise holds for the
    /// run as a whole. (A true byte-stream throttle requires
    /// `URLSessionUploadTask` with a producer, which the multipart helper
    /// doesn't yet expose.)
    private func applyThrottle(bytesUploaded: Int) async {
        recordBytes(bytesUploaded)

        let kbps = AppSettings.uploadThrottleKBps
        guard kbps > 0, bytesUploaded > 0 else { return }
        let stream = ThrottledUploadStream(
            data: Data(count: bytesUploaded),
            kbps: kbps
        )
        while await stream.nextChunk() != nil {
            if Task.isCancelled { return }
        }
    }

    /// Append a (timestamp, bytes) sample and trim anything older than 1s.
    private func recordBytes(_ count: Int) {
        let now = Date()
        rateWindow.append((now, count))
        rateWindow.removeAll { now.timeIntervalSince($0.time) > 1.0 }
        bytesUploadedInLastSecond = rateWindow.reduce(0) { $0 + $1.bytes }
    }

    private func persistQueue(_ ids: [String]) {
        // Asset identifiers only — never full asset payloads.
        defaults.set(ids, forKey: AppSettings.Keys.backupQueue)
    }

    /// IDs still pending from a previous interrupted run, if any.
    var resumableQueue: [String] {
        defaults.stringArray(forKey: AppSettings.Keys.backupQueue) ?? []
    }

    private func fetchPHAssets() -> [PHAsset] {
        let selected = selectedAlbumIDs
        let excluded = excludedAlbumIDs
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let initial: [PHAsset]
        if selected.isEmpty {
            initial = collect(PHAsset.fetchAssets(with: options))
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: Array(selected), options: nil
            )
            var combined: [PHAsset] = []
            collections.enumerateObjects { coll, _, _ in
                let inColl = PHAsset.fetchAssets(in: coll, options: options)
                combined.append(contentsOf: self.collect(inColl))
            }
            initial = combined
        }

        guard !excluded.isEmpty else { return initial }
        // Build the set of localIdentifiers that live in any excluded album.
        let excludedCollections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: Array(excluded), options: nil
        )
        var excludedAssetIDs = Set<String>()
        excludedCollections.enumerateObjects { coll, _, _ in
            let inColl = PHAsset.fetchAssets(in: coll, options: nil)
            inColl.enumerateObjects { asset, _, _ in
                excludedAssetIDs.insert(asset.localIdentifier)
            }
        }
        return initial.filter { !excludedAssetIDs.contains($0.localIdentifier) }
    }

    private func updateETR() {
        guard let start = runStartDate else { return }
        let done = progress.completed + progress.failed
        guard done > 0, progress.total > 0 else {
            estimatedTimeRemaining = nil
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let perItem = elapsed / Double(done)
        let remaining = progress.total - done
        estimatedTimeRemaining = perItem * Double(max(0, remaining))
    }

    /// Human-readable estimate of remaining time, suitable for the Live
    /// Activity status string. Returns nil if not yet computable.
    var etaString: String? {
        guard let eta = estimatedTimeRemaining, eta.isFinite, eta > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        if let formatted = formatter.string(from: eta) {
            return "~\(formatted) remaining"
        }
        return nil
    }

    private func collect(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    @discardableResult
    private func uploadOne(_ asset: PHAsset) async -> Int {
        let fileName = (PHAssetResource.assetResources(for: asset).first?.originalFilename)
            ?? "\(asset.localIdentifier).jpg"
        progress.currentFileName = fileName

        do {
            let data = try await fetchAssetData(asset)

            // SHA1 the file off the main actor, then ask the server whether it
            // already has it. Skip the upload (counts as completed) on a match
            // so re-runs don't duplicate.
            let checksum = await Task.detached(priority: .utility) {
                BackupManager.sha1Base64(data)
            }.value

            let alreadyOnServer = try await ImmichAPI.shared.existingAssetIDs(
                [(deviceAssetId: asset.localIdentifier, checksum: checksum)]
            )
            if alreadyOnServer.contains(asset.localIdentifier) {
                progress.completed += 1
                progress.currentFileName = nil
                return 0   // No bytes actually uploaded.
            }

            _ = try await ImmichAPI.shared.uploadAsset(
                data: data,
                deviceAssetId: asset.localIdentifier,
                deviceId: deviceId,
                fileName: fileName,
                fileCreatedAt: asset.creationDate ?? Date(),
                fileModifiedAt: asset.modificationDate ?? Date(),
                isFavorite: asset.isFavorite
            )
            progress.completed += 1
            progress.currentFileName = nil
            return data.count
        } catch {
            progress.failed += 1
            lastError = error
            progress.currentFileName = nil
            return 0
        }
    }

    /// Finds local PHAssets that are safe to delete (already present on the
    /// server, matched by SHA1). Convenience entry point for FreeUpSpaceView.
    func findLocalAssetsAlreadyOnServer() async -> [PHAsset] {
        let all = PHAsset.fetchAssets(with: nil)
        var candidates: [PHAsset] = []
        all.enumerateObjects { asset, _, _ in candidates.append(asset) }
        return await confirmedOnServer(candidates)
    }

    /// Returns the subset of `assets` the server confirms it already holds
    /// (matched by SHA1 checksum). Used by "Free Up Space" so a local copy is
    /// only ever deleted once its presence on the server is verified.
    func confirmedOnServer(_ assets: [PHAsset]) async -> [PHAsset] {
        var byID: [String: PHAsset] = [:]
        var items: [(deviceAssetId: String, checksum: String)] = []

        for asset in assets {
            guard let data = try? await fetchAssetData(asset) else { continue }
            let checksum = await Task.detached(priority: .utility) {
                BackupManager.sha1Base64(data)
            }.value
            byID[asset.localIdentifier] = asset
            items.append((asset.localIdentifier, checksum))
        }

        guard let present = try? await ImmichAPI.shared.existingAssetIDs(items) else {
            return []
        }
        return present.compactMap { byID[$0] }
    }

    private func fetchAssetData(_ asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            guard let resource = PHAssetResource.assetResources(for: asset).first else {
                cont.resume(throwing: BackupError.cancelled)
                return
            }
            var accumulator = Data()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { accumulator.append($0) },
                completionHandler: { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: accumulator)
                    }
                }
            )
        }
    }

    // MARK: - Live Activity (iOS 16.2+)

    #if canImport(ActivityKit)
    /// Type-erased to `Any?` so the property doesn't require iOS 16.2 at
    /// compile time. The concrete `Activity<…>` is used inside `if #available`
    /// guards.
    private var liveActivity: Any?
    /// Wall-clock timestamp of the last `liveActivityUpdate` call. ActivityKit
    /// throttles excessive updates aggressively; we self-cap at one update
    /// per ~0.75 s so even fast uploads don't burn the budget.
    private var lastActivityUpdate: Date?

    private func liveActivityStart() {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = PhosphorBackupActivityAttributes.ContentState(
            uploaded: 0, total: progress.total, currentFileName: "", isFailed: false
        )
        do {
            let activity = try Activity<PhosphorBackupActivityAttributes>.request(
                attributes: PhosphorBackupActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            liveActivity = activity
        } catch {
            liveActivity = nil
        }
    }

    private func liveActivityUpdate() {
        guard #available(iOS 16.2, *),
              let activity = liveActivity as? Activity<PhosphorBackupActivityAttributes>
        else { return }
        // Throttle: drop intermediate updates so we never exceed ~1.3 Hz.
        let now = Date()
        if let last = lastActivityUpdate, now.timeIntervalSince(last) < 0.75 {
            // Always push the final asset (uploaded == total) so the bar
            // visibly reaches 100% before the activity ends.
            if progress.completed < progress.total { return }
        }
        lastActivityUpdate = now
        let state = PhosphorBackupActivityAttributes.ContentState(
            uploaded: progress.completed,
            total: progress.total,
            currentFileName: progress.currentFileName ?? "",
            isFailed: false,
            etaString: etaString
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func liveActivityEnd(failed: Bool) {
        guard #available(iOS 16.2, *),
              let activity = liveActivity as? Activity<PhosphorBackupActivityAttributes>
        else { return }
        let state = PhosphorBackupActivityAttributes.ContentState(
            uploaded: progress.completed,
            total: progress.total,
            currentFileName: "",
            isFailed: failed
        )
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now + 4)
            )
        }
        liveActivity = nil
    }
    #else
    private func liveActivityStart() {}
    private func liveActivityUpdate() {}
    private func liveActivityEnd(failed: Bool) {}
    #endif
}

// MARK: - Network monitoring

/// One-shot Wi-Fi check. Each call spins up a fresh `NWPathMonitor`, waits for
/// the first delivered path, then cancels it — so no monitor outlives the
/// query and nothing leaks.
enum NetworkMonitor {
    static func isOnWiFi() async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.sarpedon.phosphor.netcheck")

        let once = ResumeGuard()
        let path: NWPath = await withCheckedContinuation { cont in
            // `pathUpdateHandler` can fire repeatedly; resume exactly once.
            monitor.pathUpdateHandler = { path in
                if once.tryConsume() { cont.resume(returning: path) }
            }
            monitor.start(queue: queue)
        }
        monitor.cancel()
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
}

/// Thread-safe one-shot latch so a continuation resumes exactly once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
