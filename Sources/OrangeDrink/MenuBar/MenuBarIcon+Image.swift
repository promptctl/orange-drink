import AppKit

extension MenuBarIcon {
    private static let height: CGFloat = 14
    private static let bodyWidth: CGFloat = 28
    private static let gap: CGFloat = 3
    /// The area inside the indicator's outline that the charge fills.
    static let interior = NSRect(x: 2, y: 3, width: 21, height: 8)

    private var ink: (glyph: NSColor, contrast: NSColor) {
        switch color {
        case .light: (.white, .black)
        case .dark: (.black, .white)
        }
    }

    var text: NSAttributedString? {
        guard let string = battery?.text else { return nil }
        let points: CGFloat = switch shape {
        case .indicator: 8
        case .minimal: 11
        case .logo: 0
        }
        func set(_ points: CGFloat) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: points, weight: .bold), .foregroundColor: ink.glyph,
            ])
        }
        // Text inside the outline shrinks to fit it: "10:30" is wider than the charge area at 8pt.
        guard case .indicator = shape else { return set(points) }
        let candidates = stride(from: points, through: 5, by: -0.5).lazy.map(set)
        return candidates.first { $0.size().width <= Self.interior.width } ?? set(5)
    }

    /// Where the battery outline starts: after the text that sits beside it, if any.
    private var bodyOrigin: CGFloat {
        guard case .minimal = shape, let text else { return 0 }
        return text.size().width.rounded(.up) + Self.gap
    }

    private var canvas: NSSize {
        switch shape {
        case .logo: NSSize(width: Self.height, height: Self.height)
        case .indicator, .minimal: NSSize(width: bodyOrigin + Self.bodyWidth, height: Self.height)
        }
    }

    /// The status item's image. It draws when shown, at the size chosen. The colour is the
    /// glyph's own, so it is never a template: the menu bar does not retint it.
    var image: NSImage {
        let scale = size.scale
        return NSImage(size: NSSize(width: canvas.width * scale, height: canvas.height * scale), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()
            draw()
            return true
        }
    }

    private func draw() {
        switch shape {
        case .logo: drawLogo()
        case .indicator(let battery): drawBattery(battery, digitsInside: true)
        case .minimal(let battery): drawBattery(battery, digitsInside: false)
        }
    }

    private func drawLogo() {
        let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [ink.glyph]))!
        symbol.draw(in: NSRect(origin: .zero, size: canvas))
    }

    private func drawBattery(_ battery: BatteryIndicator, digitsInside: Bool) {
        let origin = bodyOrigin
        if !digitsInside, let text {
            text.draw(at: NSPoint(x: 0, y: (Self.height - text.size().height) / 2))
        }
        let shift = NSAffineTransform()
        shift.translateX(by: origin, yBy: 0)
        shift.concat()

        let outline = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 1.5, width: 24, height: 11), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        ink.glyph.withAlphaComponent(0.6).setStroke()
        outline.stroke()
        ink.glyph.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25.5, y: 4.5, width: 1.5, height: 5), xRadius: 0.75, yRadius: 0.75).fill()

        let interior = Self.interior
        let body = NSBezierPath(roundedRect: interior, xRadius: 2, yRadius: 2)
        let filled = NSRect(x: interior.minX, y: interior.minY, width: interior.width * battery.fill, height: interior.height)
        let fillColor: NSColor = switch battery.tint {
        case .neutral: ink.glyph
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        }
        // White digits stay legible on any tint; a neutral fill is the glyph's own colour, so its
        // digits take the opposite one.
        let onFill = battery.tint == .neutral ? ink.contrast : .white

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        fillColor.setFill()
        filled.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard digitsInside, let digits = text else { return }
        let at = NSPoint(x: interior.midX - digits.size().width / 2, y: interior.midY - digits.size().height / 2)
        for (region, colour) in [
            (filled, onFill),
            (NSRect(x: filled.maxX, y: interior.minY, width: interior.maxX - filled.maxX, height: interior.height), ink.glyph),
        ] {
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSBezierPath(rect: region).addClip()
            let recoloured = NSMutableAttributedString(attributedString: digits)
            recoloured.addAttribute(.foregroundColor, value: colour, range: NSRange(location: 0, length: recoloured.length))
            recoloured.draw(at: at)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
