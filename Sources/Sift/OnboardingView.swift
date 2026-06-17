import SwiftUI
import AppKit

/// First-launch wizard. Captures the LLM API key (BYOK) and connects Slack
/// via OAuth or manual token paste.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @StateObject private var oauth = OAuthCoordinator.shared

    @State private var llmKey: String = ""
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    // Slack: manual token entry
    @State private var showManualToken = false
    @State private var manualToken: String = ""
    @State private var resolvingToken = false

    private var slackConnected: Bool {
        !settings.slackUserID.isEmpty && Keychain.read(SecretKey.slack) != nil
    }

    private var llmSaved: Bool { settings.fastProvider.isConnected() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up Sift")
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(.secondary)

            llmStep
            slackStep

            Spacer(minLength: 0)

            if let err = errorMessage {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            if let err = state.lastError, !err.isEmpty {
                Text(err).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") {
                    state.refreshConfigured()
                    if state.hasConfigured { state.startScheduler(kickNow: true) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(llmSaved && slackConnected))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - LLM step

    @ViewBuilder
    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stepDot(filled: llmSaved)
                Text("AI model").font(.subheadline.weight(.semibold))
                if llmSaved {
                    Text("Saved").font(.caption).foregroundStyle(.green)
                }
            }
            Text("Used for classifying messages and writing summaries. Add more and fine-tune which model does what in Settings. Stored in your macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Provider", selection: $settings.fastProvider) {
                ForEach(LLMProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.fastProvider) { _, newValue in
                // Onboarding uses one provider for both tiers; refine later.
                settings.smartProvider = newValue
                settings.fastModel = newValue.defaultFastModel
                settings.smartModel = newValue.defaultSmartModel
            }

            if settings.fastProvider.needsAPIKey {
                HStack(spacing: 8) {
                    SecureField(settings.fastProvider.keyPlaceholder, text: $llmKey)
                        .textFieldStyle(.roundedBorder)
                    Button(llmSaved ? "Replace" : "Save") {
                        guard !llmKey.isEmpty else { return }
                        Keychain.write(
                            llmKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: settings.fastProvider.keychainKey
                        )
                        llmKey = ""
                        state.refreshConfigured()
                    }
                    .disabled(llmKey.isEmpty)
                }
            } else {
                Text("Ollama runs locally — no API key needed. Make sure it's running on localhost:11434.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Slack step

    @ViewBuilder
    private var slackStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stepDot(filled: slackConnected)
                Text("Slack").font(.subheadline.weight(.semibold))
                if slackConnected {
                    Text("Connected to \(settings.slackHandle.isEmpty ? settings.slackUserID : "@\(settings.slackHandle)")")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Text("Sift reads your @mentions, DMs, and channels you watch.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(slackConnected ? "Reconnect Slack" : "Connect Slack") {
                    errorMessage = nil
                    oauth.start()
                }
                if oauth.inProgress {
                    HStack(spacing: 6) {
                        SiftSpinner()
                        Text("Waiting for browser…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { oauth.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            Button(showManualToken ? "Hide manual entry" : "Or paste a token manually") {
                showManualToken.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            if showManualToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste a Slack user token (xoxp-…). Create one in your workspace's Slack app admin with these read-only scopes: search:read, channels:read, channels:history, groups:read, groups:history, im:read, im:history, mpim:read, mpim:history, users:read, users:read.email.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField("xoxp-…", text: $manualToken)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            let trimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            resolveManualToken(trimmed)
                        }
                        .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvingToken)
                        if resolvingToken {
                            SiftSpinner()
                        }
                    }
                }
            }
        }
    }

    private func resolveManualToken(_ token: String) {
        resolvingToken = true
        errorMessage = nil
        Task {
            do {
                let client = SlackClient(token: token)
                let auth = try await client.authTest()
                let profile = try await client.userProfile(userID: auth.userID)

                await MainActor.run {
                    Keychain.write(token, for: SecretKey.slack)
                    settings.slackUserID = auth.userID
                    settings.slackHandle = auth.userName
                    settings.slackTeamID = auth.teamID
                    if !profile.displayName.isEmpty { settings.displayName = profile.displayName }
                    if !profile.email.isEmpty { settings.email = profile.email }
                    manualToken = ""
                    showManualToken = false
                    resolvingToken = false
                    state.refreshConfigured()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Token validation failed: \(error.localizedDescription)"
                    resolvingToken = false
                }
            }
        }
    }

    @ViewBuilder
    private func stepDot(filled: Bool) -> some View {
        Image(systemName: filled ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(filled ? Color.green : Color.secondary)
    }
}
