import Foundation

/// App-wide signal that the stored API key was rejected (HTTP 401/403). Set by
/// `ImmichAPI` when any request comes back unauthorized; observed by
/// `ContentView` to present a re-authentication sheet.
@MainActor
final class AuthState: ObservableObject {
    static let shared = AuthState()
    @Published var needsReauth = false

    func flagUnauthorized() { needsReauth = true }
    func clear() { needsReauth = false }
}

/// Owns the user-configurable Immich connection. Credentials are persisted to
/// the same UserDefaults keys that `ImmichAPI` reads (`ImmichAPI.DefaultsKey`),
/// so writing them here is what "injects" them into `ImmichAPI.shared`.
@MainActor
final class ConnectionManager: ObservableObject {

    @Published var serverURL: String
    @Published var apiKey: String
    @Published private(set) var isConnected = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var serverVersion: String?
    @Published private(set) var isTesting = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .phosphor) {
        self.defaults = defaults

        // One-time migration: copy credentials written to `.standard` by older
        // builds (pre App Group) into the shared suite so the widget can see
        // them. Skip if the suite already has values.
        Self.migrateStandardIfNeeded(into: defaults)

        let url = defaults.string(forKey: ImmichAPI.DefaultsKey.baseURL) ?? ""
        let key = defaults.string(forKey: ImmichAPI.DefaultsKey.apiKey) ?? ""
        self.serverURL = url
        self.apiKey = key
        self.isConfigured = !url.isEmpty && !key.isEmpty

        if isConfigured {
            Task { await testAndConnect() }
        }
    }

    private static func migrateStandardIfNeeded(into suite: UserDefaults) {
        guard suite !== UserDefaults.standard else { return }
        let standard = UserDefaults.standard
        for key in [ImmichAPI.DefaultsKey.baseURL, ImmichAPI.DefaultsKey.apiKey] {
            if suite.string(forKey: key) == nil,
               let value = standard.string(forKey: key),
               !value.isEmpty {
                suite.set(value, forKey: key)
            }
        }
    }

    /// Persist credentials. Written before any API call so `ImmichAPI.shared`
    /// (which reads UserDefaults fresh per request) picks them up.
    func configure(baseURL: String, apiKey: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        serverURL = trimmedURL
        self.apiKey = trimmedKey
        defaults.set(trimmedURL, forKey: ImmichAPI.DefaultsKey.baseURL)
        defaults.set(trimmedKey, forKey: ImmichAPI.DefaultsKey.apiKey)
        isConfigured = !trimmedURL.isEmpty && !trimmedKey.isEmpty
    }

    /// Validate the stored credentials against the server.
    func testAndConnect() async {
        guard isConfigured else {
            isConnected = false
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let ok = try await ImmichAPI.shared.testConnection()
            isConnected = ok
            if ok {
                // Version is supplementary metadata; failure here doesn't
                // invalidate the connection itself.
                do {
                    serverVersion = try await ImmichAPI.shared.fetchServerVersion()
                } catch {
                    serverVersion = nil
                }
            } else {
                serverVersion = nil
            }
        } catch {
            isConnected = false
            serverVersion = nil
        }
    }

    /// Clear stored credentials and disconnect.
    func disconnect() {
        defaults.removeObject(forKey: ImmichAPI.DefaultsKey.baseURL)
        defaults.removeObject(forKey: ImmichAPI.DefaultsKey.apiKey)
        serverURL = ""
        apiKey = ""
        isConfigured = false
        isConnected = false
        serverVersion = nil
    }
}
