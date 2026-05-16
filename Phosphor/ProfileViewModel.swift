import Foundation

/// Outcome of `ProfileViewModel.testConnection()`. The `failure` payload is a
/// user-facing message, already formatted for display.
enum ConnectionResult: Equatable {
    case success(version: String, latencyMs: Int)
    case failure(String)
}

@MainActor
final class ProfileViewModel: ObservableObject {

    @Published var serverURL: String
    @Published var apiKey: String
    @Published private(set) var isTestingConnection = false
    @Published private(set) var connectionResult: ConnectionResult?
    @Published private(set) var stats: ServerStats?
    @Published private(set) var isLoadingStats = false
    @Published var statsError: ImmichError?

    private let connectionManager: ConnectionManager

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        self.serverURL = connectionManager.serverURL
        self.apiKey = connectionManager.apiKey
    }

    // MARK: - Connection

    /// Persist the typed credentials and ping the server. Latency is measured
    /// around the ping itself so it reflects the actual round-trip, not setup.
    func testConnection() async {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty else {
            connectionResult = .failure("Enter both server URL and API key.")
            HapticManager.notification(.error)
            return
        }

        isTestingConnection = true
        connectionResult = nil
        defer { isTestingConnection = false }

        connectionManager.configure(baseURL: trimmedURL, apiKey: trimmedKey)

        let start = Date()
        do {
            let ok = try await ImmichAPI.shared.testConnection()
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1_000)
            guard ok else {
                connectionResult = .failure("Server reachable but returned an unexpected response.")
                HapticManager.notification(.error)
                return
            }
            let version = (try? await ImmichAPI.shared.fetchServerVersion()) ?? "unknown"
            connectionResult = .success(version: version, latencyMs: max(elapsedMs, 1))
            HapticManager.notification(.success)
            await connectionManager.testAndConnect()
        } catch let caught as ImmichError {
            connectionResult = .failure(message(for: caught))
            HapticManager.notification(.error)
        } catch {
            connectionResult = .failure(error.localizedDescription)
            HapticManager.notification(.error)
        }
    }

    /// Convenience for the Profile screen: writes credentials without a probe.
    func saveCredentials() {
        connectionManager.configure(baseURL: serverURL, apiKey: apiKey)
    }

    // MARK: - Stats

    func loadStats() async {
        isLoadingStats = true
        statsError = nil
        defer { isLoadingStats = false }
        do {
            stats = try await ImmichAPI.shared.fetchServerStatistics()
        } catch let caught {
            statsError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    // MARK: - Helpers

    private func message(for error: ImmichError) -> String {
        switch error {
        case .notConfigured: return "Server URL or API key is not set."
        case .unauthorized: return "The API key was rejected by the server."
        case .networkError: return "Could not reach the server. Check the URL and your network."
        case .decodingError: return "The server responded but the format wasn't recognized."
        case .serverError(let code): return "Server returned HTTP \(code)."
        }
    }
}

/// Formatter for `storageUsed` — separated so Profile and Onboarding share it.
enum StorageFormatter {
    static func string(fromBytes bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}
