import SwiftUI
import UIKit

struct MemoryDetailView: View {
    let memory: ImmichMemory
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var paused = false
    @State private var collageAssets: CollageAssetSelection?

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
                progressBar
            }
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
