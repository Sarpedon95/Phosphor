import SwiftUI
import UIKit

struct MemoryDetailView: View {
    let memory: ImmichMemory
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var paused = false
    @State private var collageAssets: CollageAssetSelection?
    @State private var isSaved = false
    @State private var showDeleteConfirm = false

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var assets: [ImmichAsset] { memory.assets }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()

            if assets.indices.contains(index) {
                MemorySlide(assetId: assets[index].id)
                    .id(assets[index].id)
                    .transition(.opacity)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                reactionBar
                progressBar
            }
        }
        .alert("Remove memory?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await removeMemory() } }
        } message: {
            Text("This will hide the memory from your library. The photos are not deleted.")
        }
        .contentShape(Rectangle())
        .onTapGesture { paused.toggle() }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -50 {
                        advance(1)
                    } else if value.translation.width > 50 {
                        advance(-1)
                    }
                }
        )
        .onReceive(timer) { _ in
            // No auto-advance for single-asset memories or while paused.
            guard !paused, assets.count > 1 else { return }
            advance(1)
        }
        .statusBarHidden(true)
        .fullScreenCover(item: $collageAssets) { selection in
            CollageView(assets: selection.assets)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.phosphorPrimary)
            }
            .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .accessibilityLabel("Close memory")
            Spacer()
            Text("\(index + 1) / \(assets.count)")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
                .accessibilityLabel("Photo \(index + 1) of \(assets.count)")
            if assets.count >= 2 {
                Button {
                    collageAssets = CollageAssetSelection(assets: assets)
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.phosphorPrimary)
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
                .accessibilityLabel("Create collage from memory")
                .padding(.leading, Spacing.md)
            }
        }
        .padding(.horizontal, Spacing.l + Spacing.xs)
        .padding(.top, Spacing.l)
    }

    private var reactionBar: some View {
        HStack(spacing: Spacing.lg) {
            Button { Task { await toggleSaved() } } label: {
                VStack(spacing: 2) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isSaved ? .phosphorDanger : .phosphorPrimary)
                    Text(isSaved ? "Saved" : "Save")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorPrimary)
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            }
            .accessibilityLabel(isSaved ? "Unsave memory" : "Save memory")

            Button { showDeleteConfirm = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.phosphorPrimary)
                    Text("Archive")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorPrimary)
                }
                .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            }
            .accessibilityLabel("Archive memory")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
    }

    private func toggleSaved() async {
        let previous = isSaved
        isSaved.toggle()
        do {
            try await ImmichAPI.shared.toggleMemorySaved(id: memory.id, saved: isSaved)
            HapticManager.notification(.success)
        } catch {
            isSaved = previous
            HapticManager.notification(.error)
        }
    }

    private func removeMemory() async {
        do {
            try await ImmichAPI.shared.deleteMemory(id: memory.id)
            HapticManager.notification(.success)
            dismiss()
        } catch {
            HapticManager.notification(.error)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.phosphorPrimary.opacity(0.25))
                Capsule()
                    .fill(.phosphorPrimary)
                    .frame(
                        width: geo.size.width * progress
                    )
            }
        }
        .frame(height: 3)
        .padding(.horizontal, Spacing.l + Spacing.xs)
        .padding(.bottom, Spacing.xl)
        .accessibilityHidden(true)
    }

    private var progress: CGFloat {
        guard assets.count > 1 else { return 1 }
        return CGFloat(index + 1) / CGFloat(assets.count)
    }

    private func advance(_ delta: Int) {
        guard assets.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.6)) {
            index = (index + delta + assets.count) % assets.count
        }
    }
}

private struct MemorySlide: View {
    let assetId: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: assetId) {
            image = await ImageLoader.shared.fullImage(for: assetId)
        }
    }
}
