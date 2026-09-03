import Cocoa

// Single source of truth for the Aurora Liquid Glass design system.
// Do not hard-code colors, fonts or spacings anywhere else, pull them
// from these enums.

// Color tokens, each now reads from ThemeManager.current so the
// whole palette swaps when MainWindowController calls
// ThemeManager.select(_:) and broadcasts rebuildColors(). Shape of
// the API is unchanged: call sites keep saying XMColor.bg etc.
enum XMColor {
    // Surfaces
    static var bg:          NSColor { ThemeManager.current.bg }
    static var bgDeep:      NSColor { ThemeManager.current.bgDeep }
    static var panel:       NSColor { ThemeManager.current.panel }
    static var hairline:    NSColor { ThemeManager.current.hairline }
    static var hairlineS:   NSColor { ThemeManager.current.hairlineS }
    static var glassTop:    NSColor { ThemeManager.current.glassTop }

    // Text
    static var text:        NSColor { ThemeManager.current.text }
    static var text2:       NSColor { ThemeManager.current.text2 }
    static var text3:       NSColor { ThemeManager.current.text3 }

    // Syntax
    static var syntaxTag:   NSColor { ThemeManager.current.syntaxTag }
    static var syntaxAttr:  NSColor { ThemeManager.current.syntaxAttr }
    static var syntaxVal:   NSColor { ThemeManager.current.syntaxVal }
    static var syntaxText:  NSColor { ThemeManager.current.syntaxText }
    static var syntaxPunct: NSColor { ThemeManager.current.syntaxPunct }
    static var syntaxCom:   NSColor { ThemeManager.current.syntaxCom }

    // Accents
    static var lineHighlight: NSColor { ThemeManager.current.lineHighlight }
    static var accent:      NSColor { ThemeManager.current.accent }
    static var accent2:     NSColor { ThemeManager.current.accent2 }
    static var ok:          NSColor { ThemeManager.current.ok }
    static var warn:        NSColor { ThemeManager.current.warn }
    static var err:         NSColor { ThemeManager.current.err }
}

enum XMFont {
    // Global zoom multiplier, driven by the Excel-style zoom slider
    // in the bottom status bar. EVERY font helper below multiplies its
    // point size by globalScale so changing one knob rescales the
    // whole app's typography. Views that cached an NSFont at init
    // need to re-query after the slider moves; MainWindowController
    // broadcasts a rebuildFonts() to each VC on slider change.
    // Clamped 0.5…2.0 by the slider widget.
    /// The zoom the app starts at and returns to. 75 percent, not 100:
    /// the panes are dense, and at 100 the six of them left too little
    /// room for the file itself.
    static let defaultScale: CGFloat = 0.75
    static var globalScale: CGFloat = XMFont.defaultScale
    private static func scaled(_ size: CGFloat) -> CGFloat {
        // Round to .5 pt so text stays crisp (half-integer point sizes
        // are fine for system fonts on Retina; avoid fractional values
        // like 12.37 that can cause subpixel drift).
        let s = max(5, min(40, size * globalScale))
        return (s * 2).rounded() / 2
    }

    // UI, SF Pro Text (default system font on macOS)
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        return .systemFont(ofSize: scaled(size), weight: weight)
    }
    // Code, SF Mono
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        return .monospacedSystemFont(ofSize: scaled(size), weight: weight)
    }
    // Display numbers, SF Pro Display (same family, fallback to system)
    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        let s = scaled(size)
        if let f = NSFont(name: "SF Pro Display", size: s) {
            return f
        }
        return .systemFont(ofSize: s, weight: weight)
    }
    // Helpers for common sizes
    static var uiSmall:   NSFont { ui(11, .medium) }
    static var uiBody:    NSFont { ui(12, .medium) }
    static var uiBodyB:   NSFont { ui(12, .semibold) }
    static var uiHeader:  NSFont { ui(13, .semibold) }
    static var uiLarge:   NSFont { ui(15, .semibold) }
    static var uiCaption: NSFont { ui(10, .medium) }
    static var monoCode:  NSFont { mono(12, .regular) }
    static var monoSmall: NSFont { mono(11, .regular) }
}

enum XMMetric {
    // Scaled metric helper, multiplies the given layout size by the
    // same global slider (XMFont.globalScale) that drives type. Row
    // heights, pane-header heights, chart heights, minimap width,
    // status-bar heights all flow through this so a 73% slider value
    // both shrinks text AND tightens layout → more content fits on
    // small MacBook-built-in displays. Rounded to the nearest 0.5 pt
    // for crisp hairlines.
    static func s(_ base: CGFloat) -> CGFloat {
        let v = max(4, base * XMFont.globalScale)
        return (v * 2).rounded() / 2
    }

    // Corners
    static let radiusWindow: CGFloat = 18
    static let radiusCard:   CGFloat = 14
    static let radiusPill:   CGFloat = 10
    static let radiusGlass:  CGFloat = 12

    // Strokes
    static let hairline:     CGFloat = 0.5

    // Layout
    static let treeRowH:     CGFloat = 22
    static let treeIndent:   CGFloat = 14
    static let sourceLineH:  CGFloat = 18
    static let lineGutterW:  CGFloat = 42
    static let minimapW:     CGFloat = 68
    static let tabStripH:    CGFloat = 32
    static let breadcrumbH:  CGFloat = 32
    static let paneGap:      CGFloat = 8

    // Split-view initial/min widths. Minimums tuned for 1280-wide
    // MacBook displays (14" built-in) where the earlier 200/280 mins
    // left no room for the source column + squeezed pane headers
    // off-screen.
    static let treePaneDefault:      CGFloat = 260
    static let inspectorPaneDefault: CGFloat = 320
    static let treePaneMin:          CGFloat = 140
    static let inspectorPaneMin:     CGFloat = 220

    // Inspector cards
    static let inspectorPadding:  CGFloat = 10
    static let inspectorGap:      CGFloat = 10
}

// Glass-panel configuration, tint/strength/radius combined. Used by
// GlassPanel.swift to build the NSVisualEffectView stack consistently.
struct GlassConfig {
    var tint: NSColor? = nil                 // optional color wash over the blur
    var tintAlpha: CGFloat = 0.0
    var radius: CGFloat = XMMetric.radiusCard
    var border: NSColor = XMColor.hairlineS
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var showInsetHighlight: Bool = true
}

// NSColor hex initializer, small convenience since Aurora spec uses
// hex codes pervasively. Alpha defaults to 1.0.
extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:    CGFloat( hex        & 0xFF) / 255.0,
            alpha:   alpha
        )
    }
}
