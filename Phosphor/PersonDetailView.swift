import SwiftUI

struct PersonDetailView: View {
    let person: Person
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var displayPerson: Person
    @State private var assets: [ImmichAsset] = []
    @State private var isLoading = false
    @State private var loadError: ImmichError?
    @State private var selection: PhotoSelection?
    @State private var isEditingName = false
    @State private var nameDraft = ""

    init(person: Person) {
        self.person = person
        _displayPerson = State(initialValue: person)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 2),
            count: horizontalSizeClass == .regular ? 4 : 3
        )
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            if assets.isEmpty && isLoading {
                ProgressView().tint(.phosphorPrimary)
            } else if let loadError, assets.isEmpty {
                VStack(spacing: Spacing.m + 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.yellow)
                    Text(loadError.localizedDescription)
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xxl + Spacing.s)
                    Button("Retry") { Task { await load() } }
                        .foregroundStyle(.phosphorPrimary)
                        .accessibilityHint("Tries loading these photos again.")
                }
            } else if assets.isEmpty {
                VStack(spacing: Spacing.m + 2) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.phosphorSecondary)
                    Text("No photos of \(displayPerson.displayName)")
                        .font(Typography.headline)
                        .foregroundStyle(.phosphorPrimary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets) { asset in
                            AssetGridCell(asset: asset)
                                .onTapGesture {
                                    HapticManager.impact(.light)
                                    open(asset)
                                }
                        }
                    }
                    .padding(.bottom, Spacing.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationTitle("")   // custom title via toolbar so the tap-to-rename works.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { titleField } }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { if assets.isEmpty { await load() } }
        .fullScreenCover(item: $selection) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index) { change in
                switch change {
                case .favorited(let asset):
                    if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                        assets[i] = asset
                    }
                case .trashed(let id):
                    assets.removeAll { $0.id == id }
                }
            }
        }
    }

    /// Tap title → editable name field; submit / blur saves via PATCH.
    @ViewBuilder
    private var titleField: some View {
        if isEditingName {
            TextField("Name", text: $nameDraft, onCommit: { Task { await saveName() } })
                .foregroundStyle(.phosphorAccent)
                .font(Typography.headline)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .frame(maxWidth: 220)
        } else {
            Button {
                nameDraft = displayPerson.name
                isEditingName = true
            } label: {
                Text(displayPerson.displayName)
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityLabel("\(displayPerson.displayName). Double-tap to rename.")
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            assets = try await ImmichAPI.shared.fetchPersonAssets(personId: displayPerson.id)
        } catch let caught {
            loadError = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    private func open(_ asset: ImmichAsset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        HapticManager.selection()
        selection = PhotoSelection(assets: assets, index: index)
    }

    private func saveName() async {
        let new = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingName = false
        guard !new.isEmpty, new != displayPerson.name else { return }
        do {
            let updated = try await ImmichAPI.shared.updatePerson(id: displayPerson.id, name: new)
            displayPerson = updated
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
    }
}
