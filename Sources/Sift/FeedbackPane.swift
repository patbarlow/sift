import SwiftUI

/// Send-feedback form. POSTs only the message + the user's email and app/OS
/// version to a first-party endpoint — no Slack data, todos, or credentials.
/// Mirrors the pattern used in the other apps that share this endpoint.
struct FeedbackPane: View {
    @EnvironmentObject var settings: AppSettings

    @State private var message = ""
    @State private var state: SubmitState = .idle

    private enum SubmitState: Equatable { case idle, submitting, success, error(String) }

    private static let endpoint = URL(string: "https://speaking.computer/feedback")!

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .submitting
    }

    var body: some View {
        VStack(spacing: 16) {
            if state == .success {
                SettingsCard {
                    VStack(spacing: 10) {
                        LucideIcon(sf: "checkmark.circle", size: 40)
                            .foregroundStyle(InProgressBadge.adaptiveGreen)
                        Text("Thanks for the feedback!").font(.headline)
                        Text("It goes straight to the developer — appreciate you taking the time.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            } else {
                SettingsCard(
                    title: "Send feedback",
                    subtitle: "Bugs, ideas, anything. Only your message and app version are sent — never your Slack data or todos."
                ) {
                    TextEditor(text: $message)
                        .font(.system(size: 13))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .disabled(state == .submitting)

                    if case .error(let msg) = state {
                        Text(msg).font(.callout).foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        SiftButton(variant: .primary, enabled: canSend, action: { Task { await submit() } }) {
                            HStack(spacing: 6) {
                                if state == .submitting {
                                    SiftSpinner(dot: 2.4, spacing: 2, color: .white)
                                }
                                Text(state == .submitting ? "Sending…" : "Send feedback")
                            }
                        }
                    }
                }
            }
        }
    }

    private func submit() async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .submitting

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let body: [String: String] = [
            "message": trimmed,
            "email": settings.email,
            "app": "Sift",
            "version": version,
        ]

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                state = .success
            } else {
                state = .error("Something went wrong. Please try again.")
            }
        } catch {
            state = .error("Couldn't send feedback. Check your connection.")
        }
    }
}
