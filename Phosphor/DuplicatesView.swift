import SwiftUI

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?
    @Published private(set) var index = 0

    var current: DuplicateGroup? {
        groups.indices.contains(index) ? groups[index] : nil
    }

    var reviewedCount: Int { index }

    func load() async {
        guard groups.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            groups = try await ImmichAPI.shared.fetchDuplicates()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func skip() {
        advance()
    }

    func keep(_ keeper: ImmichAsset) async {
        guard let group = current else { return }
        let others = group.assets.filter { $0.id != keeper.id }.map(\.id)
        guard !others.isEmpty else { advance(); return }
        do {
            try await ImmichAPI.shared.trashAssets(ids: others)
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
        advance()
    }

    func stackAll() async {
        guard let group = current else { return }
        do {
            try await ImmichAPI.shared.createStack(assetIds: group.assets.map(\.id))
            HapticManager.notification(.success)
        } catch {
            HapticManager.notification(.error)
        }
        advance()
    }

    private func advance() {
        if index < groups.count { index += 1 }
    }
}

struct DuplicatesView: View {
    @StateObject private var viewModel = DuplicatesViewModel()

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.groups.isEmpty {
            ProgressView().tint(.phosphorPrimary)
        } else if let error = viewModel.error, viewModel.groups.isEmpty {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.yellow)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                Button("Retry") { Task { await viewModel.load() } }
                    .foregroundStyle(.phosphorPrimary)
            }
        } else if let group = viewModel.current {
            reviewCard(group)
        } else {
            VStack(spacing: Spacing.m + 2) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSuccess)
                Text(viewModel.groups.isEmpty ? "No duplicates found" : "All duplicates reviewed")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func reviewCard(_ group: DuplicateGroup) -> some View {
        VStack(spacing: Spacing.l) {
            Text("\(viewModel.reviewedCount + 1) of \(viewModel.groups.count) groups")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)

            ScrollView {
                VStack(spacing: Spacing.m) {
                    ForEach(group.assets) { asset in
                        DuplicateRow(asset: asset) {
                            Task { await viewModel.keep(asset) }
                        }
                    }
                }
                .padding(.horizontal, Spacing.l)
            }

            HStack(spacing: Spacing.m) {
                actionButton("Skip", "arrow.right.circle", tint: .phosphorSecondary) {
                    HapticManager.impact(.light)
                    viewModel.skip()
                }
                actionButton("Stack", "square.stack.3d.up", tint: .phosphorPrimary) {
                    Task { await viewModel.stackAll() }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .padding(.top, Spacing.l)
    }

    private func actionButton(
        _ title: String,
        _ symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Typography.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.m)
                .background(tint, in: Capsule())
        }
        .accessibilityLabel(title)
    }
}

private struct DuplicateRow: View {
    let asset: ImmichAsset
    let onKeep: () -> Void

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ShimmerView()
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(asset.originalFileName)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .lineLimit(1)
                Text(asset.localDateTime.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                if let size = asset.fileSizeInByte {
                    Text(StorageFormatter.string(fromBytes: size))
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            }
            Spacer()
            Button("Keep", action: onKeep)
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
                .accessibilityLabel("Keep \(asset.originalFileName), trash the others")
        }
        .padding(Spacing.m)
        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        .task(id: asset.id) {
            image = await ImageLoader.shared.thumbnail(for: asset.id, size: .preview)
        }
    }
}
