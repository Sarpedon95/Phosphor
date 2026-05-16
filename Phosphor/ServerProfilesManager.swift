import Foundation
import SwiftUI

/// One saved Immich server config. Stored as plain JSON in App Group defaults;
/// the *active* profile's credentials are also mirrored into the canonical
/// `immich_base_url` / `immich_api_key` keys so the rest of the app
/// (ImmichAPI, widget) continues to read from a single source.
struct ServerProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var lastConnected: Date?
}

@MainActor
final class ServerProfilesManager: ObservableObject {

    static let maxProfiles = 5

    @Published private(set) var profiles: [ServerProfile] = []
    @Published private(set) var activeProfileId: UUID?

    private let defaults: UserDefaults = .phosphor
    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
        load()
        // Seed: if the user already had credentials before profiles existed,
        // wrap them as the active profile so the list isn't empty.
        if profiles.isEmpty,
           !connection.serverURL.isEmpty,
           !connection.apiKey.isEmpty {
            let seeded = ServerProfile(
                id: UUID(),
                name: "Default",
                baseURL: connection.serverURL,
                apiKey: connection.apiKey,
                lastConnected: Date()
            )
            profiles = [seeded]
            activeProfileId = seeded.id
            persist()
        }
    }

    var canAddMore: Bool { profiles.count < Self.maxProfiles }

    // MARK: - Mutations

    func addProfile(name: String, baseURL: String, apiKey: String) {
        guard canAddMore else { return }
        let profile = ServerProfile(
            id: UUID(), name: name, baseURL: baseURL, apiKey: apiKey, lastConnected: nil
        )
        profiles.append(profile)
        if activeProfileId == nil {
            switchTo(profile)
        } else {
            persist()
        }
    }

    /// Delete a profile. If the active profile is deleted, fall back to the
    /// first remaining (and reconfigure the connection); if there are none,
    /// disconnect entirely which re-triggers the onboarding gate.
    func deleteProfile(_ profile: ServerProfile) {
        let wasActive = profile.id == activeProfileId
        profiles.removeAll { $0.id == profile.id }

        if wasActive {
            if let fallback = profiles.first {
                switchTo(fallback)
            } else {
                activeProfileId = nil
                connection.disconnect()
                persist()
            }
        } else {
            persist()
        }
    }

    var canDelete: Bool { profiles.count > 0 }

    /// Switch the active profile. Caller is responsible for warning the user
    /// that this clears local cache (handled in ProfileView).
    ///
    /// Wipes everything keyed to the old server: the image cache, recently-
    /// viewed/scroll position, and the saved-search list (those are
    /// server-scoped too — a query for a city on server A is meaningless on
    /// server B).
    func switchTo(_ profile: ServerProfile) {
        activeProfileId = profile.id
        connection.configure(baseURL: profile.baseURL, apiKey: profile.apiKey)
        Task { await ImageLoader.shared.clearCache() }
        SessionState.shared.clearAll()
        // Recent search list isn't server-tied but saved-search filters
        // (city / camera / albumId) are. Clear them; the user can rebuild.
        UserDefaults.phosphor.removeObject(forKey: AppSettings.Keys.savedSearches)
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i].lastConnected = Date()
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: AppSettings.Keys.serverProfiles),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let raw = defaults.string(forKey: AppSettings.Keys.activeServerProfile),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            activeProfileId = id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: AppSettings.Keys.serverProfiles)
        }
        if let id = activeProfileId {
            defaults.set(id.uuidString, forKey: AppSettings.Keys.activeServerProfile)
        } else {
            defaults.removeObject(forKey: AppSettings.Keys.activeServerProfile)
        }
    }
}
