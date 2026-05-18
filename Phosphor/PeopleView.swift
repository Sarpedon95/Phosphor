import SwiftUI
import UIKit
import os

/// Horizontal strip of recognized faces. Expects an enclosing `NavigationStack`
/// that registers a `navigationDestination(for: Person.self)`.
struct PeopleView: View {
    @State private var people: [Person] = []
    @State private var error: Error?

    var body: some View {
        content
            .task {
                guard people.isEmpty else { return }
                await loadPeople()
            }
    }

    private func loadPeople() async {
        error = nil
        do {
            let fetched = try await ImmichAPI.shared.fetchPeople()
            people = fetched.filter { !$0.name.isEmpty }
        } catch let caught {
            error = caught
            Logger(subsystem: "com.sarpedon.phosphor", category: "people")
                .error("People load failed: \(caught.localizedDescription, privacy: .public)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl + Spacing.s)
                Button("Retry") { Task { await loadPeople() } }
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityElement(children: .combine)
        } else if people.isEmpty {
            EmptyView()
        } else {
            peopleScrollView
        }
    }

    private var peopleScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.m + 2) {
                ForEach(people) { person in
                    personLink(person)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
        }
    }

    private func personLink(_ person: Person) -> some View {
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
