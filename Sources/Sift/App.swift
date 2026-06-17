import SwiftUI
import SwiftData
import AppKit
import Combine
import Sparkle

@main
struct SiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings scene is required by macOS but we don't use it; the real
        // window lives in AppDelegate.
        Settings {
            Text("Sift").padding()
        }
    }
}

enum WindowSnapAction {
    case snapLeft
    case snapRight
    case nextDisplayLeft
    case nextDisplayRight
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let container: ModelContainer
    let state: AppState
    let settings: AppSettings

    private var statusItem: NSStatusItem!
    private var window: TodoFloatingWindow!
    private var settingsWindow: NSWindow?
    private var diagnosticWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    // Auto-updates via Sparkle. Starts the updater (background checks honour
    // SUEnableAutomaticChecks in Info.plist); "Check for Updates…" is in the menu.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // "O then <key>" navigation: press O to arm, then a letter to jump.
    private var navArmed = false
    private var navReset: DispatchWorkItem?

    override init() {
        // Persistent SQLite store under Application Support.
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Sift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("Sift.sqlite")
        let cfg = ModelConfiguration(url: storeURL)
        self.container = try! ModelContainer(
            for: Todo.self, TodoComment.self, TodoSource.self, WatchedChannel.self,
            IgnoredMentionChannel.self, SyncCursor.self,
            ProcessedGranolaMeeting.self, MemoryEntry.self, IgnoredThread.self,
            ActivityEvent.self,
            configurations: cfg
        )
        self.settings = AppSettings()
        self.state = AppState(container: container, settings: settings)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Sift")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        window = TodoFloatingWindow(
            container: container,
            state: state,
            settings: settings,
            onClose: { [weak self] in self?.hideWindow() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        // Refresh status badge whenever state changes.
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)

        refreshStatusItem()

        // Personalisation: appearance override.
        settings.$appearanceMode
            .receive(on: DispatchQueue.main)
            .sink { NSApp.appearance = $0.nsAppearance }
            .store(in: &cancellables)

        if state.hasConfigured {
            state.startScheduler()
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleNavKey(event) ?? event
        }
    }

    /// "O then <letter>" jumps between views while a Sift window is focused.
    /// Returns nil to swallow the keystroke, or the event to pass it through.
    private func handleNavKey(_ event: NSEvent) -> NSEvent? {
        // Only when one of our windows is focused and no text field is editing.
        let focused = NSApp.keyWindow
        guard focused === window else { return event }
        if let r = focused?.firstResponder, r is NSText || r is NSTextView { return event }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()

        if navArmed {
            navArmed = false
            navReset?.cancel()
            let tab: MainTab?
            switch key {
            case "t": tab = .todos
            case "z": tab = .snoozed
            case "s": tab = .stale
            case "r": tab = .review
            case "c": tab = .completed
            case "a": tab = .archived
            case "v": tab = .activity
            case ",": openSettings(); return nil
            default: return event
            }
            if let tab {
                state.mainTab = tab
            }
            return nil
        }

        if key == "o" {
            navArmed = true
            navReset?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.navArmed = false }
            navReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
            return nil
        }
        return event
    }

    @objc private func statusItemClicked(_ sender: AnyObject) {
        guard let event = NSApp.currentEvent else { toggleWindow(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            toggleWindow()
        }
    }

    private func toggleWindow() {
        if window.isVisible { hideWindow() } else { window.show(near: statusItem.button) }
    }

    func hideWindow() { window.orderOut(nil) }

    private func showStatusMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let syncItem = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "r")
        syncItem.target = self
        menu.addItem(syncItem)
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = updaterController
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sift",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func syncNow() { state.runSync() }

    // MARK: - URL scheme handler (Slack OAuth callback)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == Config.urlScheme {
            handleAppURL(url)
        }
    }

    private func handleAppURL(_ url: URL) {
        // Expect: sift://oauth/slack#token=…&user_id=…&state=…
        guard url.host?.lowercased() == "oauth" else { return }
        guard url.pathComponents.contains("slack") else { return }
        do {
            let result = try OAuthCoordinator.shared.handleCallback(url)
            Keychain.write(result.token, for: SecretKey.slack)
            settings.slackUserID = result.userID
            settings.slackHandle = result.userName
            settings.slackTeamID = result.teamID
            settings.slackAuthMethod = "oauth"

            // Auto-populate displayName + email by fetching the user's profile.
            Task { [weak self] in
                guard let self else { return }
                let slack = SlackClient(token: result.token)
                if let profile = try? await slack.userProfile(userID: result.userID) {
                    await MainActor.run {
                        if self.settings.displayName.isEmpty {
                            self.settings.displayName = profile.displayName
                        }
                        if self.settings.email.isEmpty {
                            self.settings.email = profile.email
                        }
                    }
                }
            }

            state.refreshConfigured()
            // First connect — populate right away.
            if state.hasConfigured { state.startScheduler(kickNow: true) }
            NSApp.activate(ignoringOtherApps: true)
            window.show(near: statusItem.button)
        } catch {
            state.lastError = "OAuth: \(error.localizedDescription)"
        }
    }

    @objc func openDiagnostic() {
        if diagnosticWindow == nil {
            let host = NSHostingView(
                rootView: DiagnosticView()
                    .environmentObject(state)
                    .environmentObject(settings)
                    .modelContainer(container)
            )
            host.autoresizingMask = [.width, .height]
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Sift Diagnostic"
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.contentView = host
            diagnosticWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticWindow?.makeKeyAndOrderFront(nil)
        diagnosticWindow?.center()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(state)
                    .environmentObject(settings)
                    .modelContainer(container)
            )
            host.autoresizingMask = [.width, .height]
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Sift Settings"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.contentView = host
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.center()
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let ctx = ModelContext(container)
        // Match the Todos tab: open todos only — exclude stale, snoozed, and
        // anything pending review (and done/archived are already not open).
        let p = #Predicate<Todo> { $0.status != "done" && $0.status != "archived" && $0.classification == "todo" }
        let open = (try? ctx.fetch(FetchDescriptor<Todo>(predicate: p))) ?? []
        let count = open.filter { $0.isOpen && !$0.isStale && !$0.isSnoozed && !$0.pendingReview }.count
        button.title = count > 0 ? " \(count)" : ""
        button.image = NSImage(
            systemSymbolName: count > 0 ? "tray.full" : "checkmark.circle",
            accessibilityDescription: "Sift"
        )
    }
}

/// Floating window with a transparent titlebar — gives standard macOS traffic
/// lights at top-left while our SwiftUI content fills the whole frame.
final class TodoFloatingWindow: NSWindow, NSWindowDelegate {
    private let state: AppState

    // Custom traffic-light placement (from the window's top-left), so they sit
    // with even spacing inside the header band rather than jammed in the corner.
    // `trafficGap` is the visible gap *between* buttons (not edge-to-edge).
    private static let trafficInset = CGPoint(x: 14, y: 15)
    private static let trafficGap: CGFloat = 8

    init(container: ModelContainer,
         state: AppState,
         settings: AppSettings,
         onClose: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isOpaque = true
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.isMovable = true
        self.setFrameAutosaveName("SiftMainWindow")

        let hosting = NSHostingView(
            rootView: MenuBarContent(
                onClose: onClose,
                onSnap: { [weak self] action in self?.snap(action) },
                onOpenSettings: onOpenSettings
            )
                .environmentObject(state)
                .environmentObject(state.settings)
                .modelContainer(container)
        )
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
        self.delegate = self
    }

    /// Place the traffic lights at our custom inset. AppKit re-lays them on
    /// resize / key changes, so this is reapplied from the delegate hooks.
    private func positionTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        var x = Self.trafficInset.x
        for button in buttons {
            let size = button.frame.size
            button.setFrameOrigin(NSPoint(x: x, y: container.bounds.height - Self.trafficInset.y - size.height))
            x += size.width + Self.trafficGap
        }
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    func show(near anchor: NSStatusBarButton?) {
        let target = anchor?.window?.screen ?? self.screen ?? NSScreen.main
        if let screen = target { snapToEdge(.right, on: screen) }
        makeKeyAndOrderFront(nil)
        // Reapply after AppKit's own layout pass on show.
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
        // Opening doesn't sync — the scheduler keeps data fresh on its interval
        // and "Sync now" is in the menu. Keeps the spinner from firing on open.
    }

    func snap(_ action: WindowSnapAction) {
        switch action {
        case .snapLeft:
            if let s = screen ?? NSScreen.main { snapToEdge(.left, on: s) }
        case .snapRight:
            if let s = screen ?? NSScreen.main { snapToEdge(.right, on: s) }
        case .nextDisplayLeft:
            if let n = nextDisplay() { snapToEdge(.left, on: n) }
        case .nextDisplayRight:
            if let n = nextDisplay() { snapToEdge(.right, on: n) }
        }
    }

    private enum Edge { case left, right }
    private static let snapPadding: CGFloat = 12

    private func snapToEdge(_ edge: Edge, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let p = Self.snapPadding
        let width = min(frame.width, visible.width - p * 2)
        let originX: CGFloat
        switch edge {
        case .left: originX = visible.minX + p
        case .right: originX = visible.maxX - width - p
        }
        let height = visible.height - p * 2
        let newFrame = NSRect(x: originX, y: visible.minY + p, width: width, height: height)
        setFrame(newFrame, display: true, animate: true)
    }

    private func nextDisplay() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1, let current = self.screen,
              let idx = screens.firstIndex(of: current) else { return nil }
        return screens[(idx + 1) % screens.count]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let target = screen ?? self.screen ?? NSScreen.main
        guard let visible = target?.visibleFrame else {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        var f = frameRect
        f.size.width = min(f.size.width, visible.width)
        f.size.height = min(f.size.height, visible.height)
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        return f
    }
}
