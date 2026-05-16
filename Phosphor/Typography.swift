import SwiftUI

/// Central font hierarchy. Use these instead of `.font(.headline)` etc. so the
/// app's typographic voice can be tuned in one place.
enum Typography {
    // MARK: Stage-7 semantic scale (preferred)
    static let phosphorLargeTitle = Font.largeTitle.weight(.bold)
    static let phosphorTitle = Font.title2.weight(.semibold)
    static let phosphorHeadline = Font.headline.weight(.medium)
    static let phosphorBody = Font.body
    static let phosphorCaption = Font.caption

    // MARK: Established tokens (kept — referenced across the app)
    static let wordmark = Font.system(size: 44, weight: .bold, design: .default)
    static let displayTitle = Font.system(size: 34, weight: .bold)
    static let title = Font.system(size: 28, weight: .bold)
    static let title2 = Font.system(size: 22, weight: .bold)
    static let title3 = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 17, weight: .regular)
    static let subheadline = Font.system(size: 15, weight: .medium)
    static let footnote = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionBold = Font.system(size: 12, weight: .semibold)
    static let monoStat = Font.system(size: 17, weight: .medium, design: .monospaced)
}
