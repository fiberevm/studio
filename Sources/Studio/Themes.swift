import AppKit
import SwiftTerm

/// A color theme for both the app chrome and the terminal. Values approximate the VS Code themes they're named after.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isLight: Bool
    let background: NSColor   // terminal / editor area and active tab
    let chrome: NSColor       // sidebar, tab bar, title bar
    let foreground: NSColor
    let selection: NSColor    // terminal text selection
    let listSelection: NSColor // sidebar selected row
    let border: NSColor
    let accent: NSColor       // active tab top line, palette highlight
    let cursor: NSColor
    let ansi: [NSColor]       // 16 colors: normal 0-7, bright 8-15

    static func == (a: AppTheme, b: AppTheme) -> Bool { a.id == b.id }
}

private func hex(_ s: String, _ alpha: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}
private func pal(_ l: [String]) -> [NSColor] { l.map { hex($0) } }

private let vscodeTerminalDark = pal(["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                                      "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#E5E5E5"])

extension AppTheme {
    static let all: [AppTheme] = [clearDark, darkModern, darkPlus, lightPlus, monokai, solarizedDark, oneDarkPro, githubDark, dracula]

    static let clearDark = AppTheme(
        id: "clear-dark", name: "Clear Dark (Terminal.app)", isLight: false,
        background: hex("#212734"), chrome: hex("#191D27"), foreground: hex("#E6E6E6"),
        selection: hex("#334E5E"), listSelection: hex("#334E5E"), border: NSColor(white: 1, alpha: 0.08),
        accent: hex("#4A9EFF"), cursor: hex("#D97857"),
        ansi: pal(["#35424B", "#B4564A", "#6CAA71", "#C4AC62", "#6D96B4", "#BD7BCD", "#7CCBCD", "#DDE5EB",
                   "#465D6C", "#DF6C5A", "#79BD7D", "#E5C872", "#67B5ED", "#D389E5", "#84DDE0", "#E6EEF5"]))

    static let darkModern = AppTheme(
        id: "dark-modern", name: "Dark Modern", isLight: false,
        background: hex("#1F1F1F"), chrome: hex("#181818"), foreground: hex("#CCCCCC"),
        selection: hex("#264F78"), listSelection: hex("#37373D"), border: hex("#2B2B2B"),
        accent: hex("#0078D4"), cursor: hex("#AEAFAD"), ansi: vscodeTerminalDark)

    static let darkPlus = AppTheme(
        id: "dark-plus", name: "Dark+", isLight: false,
        background: hex("#1E1E1E"), chrome: hex("#252526"), foreground: hex("#CCCCCC"),
        selection: hex("#264F78"), listSelection: hex("#37373D"), border: hex("#3C3C3C"),
        accent: hex("#007ACC"), cursor: hex("#AEAFAD"), ansi: vscodeTerminalDark)

    static let lightPlus = AppTheme(
        id: "light-plus", name: "Light+", isLight: true,
        background: hex("#FFFFFF"), chrome: hex("#F3F3F3"), foreground: hex("#333333"),
        selection: hex("#ADD6FF"), listSelection: hex("#E4E6F1"), border: hex("#E5E5E5"),
        accent: hex("#005FB8"), cursor: hex("#000000"),
        ansi: pal(["#000000", "#CD3131", "#00BC00", "#949800", "#0451A5", "#BC05BC", "#0598BC", "#555555",
                   "#666666", "#CD3131", "#14CE14", "#B5BA00", "#0451A5", "#BC05BC", "#0598BC", "#A5A5A5"]))

    static let monokai = AppTheme(
        id: "monokai", name: "Monokai", isLight: false,
        background: hex("#272822"), chrome: hex("#1E1F1C"), foreground: hex("#F8F8F2"),
        selection: hex("#49483E"), listSelection: hex("#414339"), border: hex("#414339"),
        accent: hex("#F92672"), cursor: hex("#F8F8F0"),
        ansi: pal(["#333333", "#C4265E", "#86B42B", "#B3B42B", "#6A7EC8", "#8C6BC8", "#56ADBC", "#E3E3DD",
                   "#666666", "#F92672", "#A6E22E", "#E2E22E", "#819AFF", "#AE81FF", "#66D9EF", "#F8F8F2"]))

    static let solarizedDark = AppTheme(
        id: "solarized-dark", name: "Solarized Dark", isLight: false,
        background: hex("#002B36"), chrome: hex("#00212B"), foreground: hex("#93A1A1"),
        selection: hex("#274642"), listSelection: hex("#005A6F"), border: hex("#073642"),
        accent: hex("#268BD2"), cursor: hex("#D30102"),
        ansi: pal(["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                   "#586E75", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]))

    static let oneDarkPro = AppTheme(
        id: "one-dark-pro", name: "One Dark Pro", isLight: false,
        background: hex("#282C34"), chrome: hex("#21252B"), foreground: hex("#ABB2BF"),
        selection: hex("#3E4451"), listSelection: hex("#2C313A"), border: hex("#181A1F"),
        accent: hex("#528BFF"), cursor: hex("#528BFF"),
        ansi: pal(["#3F4451", "#E05561", "#8CC265", "#D18F52", "#4AA5F0", "#C162DE", "#42B3C2", "#D7DAE0",
                   "#4F5666", "#FF616E", "#A5E075", "#F0A45D", "#4DC4FF", "#DE73FF", "#4CD1E0", "#E6E6E6"]))

    static let githubDark = AppTheme(
        id: "github-dark", name: "GitHub Dark", isLight: false,
        background: hex("#0D1117"), chrome: hex("#010409"), foreground: hex("#E6EDF3"),
        selection: hex("#264F78"), listSelection: hex("#21262D"), border: hex("#30363D"),
        accent: hex("#F78166"), cursor: hex("#2F81F7"),
        ansi: pal(["#484F58", "#FF7B72", "#3FB950", "#D29922", "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
                   "#6E7681", "#FFA198", "#56D364", "#E3B341", "#79C0FF", "#D2A8FF", "#56D4DD", "#FFFFFF"]))

    static let dracula = AppTheme(
        id: "dracula", name: "Dracula", isLight: false,
        background: hex("#282A36"), chrome: hex("#21222C"), foreground: hex("#F8F8F2"),
        selection: hex("#44475A"), listSelection: hex("#44475A"), border: hex("#191A21"),
        accent: hex("#BD93F9"), cursor: hex("#F8F8F2"),
        ansi: pal(["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                   "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]))
}

/// Published when the theme switches, for small views whose inputs never change otherwise (SwiftUI would
/// keep their first color).
@MainActor
final class ThemeChanges: ObservableObject {
    static let shared = ThemeChanges()
    func changed() { objectWillChange.send() }
}

/// The active theme. Views read these statics; SessionStore publishes a change when the theme switches.
@MainActor
enum Theme {
    static var current: AppTheme = {
        let id = UserDefaults.standard.string(forKey: "theme")
        return AppTheme.all.first { $0.id == id } ?? .clearDark
    }()

    static var background: NSColor { current.background }
    static var chrome: NSColor { current.chrome }
    static var foreground: NSColor { current.foreground }
    static var selection: NSColor { current.listSelection }
    static var border: NSColor { current.border }
    static var accent: NSColor { current.accent }
    /// Pane separator: the theme's text color mixed into its background, so it shows on every theme.
    static var paneDivider: NSColor {
        let bg = current.background.usingColorSpace(.sRGB) ?? current.background
        return bg.blended(withFraction: 0.2, of: current.foreground.usingColorSpace(.sRGB) ?? .gray) ?? current.border
    }

    static func font(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func apply(to view: LocalProcessTerminalView, fontSize: CGFloat) {
        let t = current
        view.font = font(fontSize)
        view.nativeBackgroundColor = t.background
        view.nativeForegroundColor = t.foreground
        view.selectedTextBackgroundColor = t.selection
        view.caretColor = t.cursor
        view.optionAsMetaKey = true
        view.installColors(t.ansi.map { c in
            let c = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        })
        view.needsDisplay = true
    }
}
