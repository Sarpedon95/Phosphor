import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between main app (start/update) and the Live Activity extension
/// (render). Guarded with `canImport(ActivityKit)` so the file compiles even
/// in environments without ActivityKit available.
@available(iOS 16.2, *)
struct PhosphorBackupActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var uploaded: Int
        public var total: Int
        public var currentFileName: String
        public var isFailed: Bool
        public var etaString: String?

        public init(uploaded: Int, total: Int, currentFileName: String, isFailed: Bool, etaString: String? = nil) {
            self.uploaded = uploaded
            self.total = total
            self.currentFileName = currentFileName
            self.isFailed = isFailed
            self.etaString = etaString
        }
    }

    /// Static, set once at activity start. Currently empty (we drive everything
    /// from ContentState) but kept as a placeholder for future immutable data.
    public init() {}
}
#endif
