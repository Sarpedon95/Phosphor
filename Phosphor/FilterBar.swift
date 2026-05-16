import SwiftUI

/// Horizontal chip row pinned below the Library nav bar. Mutates
/// `LibraryViewModel.activeFilters`; an empty set means "All".
struct FilterBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let order: [AssetFilter] = [
        .photos, .videos, .favorites, .flagged, .fourStarPlus,
        .livePhotos, .screenshots, .raw
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                allChip
                ForEach(order) { filter in
                    chip(for: filter)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
        .background(Color.phosphorBackground)
    }

    private var allChip: some View {
        let isActive = viewModel.activeFilters.isEmpty
        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                viewModel.activeFilters.removeAll()
            }
        } label: {
            chipBody(title: "All", count: viewModel.totalAssetCount, isActive: isActive)
        }
        .accessibilityLabel("All photos, \(viewModel.totalAssetCount)")
    }

    private func chip(for filter: AssetFilter) -> some View {
        let isActive = viewModel.activeFilters.contains(filter)
        let count = countFor(filter)
        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isActive {
                    viewModel.activeFilters.remove(filter)
                } else {
                    viewModel.activeFilters.insert(filter)
                }
            }
        } label: {
            chipBody(title: filter.label, count: count, isActive: isActive)
        }
        .accessibilityLabel("\(filter.label), \(count)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func chipBody(title: String, count: Int, isActive: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
                .font(Typography.captionBold)
            Text("\(count)")
                .font(Typography.caption)
                .foregroundStyle(isActive ? .black.opacity(0.6) : .phosphorSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: TapTarget.minimum)
        .background(
            Capsule().fill(isActive ? Color.phosphorAccent : Color.phosphorSurface)
        )
        .foregroundStyle(isActive ? Color.black : Color.phosphorAccent)
        .scaleEffect(isActive ? 1.04 : 1.0)
    }

    private func countFor(_ filter: AssetFilter) -> Int {
        // Cheap derivation; the timeline is bounded by pageSize×pages so this
        // stays linear-small.
        viewModel.filteredCount(forSingleFilter: filter)
    }
}

extension LibraryViewModel {
    /// Count assets matching exactly one chip's predicate (independent of the
    /// current selection) — used to show per-chip badges.
    func filteredCount(forSingleFilter filter: AssetFilter) -> Int {
        let calendar = Calendar.current
        _ = calendar
        return allFlatAssets().filter { asset in
            switch filter {
            case .photos: return asset.type == .image
            case .videos: return asset.type == .video
            case .favorites: return asset.isFavorite
            case .livePhotos: return asset.isLivePhoto
            case .screenshots:
                return asset.originalFileName.localizedCaseInsensitiveContains("screenshot")
            case .raw:
                let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
                return ["cr2", "arw", "nef", "dng", "rw2", "raf", "orf"].contains(ext)
            case .fourStarPlus:
                return asset.ratingValue >= 4
            case .flagged:
                return asset.isFavorite
            }
        }.count
    }

    /// Flatten without exposing `allAssets`. Reads from groupedAssets so the
    /// count tracks what the user has loaded.
    func allFlatAssets() -> [ImmichAsset] {
        groupedAssets.flatMap(\.assets)
    }
}
