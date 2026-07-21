import SwiftUI
import AppKit

// MARK: - Palette (ob_ prefix, file-private)

private extension Color {
    static let obBg     = Color(red: 0.957, green: 0.945, blue: 0.925)
    static let obPanel  = Color(red: 0.933, green: 0.922, blue: 0.902)
    static let obTerra  = Color(red: 0.788, green: 0.416, blue: 0.290)
    static let obSage   = Color(red: 0.494, green: 0.616, blue: 0.514)
    static let obSageL  = Color(red: 0.722, green: 0.788, blue: 0.729)
    static let obText   = Color(red: 0.118, green: 0.102, blue: 0.090)
    static let obText2  = Color(red: 0.392, green: 0.369, blue: 0.345)
    static let obBorder = Color(red: 0.863, green: 0.847, blue: 0.824)
}

private extension LLMProviderKind {
    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai:    return "https://platform.openai.com/api-keys"
        case .gemini:    return "https://aistudio.google.com/app/apikey"
        case .deepseek:  return "https://platform.deepseek.com/api_keys"
        case .groq:      return "https://console.groq.com/keys"
        }
    }

    var brandColor: Color {
        switch self {
        case .anthropic: return Color(red: 0.788, green: 0.416, blue: 0.290)
        case .openai:    return Color(red: 0.059, green: 0.427, blue: 0.314)
        case .gemini:    return Color(red: 0.251, green: 0.494, blue: 0.988)
        case .groq:      return Color(red: 0.961, green: 0.584, blue: 0.188)
        case .deepseek:  return Color(red: 0.259, green: 0.522, blue: 0.957)
        }
    }
}

// MARK: - Root

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var onComplete: () -> Void = {}

    @State private var slide = 0

    var body: some View {
        ZStack {
            Color.obBg.ignoresSafeArea()
            slideContent
        }
        .frame(width: 860, height: 560)
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i == slide ? Color.obTerra : Color.obBorder)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var slideContent: some View {
        switch slide {
        case 0:  IntroSlide(onNext: { slide = 1 })
        case 1:  AISetupSlide(onBack: { slide = 0 }, onNext: { slide = 2 })
        default: SlackSetupSlide(onBack: { slide = 1 }, onDone: finish)
        }
    }

    private func finish() {
        state.refreshConfigured()
        if state.hasConfigured { state.startScheduler(kickNow: true) }
        onComplete()
    }
}

// MARK: - Slide 1: Intro

private struct IntroSlide: View {
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            FilteringIllustration()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .padding(.bottom, 8)

                Text("Meet your new\nbest friend")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.obText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sift keeps track of your Slack threads, mentions, and DMs, and surfaces the ones that need you.")
                    Text("It runs locally on your machine with your own AI API key, and it picks up on priority, deadlines, and related conversations.")
                    Text("You can close tasks manually, or let Sift do it automatically once it sees you've replied.")
                }
                .font(.system(.callout))
                .foregroundStyle(Color.obText2)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                ObButton("Get started", icon: "arrow.right", action: onNext)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 36)
            .frame(width: 340, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filtering Illustration

private struct FilteringIllustration: View {
    struct Msg {
        let letter: String; let color: Color
        let name: String;   let time: String
        let channel: String; let text: String
        let replies: Int?
    }
    struct FakeTodo {
        let title: String; let sub: String; let due: Bool
    }

    private let msgs: [Msg] = [
        Msg(letter: "M", color: Color(red: 0.788, green: 0.416, blue: 0.290),
            name: "Maya Chen",  time: "10:24", channel: "#product",
            text: "Review the onboarding copy before we ship?", replies: 3),
        Msg(letter: "S", color: Color(red: 0.494, green: 0.616, blue: 0.514),
            name: "Sam Rivera", time: "9:48",  channel: "#support",
            text: "Customer flagged the export bug again", replies: 5),
        Msg(letter: "P", color: Color(red: 0.537, green: 0.435, blue: 0.710),
            name: "Priya R.",   time: "9:12",  channel: "direct",
            text: "Ping me about the Q3 plan when free", replies: nil),
        Msg(letter: "A", color: Color(red: 0.788, green: 0.416, blue: 0.290),
            name: "Alex T.",    time: "8:30",  channel: "#design",
            text: "Can you approve the design tokens PR?", replies: nil),
    ]
    private let todos: [FakeTodo] = [
        FakeTodo(title: "Review onboarding copy",    sub: "Maya · #product", due: true),
        FakeTodo(title: "Fix customer export bug",    sub: "Sam · #support",  due: false),
        FakeTodo(title: "Reply to Priya re Q3 plan", sub: "Priya · direct",  due: false),
        FakeTodo(title: "Approve design tokens PR",  sub: "Alex · #design",  due: false),
    ]

    private let cardW: CGFloat    = 216
    private let cardH: CGFloat    = 84
    private let cardGap: CGFloat  = 10
    private let cardX: CGFloat    = 16
    private let cardStartY: CGFloat = 30
    private let panelX: CGFloat   = 262
    private let panelY: CGFloat   = 14
    private let panelW: CGFloat   = 220
    private let panelH: CGFloat   = 426
    private let panelTodoOffset: CGFloat = 76
    private let todoRowH: CGFloat = 62

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let rightX = cardX + cardW
                let leftX  = panelX
                let midX   = (rightX + leftX) / 2
                for i in 0..<4 {
                    let fromY = cardStartY + CGFloat(i) * (cardH + cardGap) + cardH / 2
                    let toY   = panelY + panelTodoOffset + CGFloat(i) * todoRowH + todoRowH / 2
                    var path = Path()
                    path.move(to: CGPoint(x: rightX + 2, y: fromY))
                    path.addCurve(
                        to:       CGPoint(x: leftX - 2, y: toY),
                        control1: CGPoint(x: midX, y: fromY),
                        control2: CGPoint(x: midX, y: toY)
                    )
                    ctx.stroke(path,
                               with: .color(Color.obSageL.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ForEach(msgs.indices, id: \.self) { i in
                FakeSlackCard(msg: msgs[i])
                    .frame(width: cardW, height: cardH)
                    .offset(x: cardX, y: cardStartY + CGFloat(i) * (cardH + cardGap))
            }

            FakeSiftPanel(todos: todos)
                .frame(width: panelW, height: panelH)
                .offset(x: panelX, y: panelY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.obBg)
        .clipped()
    }
}

private struct FakeSlackCard: View {
    let msg: FilteringIllustration.Msg
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(msg.color)
                Text(msg.letter)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(msg.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.obText)
                    Text(msg.time)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.obText2.opacity(0.55))
                    Spacer(minLength: 0)
                    Text(msg.channel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.obText2.opacity(0.65))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.obBg, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.obText2)
                    .lineLimit(2)
                if let r = msg.replies {
                    HStack(spacing: 3) {
                        Circle().fill(Color.obSage).frame(width: 5, height: 5)
                        Circle().fill(Color.obTerra).frame(width: 5, height: 5)
                        Text("\(r) replies").font(.system(size: 9)).foregroundStyle(Color.obSage)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.obBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}

private struct FakeSiftPanel: View {
    let todos: [FilteringIllustration.FakeTodo]
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle().fill(Color.obSage).frame(width: 8, height: 8)
                Text("Sift").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.obText)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            // Tabs — text weight only, no pill background
            HStack(spacing: 0) {
                ForEach(["Todos", "Snoozed", "Stale"], id: \.self) { tab in
                    Text(tab)
                        .font(.system(size: 10, weight: tab == "Todos" ? .semibold : .regular))
                        .foregroundStyle(tab == "Todos" ? Color.obTerra : Color.obText2.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                Spacer()
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(todos.indices, id: \.self) { i in
                    FakeTodoRow(todo: todos[i])
                    if i < todos.count - 1 { Divider().padding(.leading, 30) }
                }
            }
            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.obBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
    }
}

private struct FakeTodoRow: View {
    let todo: FilteringIllustration.FakeTodo
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().stroke(Color.obBorder, lineWidth: 1.5)
                .frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(todo.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.obText).lineLimit(1)
                    if todo.due {
                        Text("Due today")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.obTerra)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.obTerra.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(todo.sub).font(.system(size: 9)).foregroundStyle(Color.obText2.opacity(0.6))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Slide 2: AI Setup

private struct AISetupSlide: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    let onBack: () -> Void
    let onNext: () -> Void

    @State private var llmKey = ""

    private var connected: Bool { settings.fastProvider.isConnected() }

    private func saveKey() {
        let key = llmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.write(key, for: settings.fastProvider.keychainKey)
        llmKey = ""
        state.refreshConfigured()
    }

    var body: some View {
        HStack(spacing: 0) {
            ObSidePanel(
                icon: "cpu",
                headline: "Set up your\nAI provider.",
                bodyText: "Sift uses AI to read threads and decide what matters. Pick a provider and paste your key."
            )

            VStack(alignment: .leading, spacing: 0) {
                // Provider grid
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        ProviderCard(
                            kind: kind,
                            isSelected: settings.fastProvider == kind
                        ) {
                            settings.fastProvider = kind
                            settings.smartProvider = kind
                            settings.fastModel  = kind.defaultFastModel
                            settings.smartModel = kind.defaultSmartModel
                        }
                    }
                }
                .padding(.top, 20)

                if settings.fastProvider.needsAPIKey {
                    Text("API key")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.obText2)
                        .padding(.top, 20)

                    HStack(spacing: 8) {
                        SecureField(settings.fastProvider.keyPlaceholder, text: $llmKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        ObButton(connected ? "Replace" : "Save",
                                 enabled: !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                 action: saveKey)
                    }
                    .padding(.top, 6)

                    HStack(spacing: 12) {
                        if connected {
                            Label("Key saved", systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(Color.obSage)
                        }
                        if let url = URL(string: settings.fastProvider.consoleURL) {
                            Link("Get a key →", destination: url)
                                .font(.footnote).foregroundStyle(Color.obTerra)
                        }
                    }
                    .padding(.top, 6)
                }

                Spacer(minLength: 0)

                ObNavRow(
                    onBack: onBack, onNext: onNext,
                    nextLabel: "Connect Slack",
                    nextEnabled: connected || !settings.fastProvider.needsAPIKey
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let kind: LLMProviderKind
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IntegrationLogoView(logo: .provider(kind), size: 22)
                Text(kind.displayName)
                    .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.obText : Color.obText2)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.obTerra)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected  ? Color.obTerra.opacity(0.08) :
                hovering    ? Color.obBorder.opacity(0.5)  : Color.white,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.obTerra.opacity(0.4) : Color.obBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over
            over ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}

// MARK: - Slide 3: Slack Setup

private struct SlackSetupSlide: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @StateObject private var oauth = OAuthCoordinator.shared

    let onBack: () -> Void
    let onDone: () -> Void

    @State private var showManualToken = false
    @State private var manualToken = ""
    @State private var resolving = false
    @State private var error: String?

    private var connected: Bool {
        !settings.slackUserID.isEmpty && Keychain.read(SecretKey.slack) != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ObSidePanel(
                icon: "bubble.left.and.bubble.right",
                headline: "Read-only.\nAlways.",
                bodyText: "Sift never posts, replies,\nor changes anything in Slack.\nYour messages stay on your Mac."
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("Connect your Slack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.obText)

                Text("Sift watches your @mentions, DMs, and any channels you choose — and pulls out the threads that need your attention.")
                    .font(.system(.callout))
                    .foregroundStyle(Color.obText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if connected {
                    Label(
                        "Connected as @\(settings.slackHandle.isEmpty ? settings.slackUserID : settings.slackHandle)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout).foregroundStyle(Color.obSage)
                    .padding(.top, 24)

                    ObTextButton("Reconnect") { oauth.start() }
                        .padding(.top, 6)
                } else {
                    ObButton(
                        oauth.inProgress ? "Waiting for browser…" : "Connect with Slack",
                        icon: oauth.inProgress ? nil : "link",
                        color: .obSage,
                        fullWidth: true,
                        action: { error = nil; oauth.start() }
                    )
                    .padding(.top, 24)

                    if oauth.inProgress {
                        ObTextButton("Cancel") { oauth.cancel() }
                            .padding(.top, 6)
                    }
                }

                ObTextButton(showManualToken ? "Hide manual entry" : "Or paste a token manually") {
                    showManualToken.toggle()
                }
                .padding(.top, 14)

                if showManualToken {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Create a Slack app at api.slack.com/apps with user token scopes: search:read, channels:read, channels:history, groups:read, groups:history, users:read, users:read.email, emoji:read, files:read.")
                            .font(.caption).foregroundStyle(Color.obText2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            SecureField("xoxp-…", text: $manualToken)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") { resolveToken() }
                                .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolving)
                            if resolving { ProgressView().scaleEffect(0.75) }
                        }
                    }
                    .padding(.top, 8)
                }

                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.top, 8)
                }
                if let err = state.lastError, !err.isEmpty {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.top, 4)
                }

                Spacer(minLength: 0)

                ObNavRow(
                    onBack: onBack, onNext: onDone,
                    nextLabel: connected ? "Done" : "Skip for now",
                    nextEnabled: true,
                    nextIcon: connected ? "checkmark" : nil,
                    nextColor: connected ? Color.obTerra : Color.obText2.opacity(0.5)
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolveToken() {
        let trimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resolving = true; error = nil
        Task {
            do {
                let client  = SlackClient(token: trimmed)
                let auth    = try await client.authTest()
                let profile = try await client.userProfile(userID: auth.userID)
                await MainActor.run {
                    Keychain.write(trimmed, for: SecretKey.slack)
                    settings.slackUserID = auth.userID
                    settings.slackHandle = auth.userName
                    settings.slackTeamID = auth.teamID
                    if !profile.displayName.isEmpty { settings.displayName = profile.displayName }
                    if !profile.email.isEmpty       { settings.email       = profile.email }
                    manualToken = ""; showManualToken = false; resolving = false
                    state.refreshConfigured()
                }
            } catch {
                await MainActor.run {
                    self.error = "Token failed: \(error.localizedDescription)"
                    resolving = false
                }
            }
        }
    }
}

// MARK: - Shared components

/// Left decorative panel used on slides 2 and 3.
private struct ObSidePanel: View {
    let icon: String
    let headline: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Color.obSage)
            Text(headline)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(Color.obText)
            Text(bodyText)
                .font(.system(.callout))
                .foregroundStyle(Color.obText2)
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Color.obPanel)
    }
}

/// Primary action button with hover state and pointer cursor.
private struct ObButton: View {
    let label: String
    var icon: String?
    var color: Color = .obTerra
    var fullWidth: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    init(_ label: String, icon: String? = nil, color: Color = .obTerra,
         fullWidth: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.color = color
        self.fullWidth = fullWidth; self.enabled = enabled; self.action = action
    }

    var body: some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(.callout, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(enabled ? (hovering ? color.opacity(0.82) : color)
                                : color.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over && enabled
            (over && enabled) ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}

/// Subtle text-only button (for Back, Cancel, etc.)
private struct ObTextButton: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.footnote))
                .foregroundStyle(hovering ? Color.obText : Color.obText2)
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over
            over ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}

/// Back + primary CTA row used at the bottom of setup slides.
private struct ObNavRow: View {
    let onBack: () -> Void
    let onNext: () -> Void
    let nextLabel: String
    var nextEnabled: Bool = true
    var nextIcon: String? = "arrow.right"
    var nextColor: Color = .obTerra

    var body: some View {
        HStack {
            ObTextButton("Back", action: onBack)
            Spacer()
            ObButton(nextLabel, icon: nextIcon, color: nextEnabled ? nextColor : Color.obText2.opacity(0.3)) {
                guard nextEnabled else { return }
                onNext()
            }
        }
        .padding(.bottom, 32)
    }
}
