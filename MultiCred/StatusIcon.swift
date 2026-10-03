import AppKit
import MultiCredCore

/// Menu bar icon: a rounded square in the profile color with its letter or
/// symbol in white. Not a template image, because the color identifies the
/// active profile. An orange dot marks an inconsistent state.
enum StatusIcon {
    static func image(letter: String, color: NSColor, size: CGFloat = 18, alert: Bool = false) -> NSImage {
        draw(color: color, size: size, alert: alert) { square in
            let font = NSFont.systemFont(ofSize: size * 0.62, weight: .bold)
            let text = NSAttributedString(string: String(letter.prefix(1)).uppercased(), attributes: [.font: font, .foregroundColor: NSColor.white])
            let textSize = text.size()
            text.draw(at: NSPoint(x: square.midX - textSize.width / 2, y: square.midY - textSize.height / 2))
        }
    }

    static func image(for profile: Profile, size: CGFloat = 18, alert: Bool = false) -> NSImage {
        let color = NSColor(hex: profile.color.hex)
        switch profile.icon {
        case let .letter(letter):
            return image(letter: letter, color: color, size: size, alert: alert)
        case let .symbol(name):
            return draw(color: color, size: size, alert: alert) { square in
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
                    .applying(.init(paletteColors: [.white]))
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(x: square.midX - symbolSize.width / 2, y: square.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
            }
        }
    }

    private static func draw(color: NSColor, size: CGFloat, alert: Bool, content: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let square = rect.insetBy(dx: 1, dy: 1)
            color.setFill()
            NSBezierPath(roundedRect: square, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            content(square)
            if alert {
                let dot = NSRect(x: rect.maxX - size * 0.38, y: rect.maxY - size * 0.38, width: size * 0.38, height: size * 0.38)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "MultiCred"
        return image
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
