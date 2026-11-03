import AppKit
import QuartzCore

/// One Logo glyph's three masks from the asset catalog, which scripts/brand/make-assets writes:
/// the ink, the area that fills with the charge (a hairline short of every ink line), and the
/// charging glow. Each is alpha only; the icon tints them.
struct LogoGlyph {
    let outline: CGImage
    let liquid: CGImage
    let halo: CGImage
    /// The rows the liquid covers, as fractions of the glyph's height from its bottom. An empty
    /// liquid (the straw bolt's) spans nothing, so no level shows in it.
    let liquidSpan: ClosedRange<CGFloat>

    /// The halo mask's side over the glyph's, read off the masks make-assets wrote, so the two never drift.
    var haloRatio: CGFloat { CGFloat(halo.width) / CGFloat(outline.width) }

    private static let loaded: [MenuBarIconConfig.Glyph: LogoGlyph] = Dictionary(uniqueKeysWithValues:
        MenuBarIconConfig.Glyph.allCases.map { ($0, LogoGlyph($0)) })

    static func of(_ glyph: MenuBarIconConfig.Glyph) -> LogoGlyph { loaded[glyph]! }

    private init(_ glyph: MenuBarIconConfig.Glyph) {
        let stem = switch glyph {
        case .bottle: "bottle"
        case .orange: "orange"
        case .jar: "jar"
        case .strawBolt: "straw-bolt"
        case .glassRing: "glass-ring"
        }
        // [LAW:no-silent-failure] A mask missing from the build is a broken build, never a blank icon.
        func mask(_ part: String) -> CGImage {
            guard let image = NSImage(named: "glyph-\(stem)-\(part)")?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fatalError("the asset catalog has no glyph-\(stem)-\(part); run scripts/brand/make-assets")
            }
            return image
        }
        outline = mask("outline")
        liquid = mask("liquid")
        halo = mask("halo")
        liquidSpan = Self.span(of: liquid)
    }

    private static func span(of mask: CGImage) -> ClosedRange<CGFloat> {
        let (width, height) = (mask.width, mask.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height)
        // The buffer's first row is the image's top.
        let rows = (0..<height).filter { row in alpha[row * width..<(row + 1) * width].contains { $0 > 127 } }
        guard let top = rows.first, let bottom = rows.last else { return 0...0 }
        return CGFloat(height - 1 - bottom) / CGFloat(height)...CGFloat(height - top) / CGFloat(height)
    }
}

/// The charging glow behind a Logo glyph. It says "charging" and nothing else, so it is the same
/// at every charge: built from the glyph's whole silhouette, never from what is filled.
struct Halo: Equatable {
    let glyph: MenuBarIconConfig.Glyph
    let ink: MenuBarIcon.Ink
    /// The glow's side in points.
    let side: CGFloat

    /// White-yellow, warmer on a light bar where a pale glow would vanish.
    var color: NSColor {
        switch ink {
        case .light: NSColor(red: 1, green: 0xF3 / 255, blue: 0xB0 / 255, alpha: 1)
        case .dark: NSColor(red: 1, green: 0xD8 / 255, blue: 0x4D / 255, alpha: 1)
        }
    }

    var image: NSImage {
        let mask = LogoGlyph.of(glyph).halo
        let color = color
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGraphicsContext.current!.cgContext.paint(mask, color, in: rect)
            return true
        }
    }
}

/// How the halo breathes: only its opacity moves, so Core Animation composites it with no redraw.
/// Under Reduce Motion it holds still at a middle opacity.
enum HaloBreath: Equatable {
    case breathing, steady

    static let low: Float = 0.35, high: Float = 1, still: Float = 0.7
    /// Seconds for one way, low to high.
    static let duration: Double = 4.2
    /// A sine-like ease, cubic-bezier(.37, 0, .63, 1).
    static let curve = (0.37, 0.0, 0.63, 1.0)

    init(reduceMotion: Bool) { self = reduceMotion ? .steady : .breathing }

    static let key = "breath"

    /// Sets the layer breathing or still. The same two lines run either way; the case decides what they hold.
    func apply(to layer: CALayer) {
        layer.opacity = self == .breathing ? Self.low : Self.still
        layer.removeAnimation(forKey: Self.key)
        animation.map { layer.add($0, forKey: Self.key) }
    }

    var animation: CABasicAnimation? {
        guard self == .breathing else { return nil }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = Self.low
        breath.toValue = Self.high
        breath.duration = Self.duration
        breath.autoreverses = true
        breath.repeatCount = .infinity
        let (x1, y1, x2, y2) = Self.curve
        breath.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        return breath
    }
}

extension CGContext {
    /// Paints `color` wherever the alpha mask is opaque, within `clip`: the mask's shape in one colour.
    func paint(_ mask: CGImage, _ color: NSColor, in rect: CGRect, clip: CGRect? = nil) {
        saveGState()
        self.clip(to: clip ?? rect)
        beginTransparencyLayer(auxiliaryInfo: nil)
        draw(mask, in: rect)
        setBlendMode(.sourceIn)
        setFillColor(color.cgColor)
        fill(rect)
        endTransparencyLayer()
        restoreGState()
    }
}
