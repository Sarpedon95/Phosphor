import Foundation
import UIKit

/// Minimal, dependency-free Immich client for the widget process.
///
/// The widget extension runs in a separate process from the app, so it cannot
/// reuse `ImmichAPI.shared`. It reads credentials from the shared App Group
/// `UserDefaults` (written by the main app's `ConnectionManager`).
struct WidgetNetworkClient {

    static let appGroupID = "group.com.sarpedon.phosphor"

    private var defaults: UserDefaults? { UserDefaults(suiteName: Self.appGroupID) }

    private var baseURL: URL? {
        guard let raw = defaults?.string(forKey: "immich_base_url"),
              !raw.isEmpty else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    private var apiKey: String? {
        let key = defaults?.string(forKey: "immich_api_key")
        return (key?.isEmpty == false) ? key : nil
    }

    var isConfigured: Bool { baseURL != nil && apiKey != nil }

    // MARK: - Fetch

    /// Returns up to `limit` recent asset IDs. Empty on any failure — widgets
    /// must degrade gracefully to a placeholder, never error.
    func recentAssetIDs(limit: Int) async -> [String] {
        guard let base = baseURL, let key = apiKey else { return [] }
        let url = base.appendingPathComponent("search/metadata")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["page": 1, "size": limit, "order": "desc"]
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any],
              let items = assets["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    func favoriteAssetIDs(limit: Int) async -> [String] {
        guard let base = baseURL, let key = apiKey else { return [] }
        let url = base.appendingPathComponent("search/metadata")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["page": 1, "size": limit, "isFavorite": true]
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any],
              let items = assets["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    func thumbnail(assetID: String) async -> UIImage? {
        guard let base = baseURL, let key = apiKey else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("assets/\(assetID)/thumbnail"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "size", value: "thumbnail")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return UIImage(data: data)
    }
}
