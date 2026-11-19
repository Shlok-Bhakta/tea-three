import SwiftUI

/// Color tokens lifted from T3 Code's mobile themes
/// (apps/mobile/generated-uniwind-themes.css), so Tea Three looks like it
/// belongs next to the official app.
struct Theme {
    var screen: Color
    var card: Color
    var groupedCard: Color
    var composerSurface: Color
    var composerBorder: Color
    var foreground: Color
    var foregroundSecondary: Color
    var border: Color
    var primary: Color
    var primaryForeground: Color
    var primaryText: Color
    var userBubble: Color
    var userBubbleForeground: Color
}

enum ThemeName: String, CaseIterable, Identifiable {
    case t3Chat = "t3-chat"
    case iris

    var id: String { rawValue }

    var title: String {
        switch self {
        case .t3Chat: "T3 Chat"
        case .iris: "Iris"
        }
    }

    func theme(for scheme: ColorScheme) -> Theme {
        switch (self, scheme) {
        case (.t3Chat, .dark):
            Theme(
                screen: Color(hex: 0x1F1A24), card: Color(hex: 0x29232D), groupedCard: Color(hex: 0x29232D),
                composerSurface: Color(hex: 0x29232D, opacity: 0.9), composerBorder: Color(hex: 0x27242C, opacity: 0.46),
                foreground: Color(hex: 0xF9F8FB), foregroundSecondary: Color(hex: 0xE7D0DD, opacity: 0.72),
                border: Color(hex: 0x27242C), primary: Color(hex: 0xA3004C), primaryForeground: Color(hex: 0xFBD0E8),
                primaryText: Color(hex: 0xD07EA4), userBubble: Color(hex: 0x2B2431), userBubbleForeground: Color(hex: 0xF2EBFA)
            )
        case (.t3Chat, _):
            Theme(
                screen: Color(hex: 0xFDF7FD), card: Color(hex: 0xFAF3FB), groupedCard: Color(hex: 0xF3E6F5),
                composerSurface: Color(hex: 0xF3E6F5, opacity: 0.94), composerBorder: Color(hex: 0xEEE1ED, opacity: 0.8),
                foreground: Color(hex: 0x501854), foregroundSecondary: Color(hex: 0xAB1668),
                border: Color(hex: 0xEEE1ED), primary: Color(hex: 0xDB2777), primaryForeground: .white,
                primaryText: Color(hex: 0xAA1E5D), userBubble: Color(hex: 0xF7DEF2), userBubbleForeground: Color(hex: 0x492C61)
            )
        case (.iris, .dark):
            Theme(
                screen: Color(hex: 0x1D1929), card: Color(hex: 0x1D1929), groupedCard: Color(hex: 0x2D2643),
                composerSurface: Color(hex: 0x2D2643, opacity: 0.9), composerBorder: Color(hex: 0x4D4366, opacity: 0.8),
                foreground: Color(hex: 0xFFFAFF), foregroundSecondary: Color(hex: 0xA09DA6),
                border: Color(hex: 0x4D4366), primary: Color(hex: 0xF099D8), primaryForeground: Color(hex: 0x241523),
                primaryText: Color(hex: 0xF099D8), userBubble: Color(hex: 0x4B3D72), userBubbleForeground: Color(hex: 0xFFFAFF)
            )
        case (.iris, _):
            Theme(
                screen: Color(hex: 0xF8F7F9), card: Color(hex: 0xF8F7F9), groupedCard: Color(hex: 0xF0EDF6),
                composerSurface: Color(hex: 0xF0EDF6, opacity: 0.94), composerBorder: Color(hex: 0xD6D1DE, opacity: 0.8),
                foreground: Color(hex: 0x241523), foregroundSecondary: Color(hex: 0x716871),
                border: Color(hex: 0xD6D1DE), primary: Color(hex: 0xA82C87), primaryForeground: Color(hex: 0xFFFAFF),
                primaryText: Color(hex: 0xA82C87), userBubble: Color(hex: 0xE0D9EE), userBubbleForeground: Color(hex: 0x241523)
            )
        }
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = ThemeName.t3Chat.theme(for: .dark)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Applies the chosen T3 theme to everything below it.
struct Themed: ViewModifier {
    @AppStorage("theme") private var themeName = ThemeName.t3Chat.rawValue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = (ThemeName(rawValue: themeName) ?? .t3Chat).theme(for: scheme)
        content
            .environment(\.theme, theme)
            .tint(theme.primaryText)
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}

/// The screen background: the theme's canvas with a soft primary glow up top,
/// like T3 Chat's.
struct ThemeBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.screen
            RadialGradient(colors: [theme.primary.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
