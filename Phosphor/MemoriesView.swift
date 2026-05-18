import SwiftUI
import UIKit
import os

/// Horizontal strip of memory cards shown above the timeline in LibraryView.
struct MemoriesView: View {
    @State private var memories: [ImmichMemory] = []
    @State private var selected: ImmichMemory?
    @State private var error: Error?

    var body: some View {
        memoriesContent
            .task {
                guard memories.isEmpty else { return }
                await loadMemories()
            }
            .fullScreenCover(item: $selected) { memory in
                MemoryDetailView(memory: memory)
            }
    }

    private func loadMemories() async {
        error = nil
        do {
            let fetched = try await ImmichAPI.shared.fetchMemories()
            memories = fetched.filter { !$0.assets.isEmpty }
        } catch let caught {
            error = caught
            Logger(subsystem: "com.sarpedon.phosphor", category: "memories")
                .error("Memories load failed: \(caught.localizedDescription, privacy: .public)")
        }
    }

    @ViewBuilder
    private var memoriesContent: some View {
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
                Button("Retry") { Task { await loadMemories() } }
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityElement(children: .combine)
        } else if memories.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                    ForEach(memories) { memory in
                        Button {
                            HapticManager.impact(.light)
                            selected = memory
                        } label: {
                            MemoryCard(memory: memory)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(memory.title), \(memory.assets.count) photos")
                        .accessibilityHint("Opens a slideshow of this memory.")
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
            }
        }
    }
}

private struct MemoryCard: View {
    let memory: ImmichMemory
    @State private var image: UIImage?

    /// Prefer the title Immich returned; if it's an integer (year offset),
    /// render a human-friendly "{N} Years Ago" / "Last Year" / "This Year".
    private var displayTitle: String {
        let raw = memory.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = Int(raw) else { return raw }
        let currentYear = Calendar.current.component(.year, from: Date())
        let diff = currentYear - year
        switch diff {
        case 0: return "This Year"
        case 1: return "Last Year"
        case 2..<100: return "\(diff) Years Ago"
        default: return raw
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 6)
            } else {
                Color.phosphorPlaceholder
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(displayTitle)
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                    .lineLimit(2)
                Text("\(memory.assets.count) \(memory.assets.count == 1 ? "photo" : "photos")")
                    .font(Typography.caption)
                    .foregroundStyle(Color.phosphorPrimary.opacity(0.8))
            }
            .padding(Spacing.m)
        }
        .frame(width: 160, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        .task(id: memory.id) {
            if let first = memory.assets.first {
                image = await ImageLoader.shared.thumbnail(for: first.id, size: .preview)
            }
        }
    }
}
