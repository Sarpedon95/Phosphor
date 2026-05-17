import SwiftUI
import UIKit

@MainActor
final class SharedLinksViewModel: ObservableObject {
    @Published private(set) var links: [SharedLink] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            links = try await ImmichAPI.shared.fetchSharedLinks()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func delete(_ link: SharedLink) async {
        let snapshot = links
        links.removeAll { $0.id == link.id }
        do {
            try await ImmichAPI.shared.deleteSharedLink(id: link.id)
        } catch {
            links = snapshot
            HapticManager.notification(.error)
        }
    }
}

struct SharedLinksView: View {
    @StateObject private var viewModel = SharedLinksViewModel()
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Shared Links")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create shared link")
            }
        }
        .task { if viewModel.links.isEmpty { await viewModel.load() } }
        .sheet(isPresented: $showCreate) {
            SharedLinkCreateView(linkType: .album, assetIds: [])
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.links.isEmpty && viewModel.isLoading {
            ProgressView().tint(.phosphorPrimary)
        } else if viewModel.links.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "link")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("No shared links")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            List {
                ForEach(viewModel.links) { link in
                    row(link)
                        .listRowBackground(Color.phosphorSurface)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await viewModel.delete(link) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await viewModel.load() }
        }
    }

    private func row(_ link: SharedLink) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: link.type == .album ? "rectangle.stack" : "photo")
                .foregroundStyle(.phosphorSecondary)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(link.description ?? (link.type == .album ? "Album link" : "Photo link"))
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .lineLimit(1)
                if let expires = link.expiresAt {
                    Text("Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                } else {
                    Text("No expiry")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            }
            Spacer()
            Button {
                copyLink(link)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.phosphorPrimary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy link")
        }
    }

    private func copyLink(_ link: SharedLink) {
        if let base = UserDefaults.phosphor.string(forKey: ImmichAPI.DefaultsKey.baseURL) {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            UIPasteboard.general.string = "\(trimmed)/share/\(link.key)"
            HapticManager.notification(.success)
        }
    }
}

// MARK: - Create

struct SharedLinkCreateView: View {
    let linkType: SharedLinkType
    let assetIds: [String]
    var albumId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var password = ""
    @State private var useExpiry = false
    @State private var expiryDate = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var allowDownload = true
    @State private var showMetadata = true
    @State private var isCreating = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                Form {
                    Section {
                        TextField("Description (optional)", text: $description)
                            .listRowBackground(Color.phosphorSurface)
                        SecureField("Password (optional)", text: $password)
                            .listRowBackground(Color.phosphorSurface)
                    }
                    Section { expirySectionContent }
                    Section {
                        Toggle("Allow download", isOn: $allowDownload)
                            .tint(.phosphorPrimary)
                            .listRowBackground(Color.phosphorSurface)
                        Toggle("Show metadata", isOn: $showMetadata)
                            .tint(.phosphorPrimary)
                            .listRowBackground(Color.phosphorSurface)
                    }
                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorDanger)
                                .listRowBackground(Color.phosphorSurface)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Shared Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small).tint(.phosphorPrimary)
                        } else {
                            Text("Create & Copy")
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var expirySectionContent: some View {
        Toggle("Set expiry", isOn: $useExpiry)
            .tint(.phosphorPrimary)
            .listRowBackground(Color.phosphorSurface)
        if useExpiry {
            DatePicker("Expires", selection: $expiryDate, displayedComponents: .date)
                .listRowBackground(Color.phosphorSurface)
        }
    }

    private func create() async {
        isCreating = true
        errorText = nil
        defer { isCreating = false }
        do {
            let link = try await ImmichAPI.shared.createSharedLink(
                type: linkType,
                albumId: albumId,
                assetIds: assetIds,
                description: description.isEmpty ? nil : description,
                password: password.isEmpty ? nil : password,
                expiresAt: useExpiry ? expiryDate : nil,
                allowDownload: allowDownload,
                showMetadata: showMetadata
            )
            if let base = UserDefaults.phosphor.string(forKey: ImmichAPI.DefaultsKey.baseURL) {
                let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                UIPasteboard.general.string = "\(trimmed)/share/\(link.key)"
            }
            HapticManager.notification(.success)
            dismiss()
        } catch let caught {
            errorText = (caught as? ImmichError)?.localizedDescription
                ?? caught.localizedDescription
            HapticManager.notification(.error)
        }
    }
}
