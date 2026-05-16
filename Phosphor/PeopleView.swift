import SwiftUI
import UIKit
import os

/// Horizontal strip of recognized faces. Expects an enclosing `NavigationStack`
/// that registers a `navigationDestination(for: Person.self)`.
struct PeopleView: View {
    @State private var people: [Person] = []

    var body: some View {
        Group {
            if people.isEmpty {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.m + 2) {
                        ForEach(people) { person in
                            NavigationLink(value: person) {
                                VStack(spacing: Spacing.xs + 2) {
                                    PersonAvatar(personId: person.id)
                                        .frame(width: 64, height: 64)
                                    Text(person.displayName)
                                        .font(Typography.caption)
                                        .foregroundStyle(.phosphorPrimary)
                                        .lineLimit(1)
                                        .frame(width: 68)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photos of \(person.displayName)")
                            .accessibilityAddTraits(.isLink)
                            .contextMenu {
                                Button {
                                    Task { await hide(person) }
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                }
            }
        }
        .task {
            guard people.isEmpty else { return }
            do {
                let fetched = try await ImmichAPI.shared.fetchPeople()
                people = fetched.filter { !$0.name.isEmpty }
            } catch {
                // People strip is decorative — log and hide silently.
                Logger(subsystem: "com.sarpedon.phosphor", category: "people")
                    .error("People load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func hide(_ person: Person) async {
        // Optimistic removal — server PATCH happens in parallel; if it fails
        // the strip will repopulate on next load.
        people.removeAll { $0.id == person.id }
        do {
            _ = try await ImmichAPI.shared.updatePerson(id: person.id, isHidden: true)
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

struct PersonAvatar: View {
    let personId: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color.phosphorSurface)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.phosphorSecondary)
                    }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .task(id: personId) {
            image = await ImageLoader.shared.personThumbnail(for: personId)
        }
    }
}
