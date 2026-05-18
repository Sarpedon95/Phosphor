import SwiftUI
import Network

/// Three-step onboarding: discovery → login (email/password) → API key
/// fallback. Cannot be dismissed until a connection is established; the parent
/// `ContentView` drives the `fullScreenCover` binding from
/// `ConnectionManager.isConfigured`.
struct OnboardingView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager

    enum Step: Hashable {
        case discovery
        case login(serverURL: String)
        case apiKey(serverURL: String)
    }

    @State private var step: Step = .discovery

    init(connectionManager: ConnectionManager) {
        // Parameter kept for source compatibility with the existing
        // ContentView call site (`OnboardingView(connectionManager:)`).
        _ = connectionManager
    }

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            stepView
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .animation(.easeInOut(duration: 0.22), value: step)
        .interactiveDismissDisabled(true)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .discovery:
            DiscoveryStep(step: $step)
        case .login(let serverURL):
            LoginStep(step: $step, serverURL: serverURL)
        case .apiKey(let serverURL):
            APIKeyStep(step: $step, serverURL: serverURL)
        }
    }
}

// MARK: - Step 1: Discovery

private struct DiscoveryStep: View {
    @Binding var step: OnboardingView.Step

    @State private var manualURL = ""
    @StateObject private var discovery = MDNSDiscovery()
    @State private var showQR = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            wordmark
                .padding(.top, Spacing.xxl)

            discoveryStatus
            discoveredList
                .frame(maxHeight: 240)

            manualEntry
            qrButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear {
            discovery.start(duration: 8)
        }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showQR) {
            QRScannerView { code in
                showQR = false
                if let url = parseURL(code) {
                    step = .login(serverURL: url)
                }
            }
        }
    }

    private var wordmark: some View {
        VStack(spacing: Spacing.s) {
            Text("Phosphor")
                .font(Typography.wordmark)
                .foregroundStyle(.phosphorPrimary)
            Text("Find your Immich server")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        if discovery.isScanning {
            HStack(spacing: Spacing.sm) {
                ProgressView().tint(.phosphorAccent)
                Text("Searching your network…")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
            }
        } else if discovery.servers.isEmpty {
            Text("No servers found nearby")
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorSecondary)
        }
    }

    @ViewBuilder
    private var discoveredList: some View {
        if !discovery.servers.isEmpty {
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(discovery.servers) { server in
                        Button {
                            HapticManager.selection()
                            step = .login(serverURL: server.url)
                        } label: {
                            HStack(spacing: Spacing.md) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(Typography.subheadline)
                                        .foregroundStyle(.phosphorPrimary)
                                    Text(server.displayHost)
                                        .font(Typography.caption)
                                        .foregroundStyle(.phosphorSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.phosphorSecondary)
                            }
                            .padding(Spacing.md)
                            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connect to \(server.name) at \(server.displayHost)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Or enter server address")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
            HStack(spacing: Spacing.sm) {
                TextField("https://photos.example.com", text: $manualURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(Spacing.sm)
                    .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                    .foregroundStyle(.phosphorPrimary)
                Button("Continue") {
                    let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    step = .login(serverURL: trimmed)
                }
                .font(Typography.subheadline.bold())
                .foregroundStyle(manualURL.isEmpty ? .phosphorSecondary : .phosphorAccent)
                .disabled(manualURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var qrButton: some View {
        Button {
            showQR = true
        } label: {
            HStack {
                Image(systemName: "qrcode.viewfinder")
                Text("Scan QR code")
            }
            .font(Typography.subheadline)
            .foregroundStyle(.phosphorAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(Color.phosphorSurface, in: Capsule())
        }
        .accessibilityLabel("Scan a QR code to fill the server address")
    }

    private func parseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return trimmed
    }
}

// MARK: - Step 2: Login (email + password)

private struct LoginStep: View {
    @Binding var step: OnboardingView.Step
    let serverURL: String

    @EnvironmentObject private var connectionManager: ConnectionManager

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var shake = 0
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            fields
                .modifier(ShakeEffect(amount: shake))
            signInButton
            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorDanger)
                    .transition(.opacity)
            }
            Spacer()
            apiKeyFallback
        }
        .padding(Spacing.xl)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                step = .discovery
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityLabel("Back to discovery")

            Text("Sign in")
                .font(Typography.displayTitle)
                .foregroundStyle(.phosphorPrimary)
            Text(serverURL)
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var fields: some View {
        VStack(spacing: Spacing.md) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .submitLabel(.next)
                .onSubmit { focused = .password }
                .padding(Spacing.md)
                .frame(minHeight: TapTarget.minimum)
                .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                .foregroundStyle(.phosphorPrimary)

            HStack(spacing: Spacing.sm) {
                Group {
                    if showPassword {
                        TextField("Password", text: $password)
                            .textContentType(.password)
                    } else {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signIn() } }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.phosphorSecondary)
                }
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
            .padding(Spacing.md)
            .frame(minHeight: TapTarget.minimum)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
            .foregroundStyle(.phosphorPrimary)
        }
        .disabled(isSubmitting)
    }

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            ZStack {
                Capsule().fill(.phosphorPrimary)
                if isSubmitting {
                    ProgressView().tint(.black)
                } else {
                    Text("Sign In")
                        .font(Typography.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .disabled(isSubmitting || email.isEmpty || password.isEmpty)
    }

    private var apiKeyFallback: some View {
        HStack {
            Spacer()
            Button {
                step = .apiKey(serverURL: serverURL)
            } label: {
                Text("Use API Key instead →")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorAccent)
            }
            Spacer()
        }
    }

    private func signIn() async {
        focused = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let response = try await ImmichAPI.login(
                baseURL: serverURL,
                email: trimmedEmail,
                password: password
            )
            await MainActor.run {
                connectionManager.connect(baseURL: serverURL, token: response.accessToken)
                HapticManager.notification(.success)
            }
        } catch let caught as ImmichError {
            errorMessage = message(for: caught)
            HapticManager.notification(.error)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
                shake += 1
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.notification(.error)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
                shake += 1
            }
        }
    }

    private func message(for error: ImmichError) -> String {
        switch error {
        case .notConfigured: return "Server URL is missing or invalid."
        case .unauthorized: return "Incorrect email or password."
        case .networkError: return "Could not reach the server. Check the URL and your network."
        case .decodingError: return "Server responded but the format wasn't recognized."
        case .serverError(let code): return "Server returned HTTP \(code)."
        }
    }
}

// MARK: - Step 3: API key fallback

private struct APIKeyStep: View {
    @Binding var step: OnboardingView.Step
    let serverURL: String

    @EnvironmentObject private var connectionManager: ConnectionManager

    @State private var urlText: String
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var shake = 0
    @FocusState private var focused: Field?

    private enum Field { case url, apiKey }

    init(step: Binding<OnboardingView.Step>, serverURL: String) {
        self._step = step
        self.serverURL = serverURL
        self._urlText = State(initialValue: serverURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            fields
                .modifier(ShakeEffect(amount: shake))
            connectButton
            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorDanger)
                    .transition(.opacity)
            }
            Spacer()
            HStack {
                Spacer()
                Button {
                    step = .login(serverURL: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text("← Back to sign in")
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorAccent)
                }
                Spacer()
            }
        }
        .padding(Spacing.xl)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                step = .login(serverURL: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityLabel("Back to sign in")

            Text("API key")
                .font(Typography.displayTitle)
                .foregroundStyle(.phosphorPrimary)
            Text("For machine accounts or sharing access.")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
    }

    private var fields: some View {
        VStack(spacing: Spacing.md) {
            TextField("Server URL", text: $urlText)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focused, equals: .url)
                .submitLabel(.next)
                .onSubmit { focused = .apiKey }
                .padding(Spacing.md)
                .frame(minHeight: TapTarget.minimum)
                .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                .foregroundStyle(.phosphorPrimary)

            HStack(spacing: Spacing.sm) {
                Group {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                            .textContentType(.password)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textContentType(.password)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .apiKey)
                .submitLabel(.go)
                .onSubmit { Task { await connect() } }

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.phosphorSecondary)
                }
                .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
            }
            .padding(Spacing.md)
            .frame(minHeight: TapTarget.minimum)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
            .foregroundStyle(.phosphorPrimary)
        }
        .disabled(isSubmitting)
    }

    private var connectButton: some View {
        Button {
            Task { await connect() }
        } label: {
            ZStack {
                Capsule().fill(.phosphorPrimary)
                if isSubmitting {
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
        .disabled(isSubmitting || urlText.isEmpty || apiKey.isEmpty)
    }

    private func connect() async {
        focused = nil
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let probe = try await ImmichAPI.probe(baseURL: trimmedURL, apiKey: trimmedKey)
            guard probe.ok else {
                errorMessage = "Server reachable but didn't respond as expected."
                HapticManager.notification(.error)
                return
            }
            await MainActor.run {
                connectionManager.connect(baseURL: trimmedURL, apiKey: trimmedKey)
                HapticManager.notification(.success)
            }
        } catch let caught as ImmichError {
            errorMessage = message(for: caught)
            HapticManager.notification(.error)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
                shake += 1
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.notification(.error)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
                shake += 1
            }
        }
    }

    private func message(for error: ImmichError) -> String {
        switch error {
        case .notConfigured: return "URL or API key is missing."
        case .unauthorized: return "The API key was rejected by the server."
        case .networkError: return "Could not reach the server. Check the URL."
        case .decodingError: return "Server responded but the format wasn't recognized."
        case .serverError(let code): return "Server returned HTTP \(code)."
        }
    }
}

// MARK: - Shake effect (shared)

struct ShakeEffect: GeometryEffect {
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

// MARK: - mDNS discovery

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: UInt16?

    var displayHost: String {
        if let port { return "\(host):\(port)" }
        return host
    }

    var url: String {
        let scheme = (port == 443 || port == 8443) ? "https" : "http"
        if let port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

@MainActor
final class MDNSDiscovery: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var isScanning = false

    private var browser: NWBrowser?
    private var resolveConnections: [NWConnection] = []
    private var stopTask: Task<Void, Never>?

    func start(duration: TimeInterval) {
        guard !isScanning else { return }
        isScanning = true
        servers = []

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_http._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handle(results: results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await self?.stop()
        }
    }

    func stop() {
        isScanning = false
        browser?.cancel()
        browser = nil
        resolveConnections.forEach { $0.cancel() }
        resolveConnections.removeAll()
        stopTask?.cancel()
        stopTask = nil
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }

            // Match name containing "immich" OR a TXT record entry containing it.
            let nameMatch = name.localizedCaseInsensitiveContains("immich")
            let txtMatch: Bool
            switch result.metadata {
            case .bonjour(let txt):
                txtMatch = txt.dictionary.values.contains {
                    $0.localizedCaseInsensitiveContains("immich")
                } || txt.dictionary.keys.contains {
                    $0.localizedCaseInsensitiveContains("immich")
                }
            default:
                txtMatch = false
            }
            guard nameMatch || txtMatch else { continue }
            guard !servers.contains(where: { $0.id == name }) else { continue }

            // Add a placeholder entry immediately; resolve in the background.
            servers.append(DiscoveredServer(id: name, name: name, host: "\(name).local", port: nil))
            resolve(endpoint: result.endpoint, serviceName: name)
        }
    }

    private func resolve(endpoint: NWEndpoint, serviceName: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolveConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                let resolved = connection.currentPath?.remoteEndpoint
                Task { @MainActor in
                    if let resolved {
                        self.updateResolved(serviceName: serviceName, endpoint: resolved)
                    }
                    connection.cancel()
                }
            } else if case .failed = state {
                Task { @MainActor in connection.cancel() }
            }
        }
        connection.start(queue: .main)
    }

    private func updateResolved(serviceName: String, endpoint: NWEndpoint) {
        var host = serviceName
        var port: UInt16?
        switch endpoint {
        case .hostPort(let h, let p):
            host = h.debugDescription
            port = p.rawValue
        default:
            break
        }
        if let i = servers.firstIndex(where: { $0.id == serviceName }) {
            servers[i] = DiscoveredServer(id: serviceName, name: serviceName, host: host, port: port)
        }
    }
}
