import SwiftUI
import Network

/// Five-step onboarding modeled on LyrPlay's flow, adapted for Immich:
///   Welcome → Server Setup → Connection Test → Sign In → Setup Complete.
///
/// No API-key option in this flow — sign-in is email+password only. The
/// multi-profile screen (AddServerView) still accepts API keys for sharing
/// a token-less profile, but the first-launch wall does not.
struct OnboardingView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    let isAddingAdditional: Bool

    enum Step: Int, CaseIterable {
        case welcome, serverSetup, connectionTest, signIn, complete

        var title: String {
            switch self {
            case .welcome:        return "Welcome"
            case .serverSetup:    return "Server"
            case .connectionTest: return "Testing connection"
            case .signIn:         return "Sign in"
            case .complete:       return "All set"
            }
        }
    }

    /// State machine — passed to children so each step can move forward or
    /// back without each knowing the others.
    @State private var step: Step = .welcome
    /// Address the user typed/picked, normalized but not scheme-forced.
    @State private var address: String = ""
    /// Filled by the test step on success; consumed by the sign-in step.
    @State private var resolvedBaseURL: String = ""
    @State private var resolvedPrefix: String = ""
    @State private var allowSelfSignedHost: String?

    init(connectionManager: ConnectionManager, isAddingAdditional: Bool = false) {
        _ = connectionManager
        self.isAddingAdditional = isAddingAdditional
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                progressBar
                    .padding(.top, isAddingAdditional ? Spacing.sm : Spacing.lg)
                content
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            if isAddingAdditional {
                VStack {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .font(Typography.subheadline)
                            .foregroundStyle(.phosphorSecondary)
                            .padding(Spacing.md)
                    }
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!isAddingAdditional)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    private var progressBar: some View {
        VStack(spacing: Spacing.xs) {
            Text(step.title)
                .font(Typography.captionBold)
                .foregroundStyle(.phosphorSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Color.phosphorAccent)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, Spacing.lg)
    }

    private var fraction: CGFloat {
        let total = max(1, Step.allCases.count - 1)
        return CGFloat(step.rawValue) / CGFloat(total)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep(onNext: { advance(to: .serverSetup) })
        case .serverSetup:
            ServerSetupStep(
                address: $address,
                allowSelfSignedHost: $allowSelfSignedHost,
                onBack: { advance(to: .welcome) },
                onNext: { advance(to: .connectionTest) }
            )
        case .connectionTest:
            ConnectionTestStep(
                address: address,
                onBack: { advance(to: .serverSetup) },
                onSuccess: { base, prefix in
                    resolvedBaseURL = base
                    resolvedPrefix = prefix
                    advance(to: .signIn)
                }
            )
        case .signIn:
            SignInStep(
                baseURL: resolvedBaseURL,
                prefix: resolvedPrefix,
                onBack: { advance(to: .connectionTest) },
                onSuccess: { token in
                    connectionManager.connect(
                        baseURL: resolvedBaseURL,
                        token: token,
                        prefix: resolvedPrefix
                    )
                    advance(to: .complete)
                }
            )
        case .complete:
            CompleteStep(
                baseURL: resolvedBaseURL,
                onFinish: {
                    if isAddingAdditional { dismiss() }
                    // First-run case: ContentView's fullScreenCover dismisses
                    // automatically the moment isConfigured flips to true.
                }
            )
        }
    }

    private func advance(to next: Step) {
        withAnimation { step = next }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void
    @State private var iconScale: CGFloat = 1

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.phosphorPrimary)
                .scaleEffect(iconScale)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        iconScale = 1.05
                    }
                }
            VStack(spacing: Spacing.sm) {
                Text("Phosphor")
                    .font(Typography.wordmark)
                    .foregroundStyle(.phosphorPrimary)
                Text("A beautiful client for your Immich server.")
                    .font(Typography.body)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
            }
            VStack(spacing: Spacing.lg) {
                OnboardingFeatureRow(icon: "rectangle.stack",
                                     title: "Browse your library",
                                     subtitle: "Albums, memories, search")
                OnboardingFeatureRow(icon: "icloud.and.arrow.up",
                                     title: "Back up automatically",
                                     subtitle: "Camera roll to your server")
                OnboardingFeatureRow(icon: "lock.shield",
                                     title: "Self-hosted, private",
                                     subtitle: "Works over Tailscale & VPN")
            }
            .padding(.horizontal, Spacing.lg)
            Spacer()
            PrimaryActionButton(title: "Get Started", action: onNext)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
        }
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.phosphorAccent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            Spacer()
        }
    }
}

// MARK: - Step 2: Server Setup

private struct ServerSetupStep: View {
    @Binding var address: String
    @Binding var allowSelfSignedHost: String?
    let onBack: () -> Void
    let onNext: () -> Void

    @StateObject private var discovery = MDNSDiscovery()
    @State private var portText = ""
    @State private var useHTTPS = true
    @State private var allowSelfSigned = false
    @State private var showAdvanced = false
    @State private var didAutoStart = false
    @State private var showQR = false

    private let commonHosts = ["immich.local", "192.168.1.10", "192.168.0.10"]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                discoveryHeader
                if !discovery.servers.isEmpty {
                    discoveryGrid
                }
                addressBlock
                commonHostsBlock
                advancedDisclosure
                Spacer(minLength: Spacing.md)
                bottomBar
            }
            .padding(Spacing.lg)
        }
        .onAppear {
            guard !didAutoStart else { return }
            didAutoStart = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                discovery.start(duration: 10)
            }
        }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showQR) {
            QRScannerView { scanned in
                showQR = false
                if let normalized = parseScanned(scanned) {
                    address = normalized
                }
            }
        }
    }

    private var discoveryHeader: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: discovery.isScanning ? "antenna.radiowaves.left.and.right" : "magnifyingglass")
                    .foregroundStyle(.phosphorAccent)
                Text(discovery.isScanning ? "Searching your network…" : "Search for servers")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                Spacer()
                if discovery.isScanning {
                    ProgressView().controlSize(.small).tint(.phosphorAccent)
                }
            }
            if discovery.servers.isEmpty && !discovery.isScanning {
                HStack {
                    Text("Nothing nearby — try the manual address below.")
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorTertiary)
                    Spacer()
                    Button("Search again") { discovery.start(duration: 10) }
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }

    private var discoveryGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Discovered")
                .font(Typography.captionBold)
                .foregroundStyle(.phosphorSecondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.sm) {
                ForEach(discovery.servers) { server in
                    Button {
                        HapticManager.selection()
                        address = server.suggestedAddress
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .font(Typography.subheadline)
                                .foregroundStyle(.phosphorPrimary)
                                .lineLimit(1)
                            Text(server.displayHost)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(
                            Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Server address")
                .font(Typography.captionBold)
                .foregroundStyle(.phosphorSecondary)
            HStack(spacing: Spacing.sm) {
                TextField("photos.example.com or 192.168.1.10", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.phosphorPrimary)
                    .padding(Spacing.md)
                    .frame(minHeight: TapTarget.minimum)
                    .background(
                        Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    )
                Button {
                    showQR = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(.phosphorSecondary)
                        .frame(width: 44, height: 44)
                        .background(
                            Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        )
                }
                .accessibilityLabel("Scan QR code")
            }
            Text("Local IP, .local hostname, Tailscale name, or a public domain — all fine.")
                .font(Typography.footnote)
                .foregroundStyle(.phosphorTertiary)
        }
    }

    private var commonHostsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Common addresses")
                .font(Typography.captionBold)
                .foregroundStyle(.phosphorSecondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.sm) {
                ForEach(commonHosts, id: \.self) { host in
                    Button(host) { address = host }
                        .buttonStyle(SuggestionChipStyle())
                }
            }
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Toggle("Use HTTPS", isOn: $useHTTPS)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .tint(.phosphorAccent)

                HStack {
                    Text("Port")
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorPrimary)
                    Spacer()
                    TextField("Auto", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .foregroundStyle(.phosphorPrimary)
                }

                Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .tint(.phosphorAccent)
                Text("Most home setups don't need this.")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorTertiary)
            }
            .padding(.top, Spacing.sm)
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.phosphorSecondary)
                Text("Connection settings")
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
            }
        }
        .padding(Spacing.md)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
        .tint(.phosphorSecondary)
    }

    private var bottomBar: some View {
        HStack(spacing: Spacing.md) {
            SecondaryActionButton(title: "Back", action: onBack)
            PrimaryActionButton(title: "Test Connection") {
                applyAdvancedToAddress()
                onNext()
            }
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(address.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.top, Spacing.sm)
    }

    /// Folds the Connection-settings overrides back into the address string
    /// the user typed. Only does so when the user has actually touched a
    /// control or expanded the section — otherwise the resolver autodetects.
    private func applyAdvancedToAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showAdvanced else { address = trimmed; return }
        // Strip any existing scheme & trailing slash.
        var s = trimmed
        if s.hasPrefix("https://") { s.removeFirst(8) }
        else if s.hasPrefix("http://") { s.removeFirst(7) }
        while s.hasSuffix("/") { s.removeLast() }
        let scheme = useHTTPS ? "https" : "http"
        let port = portText.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty, !s.contains(":") {
            s = "\(s):\(port)"
        }
        address = "\(scheme)://\(s)"

        // Persist the self-signed preference for the resolved host so the
        // TLS delegate can read it during the test handshake.
        if let host = hostOnly(in: s) {
            KeychainManager.set(allowSelfSigned ? "1" : "0",
                                forKey: immichSelfSignedKey(forHost: host))
            allowSelfSignedHost = host
        }
    }

    private func hostOnly(in s: String) -> String? {
        var h = s
        if h.hasPrefix("https://") { h.removeFirst(8) }
        else if h.hasPrefix("http://") { h.removeFirst(7) }
        while h.hasSuffix("/") { h.removeLast() }
        if let colon = h.lastIndex(of: ":"),
           h[h.index(after: colon)...].allSatisfy(\.isNumber) {
            h = String(h[..<colon])
        }
        return h.isEmpty ? nil : h
    }

    private func parseScanned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return trimmed
    }
}

// MARK: - Step 3: Connection Test

private struct ConnectionTestStep: View {
    let address: String
    let onBack: () -> Void
    let onSuccess: (_ baseURL: String, _ prefix: String) -> Void

    @State private var steps: [ImmichAPI.ConnectionTestStep] = ImmichAPI.makeConnectionTestSteps()
    @State private var phase: Phase = .running
    @State private var resolved: ImmichAPI.ResolvedConnection?

    private enum Phase { case running, success, failure }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.sm) {
                Text("Testing connection")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                Text(address)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .padding(.top, Spacing.lg)

            VStack(spacing: Spacing.sm) {
                ForEach(steps) { TestRow(step: $0) }
            }
            .padding(Spacing.md)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
            .padding(.horizontal, Spacing.lg)

            Spacer()

            outcome

            Spacer(minLength: 0)
        }
        .padding(.bottom, Spacing.lg)
        .task(id: address) { await run() }
    }

    @ViewBuilder
    private var outcome: some View {
        switch phase {
        case .running:
            VStack(spacing: Spacing.sm) {
                ProgressView().tint(.phosphorAccent)
                Text("Reaching your server…")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
        case .success:
            VStack(spacing: Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.phosphorSuccess)
                Text("Connected")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                PrimaryActionButton(title: "Continue") {
                    if let resolved {
                        onSuccess(resolved.baseURL, resolved.prefix)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
        case .failure:
            VStack(spacing: Spacing.md) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.phosphorError)
                Text("Couldn't connect")
                    .font(Typography.headline)
                    .foregroundStyle(.phosphorPrimary)
                Text(failureHint)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
                HStack(spacing: Spacing.md) {
                    SecondaryActionButton(title: "Try again") { Task { await run() } }
                    PrimaryActionButton(title: "Change", action: onBack)
                }
                .padding(.horizontal, Spacing.lg)
            }
        }
    }

    private var failureHint: String {
        for s in steps {
            if case .failure(let msg) = s.status { return msg }
        }
        return "Check the address, port, and HTTPS setting in Connection settings."
    }

    private func run() async {
        phase = .running
        steps = ImmichAPI.makeConnectionTestSteps()
        let result = await ImmichAPI.runConnectionTest(address: address) { snapshot in
            self.steps = snapshot
        }
        if let result {
            resolved = result
            phase = .success
            HapticManager.notification(.success)
        } else {
            resolved = nil
            phase = .failure
            HapticManager.notification(.error)
        }
    }
}

private struct TestRow: View {
    let step: ImmichAPI.ConnectionTestStep

    var body: some View {
        HStack(spacing: Spacing.md) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                if let detail {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(.phosphorSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.status {
        case .pending:
            Circle()
                .strokeBorder(Color.phosphorTertiary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        case .running:
            ProgressView().controlSize(.small).tint(.phosphorAccent)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.phosphorSuccess)
                .font(.system(size: 20))
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.phosphorError)
                .font(.system(size: 20))
        }
    }

    private var detail: String? {
        switch step.status {
        case .pending: return nil
        case .running: return "Testing…"
        case .success(let msg), .failure(let msg): return msg
        }
    }
}

// MARK: - Step 4: Sign In

private struct SignInStep: View {
    let baseURL: String
    let prefix: String
    let onBack: () -> Void
    let onSuccess: (_ token: String) -> Void

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
            HStack(spacing: Spacing.xs) {
                Image(systemName: "server.rack")
                    .font(.system(size: 11))
                    .foregroundStyle(.phosphorTertiary)
                Text(baseURL)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Color.white.opacity(0.08), in: Capsule())

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Sign in to your server")
                    .font(Typography.title2)
                    .foregroundStyle(.phosphorPrimary)
                Text("Use your Immich email and password.")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }

            VStack(spacing: Spacing.md) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    .foregroundStyle(.phosphorPrimary)
                    .padding(Spacing.md)
                    .frame(minHeight: TapTarget.minimum)
                    .background(
                        Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    )

                HStack(spacing: Spacing.sm) {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(.password)
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
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.md)
                .frame(minHeight: TapTarget.minimum)
                .background(
                    Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                )
            }
            .modifier(ShakeEffect(amount: shake))

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorError)
                    .transition(.opacity)
            }

            Spacer()

            HStack(spacing: Spacing.md) {
                SecondaryActionButton(title: "Back", action: onBack)
                Button(action: { Task { await signIn() } }) {
                    ZStack {
                        Capsule().fill(Color.phosphorAccent)
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
                .opacity((isSubmitting || email.isEmpty || password.isEmpty) ? 0.6 : 1)
            }
        }
        .padding(Spacing.lg)
    }

    private func signIn() async {
        focused = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let auth = try await ImmichAPI.login(
                baseURL: baseURL, prefix: prefix,
                email: trimmed, password: password
            )
            HapticManager.notification(.success)
            onSuccess(auth.accessToken)
        } catch let caught as ImmichError {
            present(caught)
        } catch {
            present(.networkError(error))
        }
    }

    private func present(_ error: ImmichError) {
        switch error {
        case .unauthorized: errorMessage = "Wrong email or password."
        case .networkError: errorMessage = "Lost connection to the server. Try again."
        case .notConfigured: errorMessage = "Server is missing required configuration."
        case .decodingError: errorMessage = "Got an unexpected response from the server."
        case .serverError(let code): errorMessage = "Server returned HTTP \(code)."
        }
        HapticManager.notification(.error)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) { shake += 1 }
    }
}

// MARK: - Step 5: Complete

private struct CompleteStep: View {
    let baseURL: String
    let onFinish: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(.phosphorSuccess)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .onAppear {
                    HapticManager.notification(.success)
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            VStack(spacing: Spacing.sm) {
                Text("You're all set")
                    .font(Typography.title2)
                    .foregroundStyle(.phosphorPrimary)
                Text("Connected to \(baseURL)")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
            }
            Spacer()
            PrimaryActionButton(title: "Open Library", action: onFinish)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
        }
    }
}

// MARK: - Shared UI

private struct PrimaryActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.phosphorAccent, in: Capsule())
        }
    }
}

private struct SecondaryActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white.opacity(0.10), in: Capsule())
        }
    }
}

private struct SuggestionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.subheadline)
            .foregroundStyle(.phosphorPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
            )
    }
}

// MARK: - Shake effect

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

    /// Bare host[:port] handed to the resolver — scheme-less so it can try
    /// https → http automatically.
    var suggestedAddress: String {
        if let port { return "\(host):\(port)" }
        return host
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
        stop()
        isScanning = true
        servers = []

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_http._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in self.handle(results: results) }
        }
        browser.start(queue: .main)
        self.browser = browser

        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.stop()
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
            let nameMatch = name.localizedCaseInsensitiveContains("immich")
            var txtMatch = false
            if case let .bonjour(txt) = result.metadata {
                txtMatch = txt.contains { element in
                    if element.key.lowercased() == "app",
                       case let .string(v) = element.value,
                       v.localizedCaseInsensitiveContains("immich") { return true }
                    if element.key.localizedCaseInsensitiveContains("immich") { return true }
                    if case let .string(v) = element.value,
                       v.localizedCaseInsensitiveContains("immich") { return true }
                    return false
                }
            }
            guard nameMatch || txtMatch else { continue }
            guard !servers.contains(where: { $0.id == name }) else { continue }
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
        if case let .hostPort(h, p) = endpoint {
            host = h.debugDescription
            port = p.rawValue
        }
        if let i = servers.firstIndex(where: { $0.id == serviceName }) {
            servers[i] = DiscoveredServer(id: serviceName, name: serviceName, host: host, port: port)
        }
    }
}
