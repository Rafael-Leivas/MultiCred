import AppKit

/// Menu bar icon: a rounded square in the profile color with a white letter.
/// Not a template image, because the color identifies the active profile.
enum StatusIcon {
    static func image(letter: String, color: NSColor, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let square = rect.insetBy(dx: 1, dy: 1)
            color.setFill()
            NSBezierPath(roundedRect: square, xRadius: 4, yRadius: 4).fill()

            let font = NSFont.systemFont(ofSize: size * 0.62, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: String(letter.prefix(1)).uppercased(), attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: square.midX - textSize.width / 2, y: square.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "MultiCred"
        return image
    }
}
