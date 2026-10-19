import AppKit

extension BatteryIndicator {
    static let canvas = NSSize(width: 28, height: 14)
    /// The area inside the outline that the charge fills.
    static let interior = NSRect(x: 2, y: 3, width: 21, height: 8)

    /// The status item's image. It draws when it is shown, not when it is made, so the outline
    /// and the unfilled digits take the colour of the menu bar they land in, light or dark.
    ///
    /// Neutral is a template: only its shape matters and the menu bar tints it, so the digits
    /// over the fill are cut out of it. A tinted image keeps its colour and prints white
    /// digits on the fill.
    var image: NSImage {
        let image = NSImage(size: Self.canvas, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = tint == .neutral
        return image
    }

    private var color: NSColor {
        switch tint {
        case .neutral: .labelColor
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    private func draw() {
        let interior = Self.interior
        let outline = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 1.5, width: 24, height: 11), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        outline.stroke()
        NSColor.labelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25.5, y: 4.5, width: 1.5, height: 5), xRadius: 0.75, yRadius: 0.75).fill()

        let body = NSBezierPath(roundedRect: interior, xRadius: 2, yRadius: 2)
        let filled = NSRect(x: interior.minX, y: interior.minY, width: interior.width * fill, height: interior.height)
        let digits = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ])
        let at = NSPoint(x: interior.midX - digits.size().width / 2, y: interior.midY - digits.size().height / 2)

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSBezierPath(rect: filled).addClip()
        color.setFill()
        body.fill()
        // Over the fill: cut out of a template, white on a colour.
        if tint == .neutral {
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            digits.draw(at: at)
        } else {
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white,
            ]).draw(at: at)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSBezierPath(rect: NSRect(x: filled.maxX, y: interior.minY, width: interior.maxX - filled.maxX, height: interior.height)).addClip()
        digits.draw(at: at)
        NSGraphicsContext.restoreGraphicsState()
    }
}
