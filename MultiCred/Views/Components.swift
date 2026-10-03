import MultiCredCore
import SwiftUI

/// Rounded square in the profile color with its letter or SF Symbol
/// (menu bar icon, sidebar, editor header, HUD).
struct ProfileBadge: View {
    let icon: ProfileIcon
    let color: ProfileColor
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(content.foregroundStyle(.white))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch icon {
        case let .letter(letter):
            Text(String(letter.prefix(1)).uppercased())
                .font(.system(size: size * 0.55, weight: .semibold))
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size * 0.48, weight: .semibold))
        }
    }
}

extension Profile {
    var badgeLetter: String {
        if case let .letter(letter) = icon { return letter }
        return String(name.prefix(1))
    }
}

/// The eight profile colors as selectable circles (design 04).
struct ColorChooser: View {
    @Binding var selection: ProfileColor

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ProfileColor.allCases, id: \.self) { color in
                Circle()
                    .fill(color.color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selection == color ? 2.5 : 0).padding(-4))
                    .contentShape(Circle())
                    .onTapGesture { selection = color }
                    .accessibilityLabel(color.displayName)
                    .accessibilityAddTraits(selection == color ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Letter or one of the design's symbols.
struct IconChooser: View {
    @Binding var selection: ProfileIcon
    let letter: String
    let color: ProfileColor

    static let symbols = ["briefcase", "house", "building.2", "laptopcomputer", "star", "person", "flask", "globe"]

    var body: some View {
        HStack(spacing: 8) {
            option(.letter(String(letter.prefix(1)).uppercased()))
            ForEach(Self.symbols, id: \.self) { option(.symbol($0)) }
        }
    }

    private func option(_ icon: ProfileIcon) -> some View {
        let selected = isSelected(icon)
        return Group {
            switch icon {
            case let .letter(text): Text(text).font(.system(size: 13, weight: .semibold))
            case let .symbol(name): Image(systemName: name)
            }
        }
        .frame(width: 30, height: 30)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? color.color : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { selection = icon }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func isSelected(_ icon: ProfileIcon) -> Bool {
        switch (icon, selection) {
        case (.letter, .letter): true
        case let (.symbol(a), .symbol(b)): a == b
        default: false
        }
    }
}

/// Check / cross / warning / info circle used by Verify and onboarding.
struct StatusIcon24: View {
    let status: CheckItem.Status

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(color.opacity(0.15)))
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .ok: "checkmark"
        case .error: "xmark"
        case .warning: "exclamationmark"
        case .info: "info"
        }
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private var label: String {
        switch status {
        case .ok: "De acordo"
        case .error: "Problema"
        case .warning: "Atenção"
        case .info: "Informação"
        }
    }
}

/// Page header used by every section: title, optional subtitle, trailing action.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Explanatory note with a leading symbol (the "nenhum token passa pelo app" boxes).
struct InfoNote: View {
    let text: String
    var symbol = "shield"

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol) }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// Monospaced diff of one file: "+" lines green, "−" lines red.
struct FileChangeView: View {
    let change: FileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(change.path).font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(change.removedLines.enumerated()), id: \.offset) { _, line in
                    Text("− " + line).foregroundStyle(.red)
                }
                ForEach(Array(change.addedLines.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).foregroundStyle(.green)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }

    private var summary: String {
        switch change.kind {
        case .create: "arquivo novo"
        case .delete: "será apagado"
        case .modify:
            [change.addedLines.isEmpty ? nil : "+\(change.addedLines.count) linha(s)",
             change.removedLines.isEmpty ? nil : "−\(change.removedLines.count) linha(s)"]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}
