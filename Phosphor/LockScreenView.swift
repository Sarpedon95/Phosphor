import SwiftUI

/// Full-screen lock UI. Shown by `PhosphorApp` whenever `AppLockManager.isLocked`
/// is true. Auto-prompts for biometrics on appear; tap retries.
struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            VStack(spacing: Spacing.lg) {
                Image(systemName: "faceid")
                    .font(.system(size: 60, weight: .thin))
                    .foregroundStyle(.phosphorAccent)
                Text("Phosphor is locked")
                    .font(Typography.phosphorHeadline)
                    .foregroundStyle(.phosphorAccent)
                Text("Tap to unlock")
                    .font(Typography.phosphorCaption)
                    .foregroundStyle(.phosphorSecondary)
                if let error = lock.lastAuthError {
                    Text(error)
                        .font(Typography.phosphorCaption)
                        .foregroundStyle(.phosphorDestructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await lock.authenticate() } }
        .task { await lock.authenticate() }
        .accessibilityLabel("Phosphor is locked. Double-tap to authenticate.")
    }
}
