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
/// the Keychain keys that `ImmichAPI` reads (`ImmichAPI.KeychainKey`), so
/// writing them here is what "injects" them into `ImmichAPI.shared`.
@MainActor
final class ConnectionManager: ObservableObject {

    @Published var serverURL: String
    @Published var apiKey: String
    @Published private(set) var isConnected = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var serverVersion: String?
    @Published private(set) var isTesting = false

    init() {
        let url = KeychainManager.get(forKey: ImmichAPI.KeychainKey.baseURL) ?? ""
        let key = KeychainManager.get(forKey: ImmichAPI.KeychainKey.apiKey) ?? ""
        self.serverURL = url
        self.apiKey = key
        self.isConfigured = !url.isEmpty && !key.isEmpty

        if isConfigured {
            Task { await testAndConnect() }
        }
    }

    /// Persist credentials to Keychain so `ImmichAPI.shared` picks them up
    /// immediately on the next request.
    func configure(baseURL: String, apiKey: String) {
        connect(baseURL: baseURL, apiKey: apiKey)
    }

    /// Persist API-key credentials and mark the connection ready. The
    /// `connect(baseURL:apiKey:)` / `connect(baseURL:token:)` overloads are the
    /// canonical entry points for the new onboarding flow.
    func connect(baseURL: String, apiKey: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        serverURL = trimmedURL
        self.apiKey = trimmedKey
        KeychainManager.set(trimmedURL, forKey: ImmichAPI.KeychainKey.baseURL)
        KeychainManager.set(trimmedKey, forKey: ImmichAPI.KeychainKey.apiKey)
        // A new API key supersedes any previously-stored bearer token.
        KeychainManager.delete(forKey: ImmichAPI.KeychainKey.accessToken)
        isConfigured = !trimmedURL.isEmpty && !trimmedKey.isEmpty
        isConnected = isConfigured
    }

    /// Persist bearer-token credentials (from email + password sign-in).
    func connect(baseURL: String, token: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        serverURL = trimmedURL
        // Clear any stale API key — bearer auth is now the canonical credential.
        apiKey = ""
        KeychainManager.set(trimmedURL, forKey: ImmichAPI.KeychainKey.baseURL)
        KeychainManager.set(trimmedToken, forKey: ImmichAPI.KeychainKey.accessToken)
        KeychainManager.delete(forKey: ImmichAPI.KeychainKey.apiKey)
        isConfigured = !trimmedURL.isEmpty && !trimmedToken.isEmpty
        isConnected = isConfigured
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
        KeychainManager.delete(forKey: ImmichAPI.KeychainKey.baseURL)
        KeychainManager.delete(forKey: ImmichAPI.KeychainKey.apiKey)
        KeychainManager.delete(forKey: ImmichAPI.KeychainKey.accessToken)
        serverURL = ""
        apiKey = ""
        isConfigured = false
        isConnected = false
        serverVersion = nil
    }
}
