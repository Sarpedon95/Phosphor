import SwiftUI

struct ServerProfilesView: View {
    @EnvironmentObject private var profiles: ServerProfilesManager

    @State private var switchTarget: ServerProfile?
    @State private var deleteTarget: ServerProfile?
    @State private var showAdd = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            List {
                ForEach(profiles.profiles) { profile in
                    row(for: profile)
                        .listRowBackground(Color.phosphorSurface)
                }
                .onDelete(perform: deleteRows)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!profiles.canAddMore)
                .accessibilityLabel("Add server")
                .accessibilityHint(profiles.canAddMore
                                   ? "Configure another Immich server."
                                   : "Maximum of \(ServerProfilesManager.maxProfiles) servers reached.")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServerView()
                .environmentObject(profiles)
        }
        .alert(
            "Switch server?",
            isPresented: Binding(
                get: { switchTarget != nil },
                set: { if !$0 { switchTarget = nil } }
            ),
            presenting: switchTarget
        ) { target in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Switch") {
                HapticManager.impact(.medium)
                profiles.switchTo(target)
                switchTarget = nil
            }
        } message: { target in
            Text("Switch to \"\(target.name)\"? Your current library view, image cache, and recent searches will reset.")
        }
        .alert(
            "Delete server?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                profiles.deleteProfile(target)
                deleteTarget = nil
            }
        } message: { target in
            Text("Remove \"\(target.name)\" from saved servers? This does not affect the server itself.")
        }
    }

    private func row(for profile: ServerProfile) -> some View {
        let isActive = profile.id == profiles.activeProfileId
        return Button {
            guard !isActive else { return }
            switchTarget = profile
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .phosphorSuccess : .phosphorSecondary)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorAccent)
                    Text(profile.baseURL)
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                        .lineLimit(1)
                    if let last = profile.lastConnected {
                        Text("Last connected: \(Self.dateFormatter.string(from: last))")
                            .font(Typography.caption)
                            .foregroundStyle(.phosphorSecondary)
                    }
                }
                Spacer()
                if !isActive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.phosphorSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(isActive ? "active" : "inactive")")
        .accessibilityHint(isActive
                           ? "This is the current server."
                           : "Tap to switch to this server.")
    }

    /// `.onDelete` callback. Refuses to delete the active profile.
    private func deleteRows(at offsets: IndexSet) {
        for idx in offsets {
            guard profiles.profiles.indices.contains(idx) else { continue }
            let profile = profiles.profiles[idx]
            if profile.id == profiles.activeProfileId {
                // Active profile must use the explicit alert flow so the user
                // sees the cache-clear consequence. We surface the same alert
                // here so swipe-to-delete on the active row isn't a no-op.
                deleteTarget = profile
            } else {
                deleteTarget = profile
            }
        }
    }
}
