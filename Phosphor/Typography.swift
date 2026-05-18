import SwiftUI

/// Central font hierarchy. Built on top of the system text styles so every
/// label scales with Dynamic Type out of the box.
enum Typography {
    // MARK: Semantic styles (scale with Dynamic Type)
    static let wordmark = Font.largeTitle.weight(.bold)
    static let displayTitle = Font.largeTitle.weight(.bold)
    static let title = Font.title.weight(.bold)
    static let title2 = Font.title2.weight(.bold)
    static let title3 = Font.title3.weight(.semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
    static let captionBold = Font.caption.weight(.semibold)
    static let monoStat = Font.body.monospacedDigit()

    // MARK: Stage-7 aliases (kept for source compatibility)
    static let phosphorLargeTitle = Font.largeTitle.weight(.bold)
    static let phosphorTitle = Font.title2.weight(.semibold)
    static let phosphorHeadline = Font.headline.weight(.medium)
    static let phosphorBody = Font.body
    static let phosphorCaption = Font.caption
}
