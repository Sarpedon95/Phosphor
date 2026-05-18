import SwiftUI
import Network

/// Lightly normalizes a user-typed address — strips whitespace and trailing
/// slashes only. The connection resolver decides scheme and port from the
/// shape of what's left, so we never force `:2283` onto a remote domain
/// (which is the most common reverse-proxy setup, running on default :443).
func normalizeImmichURL(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
}

/// Heuristic: looks like a LAN-only address (IP, .local, or single-label
/// hostname) where Immich's default :2283 is the likely listening port.
func looksLikeLocalAddress(_ host: String) -> Bool {
    let h = host.lowercased()
    if h.hasSuffix(".local") { return true }
    // Bare IPv4 (e.g. 192.168.1.10) — every segment numeric.
    if h.contains("."),
       h.split(separator: ".").allSatisfy({ Int($0) != nil }) {
        return true
    }
    // Single label, no dots — like "immich" or "homeserver".
    return !h.contains(".")
}

/// First-run / re-auth connection flow, modeled on a friendly home-appliance
/// setup rather than developer tooling: discover → sign in → (API-key
/// fallback). Three full-screen dark steps, no system navigation chrome.
struct OnboardingView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    /// When presented to add an additional server (not first-run), the
    /// wordmark is hidden and a dismiss button replaces the discovery back.
    let isAddingAdditional: Bool

    enum OnboardingStep: Equatable {
        case discovery
        case login(url: String)
        case apiKey(url: String)
    }

    @State private var step: OnboardingStep = .discovery

    init(connectionManager: ConnectionManager, isAddingAdditional: Bool = false) {
        _ = connectionManager   // kept for call-site compatibility
        self.isAddingAdditional = isAddingAdditional
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
        .interactiveDismissDisabled(!isAddingAdditional)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .discovery:
            DiscoveryScreen(
                isAddingAdditional: isAddingAdditional,
                onDismiss: { dismiss() },
                onPick: { address in
                    withAnimation { step = .login(url: address) }
                }
            )
        case .login(let url):
            CredentialsScreen(
                initialAddress: url,
                onBack: { withAnimation { step = .discovery } },
                onUseAPIKey: { resolved in
                    withAnimation { step = .apiKey(url: resolved) }
                }
            )
        case .apiKey(let url):
            APIKeyScreen(
                initialAddress: url,
                onBack: { withAnimation { step = .login(url: url) } }
            )
        }
    }
}

// MARK: - Screen 1: Discovery

private struct DiscoveryScreen: View {
    let isAddingAdditional: Bool
    let onDismiss: () -> Void
    let onPick: (String) -> Void

    @StateObject private var discovery = MDNSDiscovery()
    @State private var manualAddress = ""
    @State private var showQR = false

    var body: some View {
        VStack(spacing: 0) {
            if isAddingAdditional {
                HStack {
                    Spacer()
                    Button("Cancel", action: onDismiss)
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorSecondary)
                }
                .padding(Spacing.md)
            }

            Spacer(minLength: Spacing.lg)

            if !isAddingAdditional {
                VStack(spacing: Spacing.sm) {
                    Text("Phosphor")
                        .font(Typography.wordmark)
                        .foregroundStyle(.phosphorPrimary)
                    Text("Your Immich, beautifully.")
                        .font(Typography.subheadline)
                        .foregroundStyle(.phosphorSecondary)
                }
            }

            Spacer(minLength: Spacing.lg)

            discoveryList
                .frame(maxHeight: 260)

            Spacer(minLength: Spacing.lg)

            manualEntry

            Spacer(minLength: Spacing.md)
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear { discovery.start(duration: 10) }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showQR) {
            QRScannerView { code in
                showQR = false
                if let host = hostFromScanned(code) {
                    onPick(host)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveryList: some View {
        if discovery.servers.isEmpty {
            if discovery.isScanning {
                PulsingSearchRow()
            } else {
                Text("No servers found on your network")
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorTertiary)
            }
        } else {
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(discovery.servers) { server in
                        Button {
                            HapticManager.selection()
                            onPick(server.onboardingAddress)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color.phosphorAccent)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(Typography.body)
                                        .foregroundStyle(.phosphorPrimary)
                                    Text(server.displayHost)
                                        .font(Typography.caption)
                                        .foregroundStyle(.phosphorSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.phosphorTertiary)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(
                                Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            )
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
        VStack(spacing: Spacing.sm) {
            TextField("immich.local, 192.168.1.10, or my.server.com", text: $manualAddress)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.md)
                .frame(minHeight: TapTarget.minimum)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

            VStack(spacing: 2) {
                Text("For remote access, enter your Tailscale hostname or VPN address.")
                Text("Immich runs on port 2283 by default.")
            }
            .font(Typography.footnote)
            .foregroundStyle(.phosphorTertiary)
            .multilineTextAlignment(.center)

            Button {
                let trimmed = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                HapticManager.selection()
                onPick(normalizeImmichURL(trimmed))
            } label: {
                Text("Connect →")
                    .font(Typography.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.phosphorAccent, in: Capsule())
            }
            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            Button {
                showQR = true
            } label: {
                Text("Scan QR code from Immich web")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            .padding(.top, Spacing.xs)
        }
    }

    private func hostFromScanned(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return trimmed
    }
}

private struct PulsingSearchRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(Color.phosphorSecondary)
                .frame(width: 8, height: 8)
            Text("Searching your network…")
                .font(.system(size: 13))
                .foregroundStyle(.phosphorSecondary)
        }
        .opacity(pulse ? 1.0 : 0.4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel("Searching your network for Immich servers")
    }
}

// MARK: - Screen 2: Credentials

private struct CredentialsScreen: View {
    let initialAddress: String
    let onBack: () -> Void
    let onUseAPIKey: (String) -> Void

    @EnvironmentObject private var connectionManager: ConnectionManager

    @State private var host: String
    @State private var portText: String
    @State private var useHTTPS: Bool
    /// True once the user actually flips the HTTPS toggle or types into the
    /// port field. Until then the address stays exactly as they typed it on
    /// Screen 1, so the resolver does autodetection.
    @State private var userOverrodeAddress = false
    @State private var allowSelfSigned = false
    @State private var showConnectionSettings = false

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var shake = 0
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    init(initialAddress: String, onBack: @escaping () -> Void, onUseAPIKey: @escaping (String) -> Void) {
        self.initialAddress = initialAddress
        self.onBack = onBack
        self.onUseAPIKey = onUseAPIKey
        let parsed = Self.parse(initialAddress)
        _host = State(initialValue: parsed.host)
        // Only pre-fill the port if the user actually typed one — public
        // domains usually answer on the default 443, not Immich's :2283.
        _portText = State(initialValue: parsed.port ?? "")
        // HTTPS toggle reflects what the user typed: on for https://, off
        // for http://, otherwise on by default (most modern setups).
        _useHTTPS = State(initialValue: parsed.scheme ?? true)
    }

    /// Address sent to the resolver. If the user hasn't touched the
    /// connection-settings controls, this is verbatim what they typed on
    /// Screen 1, letting the resolver autodetect scheme/port. Once they
    /// edit a control we honor it.
    private var effectiveURL: String {
        if !userOverrodeAddress { return initialAddress }
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        let hostPort = trimmedPort.isEmpty ? host : "\(host):\(trimmedPort)"
        return "\(useHTTPS ? "https" : "http")://\(hostPort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            backButton

            Text("Sign in")
                .font(Typography.wordmark)
                .foregroundStyle(.phosphorPrimary)

            serverPill

            fields
                .modifier(ShakeEffect(amount: shake))

            signInButton

            if let progressMessage {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.phosphorSecondary)
                    Text(progressMessage)
                        .font(Typography.footnote)
                        .foregroundStyle(.phosphorSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorError)
                    .multilineTextAlignment(.leading)
                    .transition(.opacity)
            }

            orDivider
            apiKeyButton
            connectionSettings

            Spacer()
        }
        .padding(Spacing.xl)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.phosphorAccent)
        }
        .accessibilityLabel("Back to server discovery")
    }

    private var serverPill: some View {
        Button(action: onBack) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "server.rack")
                    .font(.system(size: 11))
                    .foregroundStyle(.phosphorTertiary)
                Text(effectiveURL)
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .accessibilityLabel("Server \(effectiveURL). Tap to change.")
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
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.md)
                .frame(minHeight: TapTarget.minimum)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.05))
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
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
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
    }

    private var orDivider: some View {
        HStack(spacing: Spacing.md) {
            Rectangle().fill(Color.phosphorSeparator).frame(height: 1)
            Text("or")
                .font(Typography.caption)
                .foregroundStyle(.phosphorTertiary)
            Rectangle().fill(Color.phosphorSeparator).frame(height: 1)
        }
    }

    private var apiKeyButton: some View {
        HStack {
            Spacer()
            Button {
                onUseAPIKey(effectiveURL)
            } label: {
                Text("Use API Key")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorSecondary)
            }
            Spacer()
        }
    }

    private var connectionSettings: some View {
        DisclosureGroup(isExpanded: $showConnectionSettings) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .tint(.phosphorAccent)
                Text("Most home setups don't need this.")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorTertiary)

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
                        .onChange(of: portText) { _, _ in userOverrodeAddress = true }
                }
                Text("Leave blank for default (Immich :2283 on LAN, :443 with HTTPS).")
                    .font(Typography.caption)
                    .foregroundStyle(.phosphorTertiary)

                Toggle("Use HTTPS", isOn: $useHTTPS)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorPrimary)
                    .tint(.phosphorAccent)
                    .onChange(of: useHTTPS) { _, _ in userOverrodeAddress = true }
            }
            .padding(.top, Spacing.sm)
        } label: {
            Text("Connection settings")
                .font(Typography.caption)
                .foregroundStyle(.phosphorSecondary)
        }
        .tint(.phosphorSecondary)
    }

    // MARK: Actions

    private func signIn() async {
        focused = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        let address = effectiveURL
        isSubmitting = true
        errorMessage = nil
        withAnimation { progressMessage = "Finding \(address)…" }
        persistSelfSigned()
        defer { isSubmitting = false; progressMessage = nil }

        // Resolve first so the user sees what URL actually answered before we
        // try to authenticate — and so a wrong address fails fast (8s probe).
        guard let resolved = await ImmichAPI.resolveConnection(address: address) else {
            present(.networkError(URLError(.cannotConnectToHost)))
            return
        }
        await MainActor.run {
            withAnimation { progressMessage = "Signing in at \(resolved.baseURL)…" }
        }

        do {
            let auth = try await ImmichAPI.login(
                baseURL: resolved.baseURL,
                prefix: resolved.prefix,
                email: trimmedEmail,
                password: password
            )
            await MainActor.run {
                connectionManager.connect(
                    baseURL: resolved.baseURL,
                    token: auth.accessToken,
                    prefix: resolved.prefix
                )
                HapticManager.notification(.success)
            }
        } catch let caught as ImmichError {
            present(caught)
        } catch {
            present(.networkError(error))
        }
    }

    /// Store the per-host self-signed preference BEFORE the probe runs, so the
    /// URLSession delegate can read it during the TLS challenge.
    private func persistSelfSigned() {
        KeychainManager.set(
            allowSelfSigned ? "1" : "0",
            forKey: immichSelfSignedKey(forHost: host)
        )
    }

    private func present(_ error: ImmichError) {
        switch error {
        case .unauthorized:
            errorMessage = "Wrong email or password."
        case .networkError:
            errorMessage = "Couldn't reach \(effectiveURL). If it's a remote domain, double-check the address. If it uses a self-signed cert, enable it in Connection settings."
        case .notConfigured:
            errorMessage = "That address doesn't look right."
        case .decodingError:
            errorMessage = "Reached \(effectiveURL) but it didn't respond like Immich. Is the port right?"
        case .serverError(let code):
            errorMessage = "Server returned HTTP \(code) at \(effectiveURL)."
        }
        HapticManager.notification(.error)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) { shake += 1 }
    }

    /// Splits a user-typed address into (host, optional explicit port,
    /// optional explicit scheme). Returning nil for port/scheme when absent
    /// is the signal to the UI: leave that control empty, don't make one up.
    private static func parse(_ address: String) -> (host: String, port: String?, scheme: Bool?) {
        let scheme: Bool? = {
            if address.hasPrefix("https://") { return true }
            if address.hasPrefix("http://")  { return false }
            return nil
        }()
        var s = address
        if s.hasPrefix("https://") { s.removeFirst(8) }
        else if s.hasPrefix("http://") { s.removeFirst(7) }
        while s.hasSuffix("/") { s.removeLast() }
        if let colon = s.lastIndex(of: ":"),
           !s[s.index(after: colon)...].isEmpty,
           s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            return (String(s[..<colon]), String(s[s.index(after: colon)...]), scheme)
        }
        return (s, nil, scheme)
    }
}

// MARK: - Screen 3: API key fallback

private struct APIKeyScreen: View {
    let initialAddress: String
    let onBack: () -> Void

    @EnvironmentObject private var connectionManager: ConnectionManager

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var shake = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.phosphorAccent)
            }
            .accessibilityLabel("Back to sign in")

            Text("API Key")
                .font(Typography.headline)
                .foregroundStyle(.phosphorPrimary)

            HStack(spacing: Spacing.xs) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                Text("Find your API key in Immich web → Account Settings → API Keys.")
            }
            .font(Typography.caption)
            .foregroundStyle(.phosphorSecondary)

            HStack(spacing: Spacing.sm) {
                Group {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
            .foregroundStyle(.phosphorPrimary)
            .padding(Spacing.md)
            .frame(minHeight: TapTarget.minimum)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .modifier(ShakeEffect(amount: shake))

            Button {
                Task { await connect() }
            } label: {
                ZStack {
                    Capsule().fill(Color.phosphorAccent)
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
            .disabled(isSubmitting || apiKey.isEmpty)

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.footnote)
                    .foregroundStyle(.phosphorError)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding(Spacing.xl)
    }

    private func connect() async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await ImmichAPI.connectWithAPIKey(
                address: initialAddress,
                apiKey: trimmedKey
            )
            await MainActor.run {
                connectionManager.connect(
                    baseURL: result.baseURL,
                    apiKey: trimmedKey,
                    prefix: result.prefix
                )
                HapticManager.notification(.success)
            }
        } catch let caught as ImmichError {
            present(caught)
        } catch {
            present(.networkError(error))
        }
    }

    private func present(_ error: ImmichError) {
        switch error {
        case .unauthorized:
            errorMessage = "That API key was rejected"
        case .networkError:
            errorMessage = "Could not reach server — check the address"
        case .notConfigured:
            errorMessage = "That address doesn't look right"
        case .decodingError:
            errorMessage = "The server responded unexpectedly"
        case .serverError(let code):
            errorMessage = "Server error (HTTP \(code))"
        }
        HapticManager.notification(.error)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) { shake += 1 }
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

    /// What we hand to the credentials screen — bare host[:port] with no
    /// scheme, so the resolver can try https then http.
    var onboardingAddress: String {
        if let port { return "\(host):\(port)" }
        return "\(host):2283"
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

            // Match a service name containing "immich" OR a TXT record where
            // key "app" == "immich" (or any entry mentioning immich).
            let nameMatch = name.localizedCaseInsensitiveContains("immich")
            var txtMatch = false
            if case let .bonjour(txt) = result.metadata {
                txtMatch = txt.contains { element in
                    if element.key.lowercased() == "app",
                       case let .string(v) = element.value,
                       v.localizedCaseInsensitiveContains("immich") {
                        return true
                    }
                    if element.key.localizedCaseInsensitiveContains("immich") {
                        return true
                    }
                    if case let .string(v) = element.value,
                       v.localizedCaseInsensitiveContains("immich") {
                        return true
                    }
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
