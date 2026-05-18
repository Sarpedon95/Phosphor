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
    @State private var showMergePicker = false
    @State private var mergeTarget: Person?
    @State private var mergeError: String?

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
                    if let formattedBirth = formattedBirthDate {
                        Text("Born \(formattedBirth)")
                            .font(Typography.subheadline)
                            .foregroundStyle(.phosphorSecondary)
                            .padding(.top, Spacing.s)
                            .accessibilityLabel("Born \(formattedBirth)")
                    }
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
        .toolbar {
            ToolbarItem(placement: .principal) { titleField }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMergePicker = true
                } label: {
                    Image(systemName: "person.2.crop.square.stack")
                }
                .accessibilityLabel("Merge with another person")
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showMergePicker) {
            PersonPickerView(excludePersonId: displayPerson.id) { picked in
                showMergePicker = false
                mergeTarget = picked
            }
        }
        .alert("Merge \(displayPerson.displayName) into \(mergeTarget?.displayName ?? "")?",
               isPresented: Binding(
                get: { mergeTarget != nil },
                set: { if !$0 { mergeTarget = nil } }
               ),
               presenting: mergeTarget) { target in
            Button("Cancel", role: .cancel) { mergeTarget = nil }
            Button("Merge", role: .destructive) {
                Task { await mergeInto(target) }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .alert("Merge failed",
               isPresented: Binding(
                get: { mergeError != nil },
                set: { if !$0 { mergeError = nil } }
               ),
               presenting: mergeError) { _ in
            Button("OK", role: .cancel) { mergeError = nil }
        } message: { message in
            Text(message)
        }
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

    private var formattedBirthDate: String? {
        guard let raw = displayPerson.birthDate, !raw.isEmpty else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        // Also try plain yyyy-MM-dd (what Immich often returns for birthdates).
        let date: Date? = isoFractional.date(from: raw)
            ?? iso.date(from: raw)
            ?? Self.dayFormatter.date(from: raw)
        guard let date else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    private func mergeInto(_ target: Person) async {
        do {
            try await ImmichAPI.shared.mergePerson(
                sourceId: displayPerson.id,
                destinationId: target.id
            )
            HapticManager.notification(.success)
            mergeTarget = nil
        } catch ImmichError.serverError(404) {
            mergeError = "Your Immich server version doesn't support merging faces."
            mergeTarget = nil
            HapticManager.notification(.error)
        } catch {
            mergeError = error.localizedDescription
            mergeTarget = nil
            HapticManager.notification(.error)
        }
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
