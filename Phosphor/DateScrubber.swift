import SwiftUI

/// Vertical fast-scroll scrubber pinned to the right edge of the Library
/// timeline. The host wraps its `ScrollView` in a `ScrollViewReader` and
/// passes the proxy in; the scrubber calls `scrollTo` to jump sections.
///
/// Only visible when the timeline has more than 3 sections.
struct DateScrubber: View {
    let groups: [TimelineGroup]
    let proxy: ScrollViewProxy

    @State private var isDragging = false
    @State private var draggedIndex: Int?
    @GestureState private var dragLocation: CGPoint = .zero

    var body: some View {
        // Hide entirely when there aren't enough sections to justify a fast
        // scroll affordance — keeps the right edge clean for short libraries.
        if groups.count <= 3 {
            EmptyView()
        } else {
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    HStack(spacing: Spacing.sm) {
                        if isDragging, let idx = draggedIndex, groups.indices.contains(idx) {
                            Text(groups[idx].title)
                                .font(Typography.title3)
                                .foregroundStyle(.phosphorAccent)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(.ultraThinMaterial, in: Capsule())
                                .transition(.opacity)
                        }
                        Capsule()
                            .fill(Color.phosphorSurface)
                            .frame(width: 2, height: geo.size.height * 0.7)
                            .overlay(alignment: .top) {
                                if isDragging, let idx = draggedIndex {
                                    let y = thumbOffset(for: idx, in: geo.size)
                                    Circle()
                                        .fill(Color.phosphorAccent)
                                        .frame(width: 10, height: 10)
                                        .offset(x: 0, y: y - 5)
                                }
                            }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, Spacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                // High-priority drag: when the user grabs the scrubber, we
                // win over the underlying ScrollView's vertical pan and don't
                // try to share gesture state (which would jitter).
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let h = geo.size.height * 0.7
                            let y = max(0, min(h, value.location.y - geo.size.height * 0.15))
                            let fraction = h <= 0 ? 0 : y / h
                            let idx = min(groups.count - 1, max(0, Int(fraction * CGFloat(groups.count))))
                            isDragging = true
                            if draggedIndex != idx {
                                draggedIndex = idx
                                HapticManager.selection()
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(groups[idx].id, anchor: .top)
                                }
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            draggedIndex = nil
                            HapticManager.impact(.light)
                        }
                )
                .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(width: 80)
            .accessibilityLabel("Fast scroll")
            .accessibilityHint("Drag to jump between timeline sections.")
        }
    }

    private func thumbOffset(for index: Int, in size: CGSize) -> CGFloat {
        let h = size.height * 0.7
        guard groups.count > 1 else { return h / 2 }
        return h * CGFloat(index) / CGFloat(groups.count - 1)
    }
}
