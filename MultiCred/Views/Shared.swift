import MultiCredCore
import SwiftUI

extension ProfileColor {
    var color: Color {
        let hex = String(self.hex.dropFirst())
        let value = UInt64(hex, radix: 16) ?? 0
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var displayName: String {
        switch self {
        case .indigo: "Índigo"
        case .blue: "Azul"
        case .teal: "Verde-azulado"
        case .green: "Verde"
        case .orange: "Laranja"
        case .red: "Vermelho"
        case .pink: "Rosa"
        case .graphite: "Grafite"
        }
    }
}

/// Colored circle with the first letter (account avatars in designs 03 and 05).
struct AccountAvatar: View {
    let name: String
    let color: ProfileColor
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel("\(name), cor \(color.displayName)")
    }
}

enum PillTone { case ok, warning, error, neutral }

/// Status pill: dot + text, never color alone.
struct StatusPill: View {
    let text: String
    let tone: PillTone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(foreground).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(foreground.opacity(0.15)))
    }

    private var foreground: Color {
        switch tone {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

extension ClaudeLoginStatus {
    var pill: (String, PillTone) {
        switch self {
        case .loggedIn: ("Conectada", .ok)
        case .loggedOut: ("Precisa entrar", .warning)
        case .unknown: ("Status indisponível", .neutral)
        }
    }
}

/// Banner shown in every window while the app runs in test mode.
struct TestModeBanner: View {
    var body: some View {
        Label("MODO DE TESTE: nada no seu Mac é alterado", systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.12))
    }
}
