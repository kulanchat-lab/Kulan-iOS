import SwiftUI

// Design tokens ported from the RN colors.ts (one deep-contrast theme for both modes).
extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

// App-wide appearance override (persisted in UserDefaults via @AppStorage).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    static func bg(_ dark: Bool) -> Color { dark ? Color(hex: 0x121214) : Color(hex: 0xFFFFFF) }
    static func bgSecondary(_ dark: Bool) -> Color { dark ? Color(hex: 0x121214) : Color(hex: 0xF2F2F7) }
    static func card(_ dark: Bool) -> Color { dark ? Color(hex: 0x26262B) : Color(hex: 0xFFFFFF) }
    static func received(_ dark: Bool) -> Color { dark ? Color(hex: 0x26262B) : Color(hex: 0xE9E9EB) }
    static func accent(_ dark: Bool) -> Color { dark ? .white : .black }
    static func onAccent(_ dark: Bool) -> Color { dark ? .black : .white }
    static let secondary = Color(hex: 0x8E8E93)
}

enum AvatarPalette {
    static let gradients: [[Color]] = [
        [Color(hex: 0x2563EB), Color(hex: 0x3B82F6)],
        [Color(hex: 0x7C3AED), Color(hex: 0x8B5CF6)],
        [Color(hex: 0xEC4899), Color(hex: 0xF43F5E)],
        [Color(hex: 0x059669), Color(hex: 0x10B981)],
        [Color(hex: 0xD97706), Color(hex: 0xF59E0B)],
        [Color(hex: 0xDC2626), Color(hex: 0xEF4444)],
        [Color(hex: 0x0891B2), Color(hex: 0x06B6D4)],
        [Color(hex: 0x4F46E5), Color(hex: 0x6366F1)],
    ]
    static func gradient(for name: String) -> [Color] {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return gradients[0] }
        var h = 0
        for ch in clean.unicodeScalars { h = (h &* 31 &+ Int(ch.value)) & 0x7fffffff }
        return gradients[h % gradients.count]
    }
}

extension View {
    /// Real iOS 26 Liquid Glass when available; frosted material fallback below it.
    @ViewBuilder
    func liquidGlass(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct AvatarView: View {
    let name: String
    var photoUrl: String?
    var size: CGFloat = 48

    private var hasPhoto: Bool { (photoUrl?.isEmpty == false) }
    private var initial: String {
        let c = name.trimmingCharacters(in: .whitespaces).first
        return c.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Group {
            if hasPhoto, let url = URL(string: photoUrl!) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallback: some View {
        LinearGradient(colors: AvatarPalette.gradient(for: name), startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white))
    }
}
