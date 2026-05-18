import SwiftUI

/// Lets the user pick a destination person from the list of recognized faces.
/// Used by the "Merge with…" flow in PersonDetailView.
struct PersonPickerView: View {
    let excludePersonId: String
    let onPick: (Person) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var people: [Person] = []
    @State private var isLoading = false
    @State private var error: ImmichError?
    @State private var query = ""

    private var filtered: [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = people.filter { $0.id != excludePersonId && !$0.name.isEmpty }
        if q.isEmpty { return base }
        return base.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Merge with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .task { if people.isEmpty { await load() } }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && people.isEmpty {
            ProgressView().tint(.phosphorPrimary)
        } else if let error, people.isEmpty {
            VStack(spacing: Spacing.m) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await load() } }
                    .foregroundStyle(.phosphorAccent)
            }
        } else {
            List(filtered) { person in
                Button {
                    onPick(person)
                } label: {
                    HStack(spacing: Spacing.md) {
                        PersonAvatar(personId: person.id)
                            .frame(width: 36, height: 36)
                        Text(person.displayName)
                            .foregroundStyle(.phosphorPrimary)
                        Spacer()
                    }
                }
                .listRowBackground(Color.phosphorSurface)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            people = try await ImmichAPI.shared.fetchPeople()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }
}
