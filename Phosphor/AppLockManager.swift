import Foundation
import LocalAuthentication
import SwiftUI

/// Biometric/passcode lock state. Locking is automatic on background transition
/// when `appLockEnabled` is on; unlocking is biometric with passcode fallback.
@MainActor
final class AppLockManager: ObservableObject {

    @Published private(set) var isLocked: Bool = false
    @Published var lastAuthError: String?

    private var pendingLockTask: Task<Void, Never>?

    init() {
        // Lock from cold launch if the user has enabled the feature.
        if AppSettings.appLockEnabled {
            isLocked = true
        }
    }

    /// Re-read settings (called when the user toggles the lock in Profile).
    func refreshFromSettings() {
        if !AppSettings.appLockEnabled {
            isLocked = false
            pendingLockTask?.cancel()
        }
    }

    func lockImmediately() {
        guard AppSettings.appLockEnabled else { return }
        pendingLockTask?.cancel()
        isLocked = true
    }

    func scheduleLockOnBackground() {
        guard AppSettings.appLockEnabled else { return }
        pendingLockTask?.cancel()
        let delay = AppSettings.lockDelaySeconds
        if delay <= 0 {
            isLocked = true
            return
        }
        pendingLockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.isLocked = true }
        }
    }

    func cancelScheduledLock() {
        pendingLockTask?.cancel()
        pendingLockTask = nil
    }

    func authenticate() async {
        guard isLocked else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var policyError: NSError?
        let canBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &policyError
        )
        let policy: LAPolicy = canBiometrics
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        do {
            let success = try await context.evaluatePolicy(
                policy, localizedReason: "Unlock Phosphor"
            )
            if success {
                isLocked = false
                lastAuthError = nil
            }
        } catch {
            lastAuthError = error.localizedDescription
        }
    }
}
