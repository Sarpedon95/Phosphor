import UIKit

/// Centralized haptic feedback. `UIFeedbackGenerator` requires the main
/// thread; `@MainActor` makes that a compile-time guarantee.
///
/// Every call checks `AppSettings.hapticsEnabled` first so the user-facing
/// haptics toggle in Profile is honoured without each call site re-checking.
@MainActor
enum HapticManager {

    /// Tactile impact for direct UI events (tap, drag completion).
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard AppSettings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Light tick used for picker/segmented changes and context-menu opens.
    static func selection() {
        guard AppSettings.hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// System notification haptic (success / warning / error).
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppSettings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    /// Legacy alias kept for older call sites; forwards to `notification(_:)`.
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notification(type)
    }
}
