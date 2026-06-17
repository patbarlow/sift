import SwiftUI
import AppKit

/// A visual theme: accent, window/card tints, and a type design that suits it.
/// Themes are hand-tuned palettes inspired by well-known tools rather than
/// imported theme files — every color has a light and a dark variant.
struct SiftTheme: Identifiable {
    let id: String
    let name: String
    let accent: Color
    /// Main floating window fill.
    let windowSolid: Color
    /// The pill bar at the top of the todo window.
    let headerBackground: Color
    /// Settings window page background and card fill.
    let settingsBackground: Color
    let cardBackground: Color
    let fontDesign: Font.Design

    /// Adaptive color from explicit light/dark hex values.
    private static func dyn(light: String, dark: String,
                            lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
                return NSColor(hex: dark, alpha: darkAlpha)
            }
            return NSColor(hex: light, alpha: lightAlpha)
        })
    }

    static let all: [SiftTheme] = [.standard, .github, .claude, .catppuccin, .linear, .gotham]

    static func theme(id: String) -> SiftTheme {
        all.first { $0.id == id } ?? .standard
    }

    /// The app's original look.
    static let standard = SiftTheme(
        id: "default",
        name: "Default",
        accent: Color(nsColor: .controlAccentColor),
        windowSolid: dyn(light: "FFFFFF", dark: "121212"),
        headerBackground: dyn(light: "F0F0F0", dark: "242424"),
        settingsBackground: dyn(light: "F1F1F1", dark: "1E1E1E"),
        cardBackground: Color(nsColor: .controlBackgroundColor),
        fontDesign: .default
    )

    static let github = SiftTheme(
        id: "github",
        name: "GitHub",
        accent: dyn(light: "1F883D", dark: "3FB950"),
        windowSolid: dyn(light: "FFFFFF", dark: "0D1117"),
        headerBackground: dyn(light: "F6F8FA", dark: "161B22"),
        settingsBackground: dyn(light: "F6F8FA", dark: "010409"),
        cardBackground: dyn(light: "FFFFFF", dark: "161B22"),
        fontDesign: .default
    )

    static let claude = SiftTheme(
        id: "claude",
        name: "Claude",
        accent: dyn(light: "C96442", dark: "D97757"),
        windowSolid: dyn(light: "FAF9F5", dark: "262624"),
        headerBackground: dyn(light: "F0EEE6", dark: "30302E"),
        settingsBackground: dyn(light: "F0EEE6", dark: "1F1E1D"),
        cardBackground: dyn(light: "FFFFFF", dark: "30302E"),
        fontDesign: .serif
    )

    static let catppuccin = SiftTheme(
        id: "catppuccin",
        name: "Catppuccin",
        accent: dyn(light: "8839EF", dark: "CBA6F7"),
        windowSolid: dyn(light: "EFF1F5", dark: "1E1E2E"),
        headerBackground: dyn(light: "E6E9EF", dark: "313244"),
        settingsBackground: dyn(light: "E6E9EF", dark: "11111B"),
        cardBackground: dyn(light: "FFFFFF", dark: "313244"),
        fontDesign: .rounded
    )

    static let linear = SiftTheme(
        id: "linear",
        name: "Linear",
        accent: dyn(light: "5E6AD2", dark: "7B83EB"),
        windowSolid: dyn(light: "FFFFFF", dark: "0F1011"),
        headerBackground: dyn(light: "F4F5F8", dark: "1C1D1F"),
        settingsBackground: dyn(light: "F4F5F8", dark: "08090A"),
        cardBackground: dyn(light: "FFFFFF", dark: "1C1D1F"),
        fontDesign: .default
    )

    static let gotham = SiftTheme(
        id: "gotham",
        name: "Gotham",
        accent: dyn(light: "1B7B68", dark: "2AA889"),
        windowSolid: dyn(light: "E8EAED", dark: "0A0F14"),
        headerBackground: dyn(light: "DDE1E6", dark: "11151C"),
        settingsBackground: dyn(light: "DDE1E6", dark: "06090D"),
        cardBackground: dyn(light: "F7F9FA", dark: "11151C"),
        fontDesign: .monospaced
    )
}

/// Current theme, readable from anywhere (button styles, cards) without
/// plumbing. Views re-evaluate it whenever AppSettings publishes a change.
enum ThemeBox {
    static var current: SiftTheme = .standard
}

extension Color {
    static var themeAccent: Color { ThemeBox.current.accent }
    static var themeCard: Color { ThemeBox.current.cardBackground }
    static var themeSettingsBackground: Color { ThemeBox.current.settingsBackground }
    static var themeHeader: Color { ThemeBox.current.headerBackground }
    /// The main content-card fill. Used as an opaque base under translucent
    /// pills/cards so a row's hover highlight can't bleed through and tint them.
    static var themeWindowSolid: Color { ThemeBox.current.windowSolid }
}

extension NSColor {
    /// 6-digit hex, e.g. "0D1117".
    convenience init(hex: String, alpha: CGFloat = 1) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
