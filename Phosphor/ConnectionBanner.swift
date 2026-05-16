import SwiftUI

/// Top-anchored overlay that appears when the server has been unreachable for
/// more than 3 seconds continuously. Self-debounces via a cancellable Task so
/// brief blips don't flash the banner on/off.
struct ConnectionBanner: View {
    @ObservedObject var connection: ConnectionManager

    @State private var isVisible = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var isRetrying = false

    private static let debounceSeconds: UInt64 = 3

    var body: some View {
        Group {
            if isVisible {
                content
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .onAppear { reevaluate(connection.isConnected, configured: connection.isConfigured) }
        .onChange(of: connection.isConnected) { _, connected in
            reevaluate(connected, configured: connection.isConfigured)
        }
        .onChange(of: connection.isConfigured) { _, configured in
            reevaluate(connection.isConnected, configured: configured)
        }
    }

    private var content: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Server unreachable")
                .font(Typography.captionBold)
                .foregroundStyle(.white)
            Spacer()
            retryButton
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.red.opacity(0.85))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server unreachable. Double tap to retry.")
    }

    @ViewBuilder
    private var retryButton: some View {
        if isRetrying {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else {
            Button("Retry") {
                Task { await retry() }
            }
            .font(Typography.captionBold)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.18), in: Capsule())
        }
    }

    private func reevaluate(_ connected: Bool, configured: Bool) {
        // Onboarding gate: never show the banner before the user has
        // completed onboarding — the onboarding sheet handles that surface.
        guard configured else {
            debounceTask?.cancel()
            isVisible = false
            return
        }

        if connected {
            debounceTask?.cancel()
            isVisible = false
            return
        }

        // Already debouncing — let the existing task decide.
        guard debounceTask == nil else { return }

        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            // Re-check at the end of the delay: the connection may have come
            // back while we waited.
            if !connection.isConnected, connection.isConfigured {
                isVisible = true
            }
            debounceTask = nil
        }
    }

    private func retry() async {
        isRetrying = true
        await connection.testAndConnect()
        isRetrying = false
        // `onChange` for isConnected will fire and hide the banner if it
        // succeeded; nothing else to do here.
    }
}
