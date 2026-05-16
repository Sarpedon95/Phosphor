import BackgroundTasks
import Foundation

/// Wraps `BGTaskScheduler` registration and scheduling for Phosphor's two
/// background jobs:
///   * **Refresh** (cheap, frequent): poll for new local assets; if any are
///     found, schedule a processing task.
///   * **Processing** (long-running, network-required): run the actual upload
///     pass via `BackupManager`.
enum BGTaskManager {

    static let refreshIdentifier = "com.sarpedon.phosphor.refresh"
    static let processingIdentifier = "com.sarpedon.phosphor.upload"

    /// Call from `PhosphorApp.init`. Must run before the launch ends — must
    /// be on the main thread synchronously.
    @MainActor
    static func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil
        ) { task in
            handleRefresh(task)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleProcessing(processingTask)
        }
    }

    @MainActor
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // ~15 min
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Handlers

    private static func handleRefresh(_ task: BGTask) {
        // Set the expiration handler synchronously *before* any async work, so
        // an early system expiration can't race an unset handler.
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        // Chain the next refresh, then do the lightweight check.
        Task { @MainActor in
            scheduleRefresh()
            if hasNewAssetsSinceLastBackup() {
                scheduleProcessing()
            }
            task.setTaskCompleted(success: true)
        }
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        let backupTask = Task { @MainActor in
            // Reschedule first so the chain continues even if the run is cut
            // short, then perform the upload pass.
            scheduleProcessing()
            await BackupManager.shared.startForegroundBackup()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            backupTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    @MainActor
    private static func hasNewAssetsSinceLastBackup() -> Bool {
        // Defer the import: BackgroundTasks runs in the main bundle and Photos
        // is available; we just spot-check.
        let manager = BackupManager.shared
        let last = manager.lastBackupDate ?? .distantPast
        // We don't enumerate PHAssets here to keep this BGAppRefresh budget
        // tight; instead return `true` if more than an hour has passed since
        // the last successful backup, which is a coarse but cheap proxy.
        return Date().timeIntervalSince(last) > 3600
    }
}
