import SwiftUI

/// Phosphor's dark palette in one place. Reach for these instead of ad-hoc
/// `Color(white: 0.12)` so palette tuning is a single-file change.
extension Color {
    // MARK: Stage-7 palette (authoritative values)

    /// Base app background — near-black with a hair of lift to avoid OLED smear.
    static let phosphorBackground = Color(white: 0.04)
    /// Elevated surface (cards, list rows).
    static let phosphorSurface = Color(white: 0.10)
    /// Higher elevation (nested surfaces, pressed states).
    static let phosphorSurface2 = Color(white: 0.15)
    /// Primary accent / foreground.
    static let phosphorAccent = Color.white
    /// Secondary text — labels, metadata.
    static let phosphorSecondary = Color(white: 0.5)
    /// Destructive / warning accent.
    static let phosphorDestructive = Color.red

    // MARK: Back-compat aliases (used across the app; map onto the above)

    /// Alias of `phosphorAccent`.
    static let phosphorPrimary = Color.white
    /// Alias of `phosphorDestructive`.
    static let phosphorDanger = Color.red
    /// Subtle separator / hairline.
    static let phosphorSeparator = Color(white: 0.16)
    /// Shimmer placeholder base tone.
    static let phosphorPlaceholder = Color(white: 0.12)
    /// Success accent.
    static let phosphorSuccess = Color.green
}
