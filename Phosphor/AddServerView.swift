import SwiftUI

struct AddServerView: View {
    @EnvironmentObject private var profiles: ServerProfilesManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var isTesting = false
    @State private var testResult: ConnectionResult?

    /// Save is only enabled after a successful probe — guarantees we never
    /// persist a broken profile.
    private var canSave: Bool {
        if case .success = testResult, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Spacing.md) {
                        nameField
                        urlField
                        keyField
                        testButton
                        if let result = testResult { resultRow(result) }
                        Spacer(minLength: Spacing.xl)
                    }
                    .padding(Spacing.md)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .foregroundStyle(canSave ? .phosphorAccent : .phosphorSecondary)
                        .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Name").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            TextField("Home", text: $name)
                .padding(Spacing.sm)
                .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
                .foregroundStyle(.phosphorAccent)
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Server URL").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            TextField("https://photos.example.com", text: $serverURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(Spacing.sm)
                .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
                .foregroundStyle(.phosphorAccent)
                .onChange(of: serverURL) { _, _ in testResult = nil }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("API Key").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            HStack {
                apiKeyInput
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.phosphorSecondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
            }
            .padding(Spacing.sm)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
            .foregroundStyle(.phosphorAccent)
            .onChange(of: apiKey) { _, _ in testResult = nil }
        }
    }

    @ViewBuilder
    private var apiKeyInput: some View {
        if showAPIKey {
            TextField("Paste API key", text: $apiKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            SecureField("Paste API key", text: $apiKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var testButton: some View {
        Button {
            Task { await test() }
        } label: {
            HStack {
                if isTesting {
                    ProgressView().controlSize(.small).tint(.black)
                    Text("Testing…")
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Test Connection")
                }
            }
            .font(Typography.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(Color.phosphorAccent, in: Capsule())
        }
        .disabled(isTesting || serverURL.isEmpty || apiKey.isEmpty)
    }

    @ViewBuilder
    private func resultRow(_ result: ConnectionResult) -> some View {
        switch result {
        case .success(let version, let latency):
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.phosphorSuccess)
                Text("Connected · v\(version) · \(latency)ms")
                    .foregroundStyle(.phosphorAccent)
            }
            .font(Typography.subheadline)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
        case .failure(let message):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.phosphorDestructive)
                Text(message).foregroundStyle(.phosphorAccent)
            }
            .font(Typography.subheadline)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
        }
    }

    // MARK: - Actions

    private func test() async {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            let probe = try await ImmichAPI.probe(baseURL: trimmedURL, apiKey: trimmedKey)
            if probe.ok {
                testResult = .success(version: probe.version ?? "unknown", latencyMs: probe.latencyMs)
                HapticManager.notification(.success)
            } else {
                testResult = .failure("Server reachable but didn't respond as expected.")
                HapticManager.notification(.error)
            }
        } catch let caught as ImmichError {
            testResult = .failure(message(for: caught))
            HapticManager.notification(.error)
        } catch {
            testResult = .failure(error.localizedDescription)
            HapticManager.notification(.error)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !trimmedName.isEmpty, !trimmedURL.isEmpty, !trimmedKey.isEmpty else { return }
        profiles.addProfile(name: trimmedName, baseURL: trimmedURL, apiKey: trimmedKey)
        HapticManager.notification(.success)
        dismiss()
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
