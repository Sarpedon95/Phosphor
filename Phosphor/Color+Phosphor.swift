import SwiftUI

/// Phosphor's dark palette in one place. Reach for these instead of ad-hoc
/// `Color(white: 0.12)` so palette tuning is a single-file change.
extension ShapeStyle where Self == Color {
    // MARK: Stage-7 palette (authoritative values)

    /// Base app background — near-black with a hair of lift to avoid OLED smear.
    static var phosphorBackground: Color { Color(white: 0.04) }
    /// Elevated surface (cards, list rows).
    static var phosphorSurface: Color { Color(white: 0.10) }
    /// Higher elevation (nested surfaces, pressed states).
    static var phosphorSurface2: Color { Color(white: 0.15) }
    /// Primary accent / foreground.
    static var phosphorAccent: Color { Color.white }
    /// Secondary text — labels, metadata.
    static var phosphorSecondary: Color { Color(white: 0.5) }
    /// Destructive / warning accent.
    static var phosphorDestructive: Color { Color.red }

    // MARK: Back-compat aliases (used across the app; map onto the above)

    /// Alias of `phosphorAccent`.
    static var phosphorPrimary: Color { Color.white }
    /// Alias of `phosphorDestructive`.
    static var phosphorDanger: Color { Color.red }
    /// Subtle separator / hairline.
    static var phosphorSeparator: Color { Color(white: 0.16) }
    /// Shimmer placeholder base tone.
    static var phosphorPlaceholder: Color { Color(white: 0.12) }
    /// Success accent.
    static var phosphorSuccess: Color { Color.green }
}
