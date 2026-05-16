import CoreGraphics

/// Spacing scale. Stage-7 names (`sm/md/lg`) are preferred for new code; the
/// short legacy names (`s/m/l/xxl`) are kept because ~80 call sites use them.
///
/// Note on `xl`: the established scale defines `xl = 24` and is used widely, so
/// it is left at 24. Stage-7's "xl: 32" is provided as `xxl` (same value).
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24

    // Legacy aliases (do not remove — heavily referenced).
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum CornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let card: CGFloat = 20
}

/// Minimum interactive tap target per Apple HIG.
enum TapTarget {
    static let minimum: CGFloat = 44
}
