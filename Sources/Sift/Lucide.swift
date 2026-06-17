import SwiftUI
import AppKit

/// Renders Lucide (lucide.dev, ISC-licensed) icons bundled as template SVGs.
/// Keyed by the SF Symbol name used at each call site, so menu chrome can swap
/// renderers without rewriting every string. An unmapped name falls back to the
/// SF Symbol, so an icon never silently disappears.
enum Lucide {
    /// SF Symbol name → bundled Lucide file (without `lucide-` prefix / `.svg`).
    private static let map: [String: String] = [
        "checkmark": "check",
        "xmark": "x",
        "line.3.horizontal": "menu",
        "gearshape": "settings",
        "trash": "trash-2",
        "chevron.right": "chevron-right",
        "chevron.up.chevron.down": "chevrons-up-down",
        "magnifyingglass": "search",
        "moon.zzz": "moon",
        "moon.zzz.fill": "moon",
        "bell": "bell",
        "calendar": "calendar",
        "calendar.badge.clock": "calendar-clock",
        "clock.arrow.circlepath": "history",
        "clock.badge.exclamationmark": "clock-alert",
        "hourglass": "hourglass",
        "bolt": "zap",
        "checklist": "list-todo",
        "questionmark.circle": "circle-question-mark",
        "archivebox": "archive",
        "checkmark.circle": "circle-check",
        "checkmark.circle.fill": "circle-check",
        "rectangle.3.group": "group",
        "rectangle.compress.vertical": "minimize-2",
        "rectangle.lefthalf.inset.filled": "panel-left",
        "rectangle.righthalf.inset.filled": "panel-right",
        "rectangle.on.rectangle": "monitor",
        "arrow.uturn.backward": "undo-2",
        "bubble.left": "message-square",
        "bubble.left.and.bubble.right": "messages-square",
        "link": "link",
        "flag": "flag",
        "wand.and.stars": "wand-sparkles",
        "plus.circle.fill": "circle-plus",
        "minus.circle.fill": "circle-minus",
        "exclamationmark.circle": "circle-alert",
        "exclamationmark.circle.fill": "circle-alert",
        "xmark.circle": "circle-x",
        "xmark.circle.fill": "circle-x",
        "arrow.down.circle": "circle-arrow-down",
        "arrow.right.circle": "circle-arrow-right",
        "tray": "inbox",
        "tray.full": "inbox",
        "tray.and.arrow.down": "inbox",
        "sun.max": "sun",
        "circle": "circle",
        "square.grid.2x2": "grid-2x2",
        "rectangle.split.2x1": "columns-2",
        "arrow.up.left.and.arrow.down.right": "maximize-2",
        "note.text": "file-text",
        "terminal": "square-terminal",
    ]

    private static var cache: [String: NSImage] = [:]

    /// A tintable template image for the given SF Symbol name, or nil if there's
    /// no Lucide mapping or the asset is missing.
    static func image(forSF sf: String) -> NSImage? {
        guard let file = map[sf] else { return nil }
        if let cached = cache[file] { return cached }
        guard let url = Bundle.module.url(forResource: "lucide-\(file)", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[file] = img
        return img
    }
}

/// Drop-in replacement for `Image(systemName:)` in menu / dropdown chrome:
/// renders the Lucide equivalent when one exists, else the SF Symbol. Tints with
/// the ambient `foregroundStyle`, like a symbol.
struct LucideIcon: View {
    let sf: String
    var size: CGFloat = 14

    init(sf: String, size: CGFloat = 14) {
        self.sf = sf
        self.size = size
    }

    var body: some View {
        if let img = Lucide.image(forSF: sf) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: sf)
        }
    }
}
