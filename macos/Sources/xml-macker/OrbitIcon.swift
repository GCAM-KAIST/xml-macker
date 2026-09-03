import Cocoa

// The Orbit toolbar mark (Icon Set sheet, variant C: two levels of
// nesting, a planet with two rings and three children in orbit).
// Drawn in code rather than loaded from the SVG: crisp at every
// toolbar size and zoom, and no resource plumbing. Colors are the
// sheet's oklch values converted to sRGB.
enum OrbitIcon {
    private static let ring    = NSColor(srgbRed: 0.60, green: 0.66, blue: 0.80, alpha: 1)
    private static let planet  = NSColor(srgbRed: 0.25, green: 0.40, blue: 0.78, alpha: 1)
    private static let orange  = NSColor(srgbRed: 0.92, green: 0.51, blue: 0.29, alpha: 1)
    private static let teal    = NSColor(srgbRed: 0.24, green: 0.67, blue: 0.57, alpha: 1)
    private static let purple  = NSColor(srgbRed: 0.70, green: 0.39, blue: 0.75, alpha: 1)

    static func image(pointSize: CGFloat = 20) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size, flipped: true) { rect in
            let s = rect.width / 24          // the sheet is on a 24-unit grid
            func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: (cx - r) * s, y: (cy - r) * s,
                                            width: 2 * r * s, height: 2 * r * s))
            }
            ring.setStroke()
            for radius in [5.6, 10.0] as [CGFloat] {
                let p = disc(12, 12, radius)
                p.lineWidth = max(1, 1.4 * s)
                p.stroke()
            }
            planet.setFill(); disc(12, 12, 3.1).fill()
            orange.setFill(); disc(12, 6.4, 1.7).fill()
            teal.setFill();   disc(4.9, 16.1, 1.8).fill()
            purple.setFill(); disc(19.8, 9, 1.6).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Orbit"
        return img
    }
}
