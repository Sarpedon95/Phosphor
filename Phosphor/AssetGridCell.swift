import SwiftUI
import UIKit

enum AssetContextAction {
    case favorite
    case archive
    case addToAlbum
    case share
    case trash
}

/// Square async thumbnail cell shared by every asset grid (timeline, album
/// detail, favorites, search results, person detail).
struct AssetGridCell: View {
    let asset: ImmichAsset
    var imageLoader: ImageLoader = .shared
    var onContextAction: ((AssetContextAction) -> Void)? = nil

    @State private var image: UIImage?

    var body: some View {
        // Attach the built-in context menu only when a handler is supplied,
        // so call sites with their own custom .contextMenu remain unaffected.
        if let onContextAction {
            base.contextMenu {
                contextMenuItems(onContextAction)
            }
        } else {
            base
        }
    }

    private var base: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    ShimmerView()
                }

                badges
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
            .overlay {
                // 5-star assets get a subtle gold border.
                if asset.ratingValue == 5 {
                    Rectangle()
                        .strokeBorder(Color(.systemYellow).opacity(0.85), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.id) {
            image = await imageLoader.thumbnail(for: asset.id, size: .thumbnail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to open")
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func contextMenuItems(_ onContextAction: @escaping (AssetContextAction) -> Void) -> some View {
        Button {
            onContextAction(.favorite)
        } label: {
            Label(
                asset.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: asset.isFavorite ? "heart.slash" : "heart"
            )
        }
        Button {
            onContextAction(.archive)
        } label: {
            Label(
                asset.isArchived ? "Unarchive" : "Archive",
                systemImage: asset.isArchived ? "tray.and.arrow.up" : "archivebox"
            )
        }
        Button {
            onContextAction(.addToAlbum)
        } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
        Button {
            onContextAction(.share)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            onContextAction(.trash)
        } label: {
            Label("Trash", systemImage: "trash")
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        parts.append(asset.isVideo ? "Video" : "Photo")
        if asset.isLivePhoto { parts.append("live photo") }
        if asset.isFavorite { parts.append("favorite") }
        if asset.ratingValue > 0 { parts.append("\(asset.ratingValue) star\(asset.ratingValue == 1 ? "" : "s")") }
        if asset.isStacked { parts.append("stack of \(asset.stackCount ?? 0)") }
        parts.append(asset.originalFileName)
        return parts.joined(separator: ", ")
    }

    private var badges: some View {
        VStack {
            HStack {
                if asset.ratingValue >= 4 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.systemYellow))
                        .shadow(radius: 2)
                } else if asset.isLivePhoto {
                    badge("livephoto")
                }
                Spacer()
                if asset.isFavorite {
                    badge("heart.fill")
                }
            }
            Spacer()
            HStack {
                if asset.isVideo {
                    badge("video.fill")
                }
                Spacer()
                if asset.isStacked {
                    stackBadge
                }
            }
        }
        .padding(Spacing.xs + 1)
    }

    private var stackBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "square.stack.3d.up.fill")
            Text("\(asset.stackCount ?? 0)")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.phosphorPrimary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func badge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.phosphorPrimary)
            .shadow(radius: 2)
    }
}

/// Subtle left-to-right shimmer placeholder shown while a thumbnail loads.
struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(Color.phosphorPlaceholder)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: phase * geo.size.width)
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
