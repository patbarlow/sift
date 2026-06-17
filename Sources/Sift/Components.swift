import SwiftUI
import AppKit

// MARK: - Spinner

/// CLI-style loading indicator: a 2-column, 3-row grid of dots with a bright
/// "comet" running clockwise around the perimeter. Used everywhere instead of
/// the system ProgressView.
struct SiftSpinner: View {
    var dot: CGFloat = 3
    var spacing: CGFloat = 2.5
    var color: Color = .secondary

    // grid index (row*2 + col) -> position along the clockwise perimeter
    // perimeter order of grid indices: 0,1,3,5,4,2 (TL,TR,MR,BR,BL,ML)
    private static let seqPos: [Int] = [0, 1, 5, 2, 4, 3]
    private static let step = 0.11

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.step)) { ctx in
            let head = Int(ctx.date.timeIntervalSinceReferenceDate / Self.step) % 6
            VStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<2, id: \.self) { c in
                            let idx = r * 2 + c
                            let dist = ((head - Self.seqPos[idx]) % 6 + 6) % 6
                            Circle()
                                .fill(color)
                                .frame(width: dot, height: dot)
                                .opacity(max(0.18, 1 - Double(dist) * 0.17))
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Row hover

/// A subtle hover highlight for list rows. Drawn as a background that extends
/// slightly past the content (negative padding), so it never shifts layout or
/// row spacing — it just lights up the row under the cursor.
struct RowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
                    .padding(.horizontal, -11)
                    .padding(.vertical, -8)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHover() -> some View { modifier(RowHover()) }
}

extension Shape {
    /// An opaque tinted fill: the window-card color with the tint painted over
    /// it. Because the base is opaque, a row's hover highlight behind can't
    /// bleed through and shift the color — the pill/card keeps its own color.
    func solidTint(_ tint: Color) -> some View {
        ZStack {
            fill(Color.themeWindowSolid)
            fill(tint)
        }
    }
}

// MARK: - Button

enum SiftButtonVariant {
    case primary      // accent fill, white text
    case secondary    // faint fill + border
    case subtle       // transparent until hover
    case destructive  // transparent until hover, then red
    case danger       // solid red fill, white text — destructive CTAs
}

/// Shared button styling: padding, rounding, and default/hover/pressed/selected
/// states. Hover is supplied by the wrapping `SiftButton` (a ButtonStyle can't
/// observe hover itself).
struct SiftButtonStyle: ButtonStyle {
    var variant: SiftButtonVariant = .subtle
    var hovering = false
    var selected = false
    var iconOnly = false
    var forceHighlight = false  // e.g. while a menu it triggers is open

    /// Fixed square size for icon-only buttons.
    static let iconSide: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        Group {
            if iconOnly {
                configuration.label
                    .frame(width: Self.iconSide, height: Self.iconSide)
            } else {
                configuration.label
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(foreground)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background(pressed: pressed))
        )
        .overlay {
            if variant == .secondary && !selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeOut(duration: 0.1), value: pressed)
    }

    private var foreground: Color {
        if variant == .danger { return .white }
        if variant == .destructive { return (hovering || forceHighlight) ? .white : .primary }
        if selected || variant == .primary { return .white }
        return .primary
    }

    private func background(pressed: Bool) -> Color {
        if selected { return Color.themeAccent }
        let active = hovering || forceHighlight
        switch variant {
        case .primary:
            return pressed ? Color.themeAccent.opacity(0.82) : Color.themeAccent
        case .secondary:
            return pressed ? Color.primary.opacity(0.12)
                 : (active ? Color.primary.opacity(0.1) : Color.primary.opacity(0.04))
        case .subtle:
            return pressed || forceHighlight ? Color.primary.opacity(0.12)
                 : (active ? Color.primary.opacity(0.07) : Color.clear)
        case .destructive:
            return pressed ? Color.red.opacity(0.85)
                 : (active ? Color.red : Color.clear)
        case .danger:
            return pressed ? Color.red.opacity(0.82) : Color.red
        }
    }
}

/// A button with consistent styling and hover/press states. Use the
/// convenience init for icon + text, or the trailing-closure init for custom
/// content (e.g. an integration logo).
struct SiftButton<Content: View>: View {
    var variant: SiftButtonVariant = .subtle
    var selected: Bool = false
    var iconOnly: Bool = false
    var forceHighlight: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) { content() }
            .buttonStyle(SiftButtonStyle(variant: variant, hovering: hovering && enabled, selected: selected, iconOnly: iconOnly, forceHighlight: forceHighlight))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .onHover { h in
                guard enabled else { return }
                hovering = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

struct SiftButtonLabel: View {
    let title: String?
    let leading: String?
    let trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            if let leading { LucideIcon(sf: leading, size: 14) }
            if let title { Text(title).lineLimit(1) }
            if let trailing { LucideIcon(sf: trailing, size: 14) }
        }
    }
}

extension SiftButton where Content == SiftButtonLabel {
    /// Text and/or SF Symbol icons (left/right).
    init(_ title: String? = nil,
         leading: String? = nil,
         trailing: String? = nil,
         variant: SiftButtonVariant = .subtle,
         selected: Bool = false,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(variant: variant, selected: selected, iconOnly: title == nil, enabled: enabled, action: action) {
            SiftButtonLabel(title: title, leading: leading, trailing: trailing)
        }
    }
}

// MARK: - Menu

/// Dropdown built from our own buttons. The menu renders in a floating panel
/// anchored to the trigger (like the right-click menu), so it can extend past
/// the window edge and never z-fights with sibling views. `content` receives
/// a `dismiss` to call after selecting.
struct SiftMenu<Label: View, Content: View>: View {
    @Binding var isOpen: Bool
    var variant: SiftButtonVariant = .subtle
    var iconOnly: Bool = false
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 360
    var scrolls: Bool = false          // long lists (models) scroll; short menus don't
    var alignTrailing: Bool = false    // anchor the menu to the trigger's right edge
    var hoverDismiss: Bool = false     // close when the cursor leaves (hover-opened menus)
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (@escaping () -> Void) -> Content
    @State private var anchorView: NSView?

    var body: some View {
        SiftButton(variant: variant, iconOnly: iconOnly, forceHighlight: isOpen, action: { isOpen.toggle() }) {
            label()
        }
        .background(AnchorCapture(view: $anchorView))
        .onChange(of: isOpen) { _, open in
            if open { present() } else { SiftContextMenuController.shared.dismiss() }
        }
        .onDisappear { if isOpen { SiftContextMenuController.shared.dismiss() } }
    }

    private func present() {
        guard let v = anchorView, let window = v.window else {
            isOpen = false
            return
        }
        let rect = window.convertToScreen(v.convert(v.bounds, to: nil))
        SiftContextMenuController.shared.show(
            anchoredTo: rect,
            alignTrailing: alignTrailing,
            minWidth: minWidth,
            scrollMaxHeight: scrolls ? maxHeight : nil,
            hoverDismiss: hoverDismiss,
            onDismiss: { isOpen = false }
        ) { dismiss in
            AnyView(VStack(alignment: .leading, spacing: 2) { content(dismiss) })
        }
    }
}

/// Captures the trigger's NSView so the menu panel can anchor to its screen
/// position.
private struct AnchorCapture: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shared dropdown/menu card chrome (rounded fill, border, shadow). Used by
/// `SiftMenu` and the right-click `siftContextMenu`, so both look identical.
struct SiftMenuCard<Content: View>: View {
    var minWidth: CGFloat = 200
    var fixedHeight: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(minWidth: minWidth)
            .fixedSize(horizontal: true, vertical: fixedHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.1))
            )
    }
}

/// A full-width row inside a `SiftMenu`.
struct SiftMenuItem: View {
    let title: String
    var systemImage: String? = nil
    var checked: Bool = false
    var destructive: Bool = false
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        SiftButton(variant: destructive ? .destructive : .subtle, action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    LucideIcon(sf: systemImage, size: 14).frame(width: 15)
                }
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if checked {
                    LucideIcon(sf: "checkmark", size: 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SiftMenuHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin divider line inside a menu.
struct SiftMenuDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 6).padding(.vertical, 3)
    }
}

/// A menu row that opens a flyout child panel (to its right) on hover. The
/// `children` closure builds the submenu and receives a `dismiss` that closes
/// the whole menu after a selection.
struct SiftSubmenu<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var children: (@escaping () -> Void) -> Content
    @State private var anchor: NSView?

    var body: some View {
        SiftButton(variant: .subtle, action: open) {
            HStack(spacing: 8) {
                if let systemImage { LucideIcon(sf: systemImage, size: 14).frame(width: 15) }
                Text(title)
                Spacer(minLength: 8)
                LucideIcon(sf: "chevron.right", size: 12)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AnchorCapture(view: $anchor))
        .onHover { if $0 { open() } }   // hover opens the flyout (replaces any open one)
    }

    private func open() {
        guard let v = anchor, let w = v.window else { return }
        let rect = w.convertToScreen(v.convert(v.bounds, to: nil))
        let ctrl = SiftContextMenuController.shared
        let present = {
            ctrl.showChild(owner: title, anchoredTo: rect) { dismiss in
                AnyView(VStack(alignment: .leading, spacing: 2) { children(dismiss) })
            }
        }
        // If another flyout is open and the cursor is still aimed at it, don't
        // steal it — the user is cutting the corner. Retry once they settle.
        if ctrl.currentChildOwner != nil, ctrl.currentChildOwner != title, ctrl.childProtected() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                guard NSMouseInRect(NSEvent.mouseLocation, rect, false) else { return }   // moved off this row
                guard ctrl.currentChildOwner != title else { return }                     // already ours
                guard !(ctrl.currentChildOwner != nil && ctrl.childProtected()) else { return } // still aimed elsewhere
                present()
            }
        } else {
            present()
        }
    }
}

// MARK: - Right-click context menu (our styling)

/// Transparent overlay that catches only right-clicks (left-clicks pass
/// straight through to the SwiftUI views beneath it via the nil-hitTest trick),
/// so a row stays fully interactive while gaining a custom context menu.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onRightClick: onRightClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onRightClick: () -> Void
        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            switch e.type {
            case .rightMouseDown, .rightMouseUp: return self
            default: return nil   // let left-clicks fall through to the row
            }
        }

        override func rightMouseDown(with event: NSEvent) { onRightClick() }
    }
}

/// Shows a `SiftMenuCard` in a borderless floating panel — at the cursor for
/// right-click menus, or anchored to a trigger for dropdowns. A panel can
/// extend past the window edge and never z-fights with in-window views.
@MainActor
final class SiftContextMenuController {
    static let shared = SiftContextMenuController()
    private var panel: NSPanel?
    private var childPanel: NSPanel?    // flyout submenu
    private var childOwner: String?     // which submenu opened the child
    private var childAnchor: NSRect = .zero
    private var childWatch: Timer?
    private var childUnsafeTicks = 0
    private var monitors: [Any] = []
    private var onDismissCallback: (() -> Void)?

    // Hover-to-close (opt-in, for hover-opened menus like the nav): close once
    // the cursor leaves the panel, its trigger, and any open flyout.
    private var hoverWatch: Timer?
    private var hoverUnsafeTicks = 0
    private var triggerRect: NSRect = .zero

    /// Margin around the card so its drop shadow has room to render inside
    /// the panel instead of being clipped at the window edge.
    private static let inset: CGFloat = 24

    /// Right-click menu at the mouse location.
    func show<Content: View>(@ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        let cursor = NSEvent.mouseLocation   // screen coords, bottom-left origin
        presentCard(
            minWidth: 180,
            scrollMaxHeight: nil,
            referencePoint: cursor,
            onDismiss: nil,
            origin: { size in
                NSPoint(x: cursor.x - Self.inset, y: cursor.y - size.height + Self.inset)
            },
            content: { d in AnyView(VStack(alignment: .leading, spacing: 2) { content(d) }) }
        )
    }

    /// Dropdown anchored below a trigger (screen coordinates); flips above
    /// when there's no room beneath.
    func show(anchoredTo anchor: NSRect,
              alignTrailing: Bool,
              minWidth: CGFloat,
              scrollMaxHeight: CGFloat?,
              hoverDismiss: Bool = false,
              onDismiss: @escaping () -> Void,
              content: @escaping (@escaping () -> Void) -> AnyView) {
        let reference = NSPoint(x: anchor.midX, y: anchor.midY)
        let vf = (NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main)?.visibleFrame ?? .zero
        presentCard(
            minWidth: minWidth,
            scrollMaxHeight: scrollMaxHeight,
            referencePoint: reference,
            onDismiss: onDismiss,
            triggerRect: hoverDismiss ? anchor : .zero,
            hoverDismiss: hoverDismiss,
            origin: { size in
                let x = alignTrailing
                    ? anchor.maxX - size.width + Self.inset
                    : anchor.minX - Self.inset
                var y = anchor.minY - 4 - size.height + Self.inset
                if y + Self.inset < vf.minY { y = anchor.maxY + 4 - Self.inset }
                return NSPoint(x: x, y: y)
            },
            content: content
        )
    }

    /// A flyout child panel to the right of a parent menu item (flips left if
    /// there's no room). Replaces any currently-open child.
    func showChild(owner: String, anchoredTo rect: NSRect, content: @escaping (@escaping () -> Void) -> AnyView) {
        if owner == childOwner, childPanel != nil { return }   // already open for this row
        closeChild()
        let dismissAll: () -> Void = { [weak self] in self?.dismiss() }
        let (panel, size) = buildPanel(minWidth: 170, scrollMaxHeight: nil, view: content(dismissAll))
        let vf = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = rect.maxX + 2 - Self.inset
        if x + size.width - Self.inset > vf.maxX { x = rect.minX - size.width + Self.inset }
        var y = rect.maxY - size.height + Self.inset
        y = min(max(y, vf.minY - Self.inset), vf.maxY - size.height + Self.inset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        childPanel = panel
        childOwner = owner
        childAnchor = rect
        // Watch the mouse: close the flyout when the cursor wanders to a
        // different parent row — but not while it's inside the safe triangle
        // aimed at the open flyout (lets you cut the corner to reach it).
        childUnsafeTicks = 0
        childWatch?.invalidate()
        childWatch = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.childTick() }
        }
    }

    private func childTick() {
        guard let child = childPanel else { return }
        let p = NSEvent.mouseLocation
        if child.frame.contains(p) || childAnchor.contains(p) || aimingAtChild(p, child: child.frame) {
            childUnsafeTicks = 0
            return
        }
        childUnsafeTicks += 1
        if childUnsafeTicks >= 3 { closeChild() }   // ~120ms outside the safe zone
    }

    /// True if the cursor sits in the triangle from the parent row's near edge
    /// to the flyout's two near corners — i.e. it's heading toward the flyout.
    private func aimingAtChild(_ p: NSPoint, child: NSRect) -> Bool {
        let onRight = child.midX > childAnchor.midX
        let apex = NSPoint(x: onRight ? childAnchor.maxX : childAnchor.minX, y: childAnchor.midY)
        let edgeX = onRight ? child.minX : child.maxX
        let c1 = NSPoint(x: edgeX, y: child.minY)
        let c2 = NSPoint(x: edgeX, y: child.maxY)
        func sign(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> CGFloat {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let d1 = sign(p, apex, c1), d2 = sign(p, c1, c2), d3 = sign(p, c2, apex)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    func closeChild() {
        childWatch?.invalidate()
        childWatch = nil
        childOwner = nil
        childPanel?.orderOut(nil)
        childPanel = nil
    }

    /// Which submenu currently owns the open flyout (nil if none).
    var currentChildOwner: String? { childOwner }

    /// Whether the open flyout is currently "protected" — cursor over it, on
    /// its parent row, or inside the safe triangle aimed at it. While true, a
    /// different submenu must not steal the panel.
    func childProtected() -> Bool {
        guard let child = childPanel else { return false }
        let p = NSEvent.mouseLocation
        return child.frame.contains(p) || childAnchor.contains(p) || aimingAtChild(p, child: child.frame)
    }

    /// Build a borderless menu panel sized to its content.
    private func buildPanel(minWidth: CGFloat, scrollMaxHeight: CGFloat?, view: AnyView) -> (NSPanel, NSSize) {
        let inner = view.padding(6)
        var root = AnyView(SiftMenuCard(minWidth: minWidth) { inner }.padding(Self.inset))
        var hosting = NSHostingView(rootView: root)
        var size = hosting.fittingSize
        if let maxH = scrollMaxHeight, size.height - Self.inset * 2 > maxH {
            root = AnyView(
                SiftMenuCard(minWidth: minWidth, fixedHeight: false) {
                    ScrollView { inner }.scrollBounceBehavior(.basedOnSize).frame(height: maxH)
                }
                .padding(Self.inset)
            )
            hosting = NSHostingView(rootView: root)
            size = hosting.fittingSize
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.contentView = hosting
        return (panel, size)
    }

    private func presentCard(minWidth: CGFloat,
                             scrollMaxHeight: CGFloat?,
                             referencePoint: NSPoint,
                             onDismiss: (() -> Void)?,
                             triggerRect: NSRect = .zero,
                             hoverDismiss: Bool = false,
                             origin: (NSSize) -> NSPoint,
                             content: @escaping (@escaping () -> Void) -> AnyView) {
        dismiss()
        onDismissCallback = onDismiss
        let dismissFn: () -> Void = { [weak self] in self?.dismiss() }
        let (panel, size) = buildPanel(minWidth: minWidth, scrollMaxHeight: scrollMaxHeight, view: content(dismissFn))

        let vf = (NSScreen.screens.first { $0.frame.contains(referencePoint) } ?? NSScreen.main)?.visibleFrame
        var o = origin(size)
        if let vf {
            o.x = min(max(o.x, vf.minX - Self.inset), vf.maxX - size.width + Self.inset)
            o.y = min(max(o.y, vf.minY - Self.inset), vf.maxY - size.height + Self.inset)
        }
        panel.setFrameOrigin(o)
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss on any click outside both panels; swallow that click so it
        // only closes the menu rather than activating what's underneath.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel || event.window === self.childPanel { return event }
            self.dismiss()
            return nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        monitors = [local, global].compactMap { $0 }

        if hoverDismiss {
            self.triggerRect = triggerRect
            hoverUnsafeTicks = 0
            hoverWatch?.invalidate()
            hoverWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverTick() }
            }
        }
    }

    /// Close once the cursor has been outside the panel, its trigger, and any
    /// flyout for a short grace period (avoids closing on a quick overshoot).
    private func hoverTick() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        let inMain = panel.frame.contains(p) || triggerRect.contains(p)
        let inChild = (childPanel?.frame.contains(p) ?? false)
            || (childOwner != nil && childAnchor.contains(p))
            || (childPanel.map { aimingAtChild(p, child: $0.frame) } ?? false)
        if inMain || inChild { hoverUnsafeTicks = 0; return }
        hoverUnsafeTicks += 1
        if hoverUnsafeTicks >= 2 { dismiss() }   // ~60ms outside
    }

    func dismiss() {
        hoverWatch?.invalidate()
        hoverWatch = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        closeChild()
        panel?.orderOut(nil)
        panel = nil
        let callback = onDismissCallback
        onDismissCallback = nil
        callback?()
    }
}

extension View {
    /// Attach a right-click menu rendered with our own components. `items`
    /// receives a `dismiss` closure to call after a selection.
    func siftContextMenu<Content: View>(@ViewBuilder _ items: @escaping (@escaping () -> Void) -> Content) -> some View {
        overlay(RightClickCatcher {
            SiftContextMenuController.shared.show(content: items)
        })
    }
}
