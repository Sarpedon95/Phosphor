import SwiftUI

/// First-launch wall. Cannot be dismissed until `viewModel.testConnection()`
/// returns `.success`. The parent host (`ContentView`) drives the
/// `fullScreenCover` binding from `ConnectionManager.isConfigured`.
struct OnboardingView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager
    @StateObject private var viewModel: ProfileViewModel

    @State private var showAPIKey = false
    @State private var shake = 0
    @FocusState private var focused: Field?

    private enum Field { case url, apiKey }

    init(connectionManager: ConnectionManager) {
        _viewModel = StateObject(wrappedValue: ProfileViewModel(connectionManager: connectionManager))
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()

            VStack(spacing: Spacing.xxl) {
                Spacer(minLength: 0)
                wordmark
                Spacer(minLength: 0)
                form
                connectButton
                errorMessage
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxl)
        }
        .interactiveDismissDisabled(true)
        .preferredColorScheme(.dark)
    }

    private var wordmark: some View {
        VStack(spacing: Spacing.s) {
            Text("Phosphor")
                .font(Typography.wordmark)
                .foregroundStyle(.phosphorPrimary)
            Text("Your photos. Your server. Your way.")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var form: some View {
        VStack(spacing: Spacing.m) {
            field {
                TextField("Server URL", text: $viewModel.serverURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focused, equals: .url)
                    .submitLabel(.next)
                    .onSubmit { focused = .apiKey }
            }
            .accessibilityLabel("Server URL")

            field {
                HStack(spacing: Spacing.s) {
                    apiKeyField
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.phosphorSecondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                }
            }
            .accessibilityLabel("API key")
        }
        .disabled(viewModel.isTestingConnection)
        .modifier(ShakeEffect(amount: shake))
    }

    @ViewBuilder
    private var apiKeyField: some View {
        if showAPIKey {
            TextField("API Key", text: $viewModel.apiKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .apiKey)
                .submitLabel(.go)
                .onSubmit { Task { await connect() } }
        } else {
            SecureField("API Key", text: $viewModel.apiKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .apiKey)
                .submitLabel(.go)
                .onSubmit { Task { await connect() } }
        }
    }

    @ViewBuilder
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: TapTarget.minimum)
            .background(Color.phosphorSurface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
            .foregroundStyle(.phosphorPrimary)
    }

    private var connectButton: some View {
        Button {
            Task { await connect() }
        } label: {
            ZStack {
                Capsule().fill(.phosphorPrimary)
                if viewModel.isTestingConnection {
                    ProgressView().tint(.black)
                } else {
                    Text("Connect")
                        .font(Typography.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .disabled(viewModel.isTestingConnection)
        .accessibilityLabel("Connect to server")
    }

    @ViewBuilder
    private var errorMessage: some View {
        if case .failure(let message) = viewModel.connectionResult {
            Text(message)
                .font(Typography.footnote)
                .foregroundStyle(.phosphorDanger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.s)
                .transition(.opacity)
        }
    }

    private func connect() async {
        focused = nil
        await viewModel.testConnection()
        if case .failure = viewModel.connectionResult {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
                shake += 1
            }
        }
        // Success path: `ConnectionManager.isConfigured` flips and the parent
        // ContentView dismisses the fullScreenCover automatically.
    }
}

/// Horizontal shake animation used for invalid-credentials feedback.
private struct ShakeEffect: GeometryEffect {
    var amount: Int
    var animatableData: CGFloat {
        get { CGFloat(amount) }
        set { amount = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(CGFloat(amount) * .pi * 2) * 8
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
