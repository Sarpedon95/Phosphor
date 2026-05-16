import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
struct PhosphorLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhosphorBackupActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Backup", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.uploaded)/\(context.state.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.currentFileName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: fraction(context.state))
                        .tint(.white)
                }
            } compactLeading: {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text("\(context.state.uploaded)/\(context.state.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            } minimal: {
                ProgressView(value: fraction(context.state))
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            .keylineTint(.white)
        }
    }

    private func fraction(_ state: PhosphorBackupActivityAttributes.ContentState) -> Double {
        guard state.total > 0 else { return 0 }
        return min(1, Double(state.uploaded) / Double(state.total))
    }
}

@available(iOS 16.2, *)
private struct LockScreenLiveActivityView: View {
    let state: PhosphorBackupActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: state.isFailed ? "exclamationmark.circle" : "arrow.up.circle")
                Text(state.isFailed ? "Backup paused" : "Backing up to Phosphor")
                    .font(.headline)
                Spacer()
                Text("\(state.uploaded)/\(state.total)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)

            if !state.currentFileName.isEmpty {
                Text(state.currentFileName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            ProgressView(value: state.total == 0 ? 0 : Double(state.uploaded) / Double(state.total))
                .tint(.white)
        }
        .padding()
    }
}

@available(iOS 16.2, *)
@main
struct PhosphorLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PhosphorLiveActivityWidget()
    }
}
#endif
