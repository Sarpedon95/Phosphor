import SwiftUI

/// Manages who an album is shared with. Lists current shared users and lets
/// the owner add or remove people by searching the server's user directory.
struct SharedAlbumManagementView: View {
    let album: ImmichAlbum
    let onChange: ([SharedUser]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sharedUsers: [SharedUser]
    @State private var query = ""
    @State private var searchResults: [ImmichUser] = []
    @State private var isSearching = false
    @State private var searchError: ImmichError?
    @State private var addingUserId: String?
    @State private var searchTask: Task<Void, Never>?

    init(album: ImmichAlbum, onChange: @escaping ([SharedUser]) -> Void) {
        self.album = album
        self.onChange = onChange
        self._sharedUsers = State(initialValue: album.sharedUsers ?? [])
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                List {
                    if !sharedUsers.isEmpty {
                        Section("Shared with") {
                            ForEach(sharedUsers, id: \.id) { user in
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundStyle(.phosphorAccent)
                                    Text(user.email ?? user.id)
                                        .foregroundStyle(.phosphorPrimary)
                                }
                                .listRowBackground(Color.phosphorSurface)
                            }
                            .onDelete { offsets in
                                for offset in offsets {
                                    let user = sharedUsers[offset]
                                    Task { await remove(user) }
                                }
                            }
                        }
                    }
                    Section("Add a person") {
                        TextField("Search by name or email", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .listRowBackground(Color.phosphorSurface)
                            .onChange(of: query) { _, new in
                                debounceSearch(new)
                            }
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView().tint(.phosphorAccent)
                                Spacer()
                            }
                            .listRowBackground(Color.phosphorSurface)
                        }
                        if let searchError {
                            Text(searchError.localizedDescription)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorDanger)
                                .listRowBackground(Color.phosphorSurface)
                        }
                        ForEach(searchResults) { user in
                            Button { Task { await add(user) } } label: {
                                HStack {
                                    Text(user.displayName)
                                        .foregroundStyle(.phosphorPrimary)
                                    Spacer()
                                    if addingUserId == user.id {
                                        ProgressView().controlSize(.small).tint(.phosphorAccent)
                                    } else if sharedUsers.contains(where: { $0.id == user.id }) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.phosphorSecondary)
                                    } else {
                                        Image(systemName: "plus")
                                            .foregroundStyle(.phosphorAccent)
                                    }
                                }
                            }
                            .disabled(addingUserId != nil || sharedUsers.contains { $0.id == user.id })
                            .listRowBackground(Color.phosphorSurface)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            searchError = nil
            return
        }
        isSearching = true
        searchError = nil
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            do {
                let users = try await ImmichAPI.shared.fetchUsers(query: trimmed)
                if Task.isCancelled { return }
                searchResults = users
            } catch let caught {
                searchError = (caught as? ImmichError) ?? .networkError(caught)
                searchResults = []
            }
            isSearching = false
        }
    }

    private func add(_ user: ImmichUser) async {
        guard !sharedUsers.contains(where: { $0.id == user.id }) else { return }
        addingUserId = user.id
        defer { addingUserId = nil }
        do {
            try await ImmichAPI.shared.shareAlbum(id: album.id, userIds: [user.id])
            sharedUsers.append(SharedUser(id: user.id, email: user.email))
            onChange(sharedUsers)
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }

    private func remove(_ user: SharedUser) async {
        let snapshot = sharedUsers
        sharedUsers.removeAll { $0.id == user.id }
        do {
            try await ImmichAPI.shared.unshareAlbum(id: album.id, userId: user.id)
            onChange(sharedUsers)
            HapticManager.notification(.success)
        } catch {
            sharedUsers = snapshot
            HapticManager.notification(.error)
        }
    }
}
