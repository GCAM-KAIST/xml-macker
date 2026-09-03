import Cocoa

// Theme = the full set of color tokens the UI is built from.
// XMColor's statics read from `Theme.current`, so swapping the
// current theme rewrites every color across the app in one step.
//
// Some NSLayers cache `cgColor` values at construction time (e.g.
// `layer?.backgroundColor = XMColor.bg.cgColor`). Those caches do
// NOT auto-update on a theme switch, so every view that caches a
// cgColor exposes a `rebuildColors()` method. MainWindowController
// broadcasts it right after swapping themes, the same way it
// broadcasts `rebuildFonts()` for the zoom slider.
//
// NSAppearance (darkAqua / aqua) is also flipped to match, so the
// traffic-light buttons and vibrant NSVisualEffectView blurs
// follow the theme without manual work.

struct Theme: Equatable {
    // Identity, persisted in UserDefaults so the last-used theme
    // restores on next launch.
    let id: String
    let displayName: String
    let isDark: Bool

    // Surfaces
    let bg: NSColor
    let bgDeep: NSColor
    let panel: NSColor
    let hairline: NSColor
    let hairlineS: NSColor
    let glassTop: NSColor

    // Text
    let text: NSColor
    let text2: NSColor
    let text3: NSColor

    // Syntax (XML-specific: tag names, attribute names, attribute
    // values, element text, punctuation, comments).
    let syntaxTag: NSColor
    let syntaxAttr: NSColor
    let syntaxVal: NSColor
    let syntaxText: NSColor
    let syntaxPunct: NSColor
    let syntaxCom: NSColor

    // Accents
    let accent: NSColor
    let accent2: NSColor
    let ok: NSColor
    let warn: NSColor
    let err: NSColor

    // Editor landing-line band + text-selection background. Each
    // theme picks the muted "editor selection" color famous editors
    // use (VS Code #264F78, One Dark #3E4451, Dracula #44475A…)
    // instead of a loud full-strength accent, which made the band
    // read as a stray highlight rather than a selection.
    let lineHighlight: NSColor

    // Native appearance applied to NSWindow.appearance so traffic
    // lights + NSVisualEffectView vibrancy match.
    // Non-optional on purpose. Assigning nil to NSWindow.appearance does
    // not mean "leave it alone", it means "follow the system", and that
    // silent fallback is how a dark theme ended up with the system's light
    // title glyphs painted on its own near-black titlebar.
    var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
            ?? NSAppearance(named: .darkAqua)
            ?? NSAppearance.currentDrawing()
    }

    // NSVisualEffectView material used inside every GlassPanel. The
    // original dark UI used `.hudWindow` (a dark HUD style that stays
    // dark regardless of appearance). Under Light we switch to
    // `.contentBackground`, which adapts to the window's appearance
    // and gives the bright white/off-white surface the user expects
    // when the theme says "Light".
    var glassMaterial: NSVisualEffectView.Material {
        isDark ? .hudWindow : .contentBackground
    }

    // No theme blurs the desktop behind the window any more.
    //
    // The blur was the reason the themes looked like they were not
    // working at all. An NSVisualEffectView set to .behindWindow
    // composites against the WALLPAPER, not against anything the app
    // painted, so every pane rendered as the same system grey no matter
    // which palette was selected, and the contrast of the text on it
    // changed with the desktop picture. Hacker's near-black #020A05
    // arrived on screen roughly ten times lighter than it should be.
    //
    // Keeping the blur for the default theme only would have left that
    // wallpaper dependence in the theme most people see, and macOS's own
    // Reduce Transparency setting replaces the material with a flat grey
    // regardless of the palette. So every theme now paints its own
    // surface. The look survives: the panel is still lifted off the
    // window ground, still has its top gloss and its hairline border.
    var usesVibrancy: Bool { false }

    // `panel` with its transparency already resolved against `bg`. This
    // is what a theme paints when it is not using the blur.
    var panelOpaque: NSColor {
        guard let p = panel.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return bg }
        let a = p.alphaComponent
        return NSColor(srgbRed: p.redComponent   * a + b.redComponent   * (1 - a),
                       green:   p.greenComponent * a + b.greenComponent * (1 - a),
                       blue:    p.blueComponent  * a + b.blueComponent  * (1 - a),
                       alpha: 1)
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }
}

extension Theme {

    // ─── Aurora Dark (the palette the app shipped with) ───
    static let auroraDark = Theme(
        id: "aurora-dark",
        displayName: "Aurora Dark",
        isDark: true,
        bg:          NSColor(hex: 0x0C1016),
        bgDeep:      NSColor(hex: 0x070A10),
        panel:       NSColor(srgbRed: 0.078, green: 0.102, blue: 0.141, alpha: 0.58),
        hairline:    NSColor(white: 1.0, alpha: 0.07),
        hairlineS:   NSColor(white: 1.0, alpha: 0.14),
        glassTop:    NSColor(white: 1.0, alpha: 0.08),
        text:        NSColor(srgbRed: 0.941, green: 0.957, blue: 0.988, alpha: 0.94),
        text2:       NSColor(srgbRed: 0.941, green: 0.957, blue: 0.988, alpha: 0.60),
        text3:       NSColor(srgbRed: 0.941, green: 0.957, blue: 0.988, alpha: 0.50),
        syntaxTag:   NSColor(hex: 0xC4A4FF),
        syntaxAttr:  NSColor(hex: 0x7ED6FF),
        syntaxVal:   NSColor(hex: 0xFFC78A),
        syntaxText:  NSColor(hex: 0xA8E6B6),
        syntaxPunct: NSColor(white: 1.0, alpha: 0.60),
        syntaxCom:   NSColor(white: 1.0, alpha: 0.48),
        accent:      NSColor(hex: 0x64B5FF),
        accent2:     NSColor(hex: 0xC4A4FF),
        ok:          NSColor(hex: 0x3DDC97),
        warn:        NSColor(hex: 0xF5C469),
        err:         NSColor(hex: 0xFF6B7A),
        lineHighlight: NSColor(hex: 0x264F78).withAlphaComponent(0.60)
    )

    // ─── Light, classic paper-white with muted XML syntax colors ───
    //
    // Inspired by Apple's default Aqua light appearance. Surfaces are
    // off-white so pure-white highlights still read; text is near-
    // black for max contrast; syntax colors are desaturated against
    // the light ground so they don't vibrate.
    static let light = Theme(
        id: "light",
        displayName: "Light",
        isDark: false,
        bg:          NSColor(hex: 0xF7F7F9),
        bgDeep:      NSColor(hex: 0xFFFFFF),
        panel:       NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.82),
        hairline:    NSColor(white: 0.0, alpha: 0.10),
        hairlineS:   NSColor(white: 0.0, alpha: 0.20),
        glassTop:    NSColor(white: 1.0, alpha: 0.70),
        text:        NSColor(white: 0.10, alpha: 1.00),
        text2:       NSColor(white: 0.30, alpha: 1.00),
        text3:       NSColor(white: 0.44, alpha: 1.00),
        syntaxTag:   NSColor(hex: 0x6F2DBD),  // deep violet
        syntaxAttr:  NSColor(hex: 0x0969DA),  // blue
        syntaxVal:   NSColor(hex: 0xA83E1C),  // burnt amber
        syntaxText:  NSColor(hex: 0x1A7F37),  // forest green
        syntaxPunct: NSColor(white: 0.0, alpha: 0.55),
        syntaxCom:   NSColor(white: 0.0, alpha: 0.56),
        accent:      NSColor(hex: 0x0969DA),
        accent2:     NSColor(hex: 0x6F2DBD),
        ok:          NSColor(hex: 0x1A7F37),
        warn:        NSColor(hex: 0x8A6A00),
        err:         NSColor(hex: 0xCF222E),
        lineHighlight: NSColor(hex: 0xB3D7FF).withAlphaComponent(0.55)
    )

    // ─── One Dark (Atom-style), VS Code's "One Dark Pro" flavor ───
    //
    // Slate-blue background, red/orange/yellow/green/cyan/purple
    // rainbow. Recognizable to anyone who uses VS Code.
    static let oneDark = Theme(
        id: "one-dark",
        displayName: "One Dark",
        isDark: true,
        bg:          NSColor(hex: 0x282C34),
        bgDeep:      NSColor(hex: 0x21252B),
        panel:       NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 0.58),
        hairline:    NSColor(white: 1.0, alpha: 0.07),
        hairlineS:   NSColor(white: 1.0, alpha: 0.16),
        glassTop:    NSColor(white: 1.0, alpha: 0.06),
        text:        NSColor(hex: 0xABB2BF),
        text2:       NSColor(hex: 0x9199A6),
        text3:       NSColor(hex: 0x8E95A2),
        syntaxTag:   NSColor(hex: 0xE1727B),  // red , element names
        syntaxAttr:  NSColor(hex: 0xD19A66),  // orange, attr names
        syntaxVal:   NSColor(hex: 0x98C379),  // green, attr values
        syntaxText:  NSColor(hex: 0x61AFEF),  // blue, element text
        syntaxPunct: NSColor(hex: 0xABB2BF),
        syntaxCom:   NSColor(hex: 0x8E95A2),
        accent:      NSColor(hex: 0x61AFEF),
        accent2:     NSColor(hex: 0xC678DD),
        ok:          NSColor(hex: 0x98C379),
        warn:        NSColor(hex: 0xE5C07B),
        err:         NSColor(hex: 0xE1727B),
        lineHighlight: NSColor(hex: 0x2C313C).withAlphaComponent(0.90)
    )

    // Solarized Dark was removed in v1.1. Its own palette is built for
    // low contrast on purpose, and three of its colours could not be read
    // against its own background. Making it legible meant changing eight
    // of Ethan Schoonover's canonical hex values, at which point it was
    // no longer Solarized. Anyone who had it selected lands on One Dark.

    // ─── Dracula, the classic purple-pink dark theme ───
    //
    // Official palette (draculatheme.com): background #282A36,
    // current line #44475A, pink tags, green attribute names,
    // yellow strings, purple numbers.
    static let dracula = Theme(
        id: "dracula",
        displayName: "Dracula",
        isDark: true,
        bg:          NSColor(hex: 0x282A36),
        bgDeep:      NSColor(hex: 0x21222C),
        panel:       NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 0.58),
        hairline:    NSColor(white: 1.0, alpha: 0.07),
        hairlineS:   NSColor(white: 1.0, alpha: 0.16),
        glassTop:    NSColor(white: 1.0, alpha: 0.06),
        text:        NSColor(hex: 0xF8F8F2),
        text2:       NSColor(hex: 0xF8F8F2).withAlphaComponent(0.62),
        text3:       NSColor(hex: 0x8692B9),
        syntaxTag:   NSColor(hex: 0xFF79C6),  // pink, element names
        syntaxAttr:  NSColor(hex: 0x50FA7B),  // green, attr names
        syntaxVal:   NSColor(hex: 0xF1FA8C),  // yellow, attr values
        syntaxText:  NSColor(hex: 0xBD93F9),  // purple, element text (numbers)
        syntaxPunct: NSColor(hex: 0xF8F8F2).withAlphaComponent(0.60),
        syntaxCom:   NSColor(hex: 0x8692B9),
        accent:      NSColor(hex: 0xBD93F9),
        accent2:     NSColor(hex: 0xFF79C6),
        ok:          NSColor(hex: 0x50FA7B),
        warn:        NSColor(hex: 0xFFB86C),
        err:         NSColor(hex: 0xFF5555),
        lineHighlight: NSColor(hex: 0x44475A).withAlphaComponent(0.90)
    )

    // ─── Hacker, Matrix-style green phosphor on black ───
    //
    // A terminal look: everything is a shade of green on near-black,
    // while warnings and errors keep amber and red so problems still
    // stand out.
    static let hacker = Theme(
        id: "hacker-green",
        displayName: "Hacker",
        isDark: true,
        bg:          NSColor(hex: 0x020A05),
        bgDeep:      NSColor(hex: 0x000000),
        panel:       NSColor(srgbRed: 0.0, green: 0.08, blue: 0.03, alpha: 0.60),
        hairline:    NSColor(hex: 0x00FF41).withAlphaComponent(0.10),
        hairlineS:   NSColor(hex: 0x00FF41).withAlphaComponent(0.25),
        glassTop:    NSColor(hex: 0x00FF41).withAlphaComponent(0.05),
        text:        NSColor(hex: 0xB4FFC6),
        text2:       NSColor(hex: 0x6BD98A),
        text3:       NSColor(hex: 0x3E8A54),
        syntaxTag:   NSColor(hex: 0x00FF41),  // pure Matrix green, element names
        syntaxAttr:  NSColor(hex: 0x7EE787),  // soft green, attr names
        syntaxVal:   NSColor(hex: 0xD8FFB0),  // pale lime, attr values
        syntaxText:  NSColor(hex: 0xEFFFF2),  // near-white green, element text
        syntaxPunct: NSColor(hex: 0x2EA043),
        syntaxCom:   NSColor(hex: 0x278B42),
        // Not the same green as syntaxTag and ok: an element name, a
        // valid document and a focused control were all one pixel.
        accent:      NSColor(hex: 0x54FFB0),
        accent2:     NSColor(hex: 0xB6FF5E),
        ok:          NSColor(hex: 0x00FF41),
        warn:        NSColor(hex: 0xFFD75E),
        err:         NSColor(hex: 0xFF4D4D),
        lineHighlight: NSColor(hex: 0x00FF41).withAlphaComponent(0.16)
    )

    // ─── Solarized Dark, the palette Ethan Schoonover measured ───
    //
    // The same theme the Windows edition ships, so both versions offer
    // the same six. Two of Solarized's own greys are lifted a little:
    // base01 as a comment colour, and base00 as the third text tone,
    // both fall under 4.5:1 on this ground, and the app's own check
    // refuses a colour people have to lean in to read.
    static let solarizedDark = Theme(
        id: "solarized-dark",
        displayName: "Solarized Dark",
        isDark: true,
        bg:          NSColor(hex: 0x002B36),  // base03
        bgDeep:      NSColor(hex: 0x001F27),
        // The pane sits on base03 rather than above it: Solarized's own
        // colours only clear 4.5:1 on the deep ground they were made for.
        panel:       NSColor(srgbRed: 0.0, green: 0.100, blue: 0.130, alpha: 0.90),
        hairline:    NSColor(white: 1.0, alpha: 0.06),
        hairlineS:   NSColor(white: 1.0, alpha: 0.15),
        glassTop:    NSColor(white: 1.0, alpha: 0.05),
        text:        NSColor(hex: 0x93A1A1),  // base1
        text2:       NSColor(hex: 0x839496),  // base0
        text3:       NSColor(hex: 0x8A9EA1),  // base00, lifted to stay readable
        syntaxTag:   NSColor(hex: 0x268BD2),  // blue, element names
        syntaxAttr:  NSColor(hex: 0x2AA198),  // cyan, attr names
        syntaxVal:   NSColor(hex: 0xB58900),  // yellow, attr values
        syntaxText:  NSColor(hex: 0x859900),  // green, element text
        syntaxPunct: NSColor(hex: 0x93A1A1),
        syntaxCom:   NSColor(hex: 0x7E9599),  // base01, lifted to stay readable
        accent:      NSColor(hex: 0x268BD2),
        accent2:     NSColor(hex: 0xD33682),  // magenta
        ok:          NSColor(hex: 0x859900),
        // Solarized's orange and red sit near 3.8:1 on their own ground.
        // A warning and an error are the two things that must not be hard
        // to read, so both are lifted while keeping the hue.
        warn:        NSColor(hex: 0xE07B39),
        err:         NSColor(hex: 0xFF6E6A),
        lineHighlight: NSColor(hex: 0x0A4A5A).withAlphaComponent(0.85)
    )

    static let all: [Theme] = [.auroraDark, .light, .oneDark, .dracula, .hacker, .solarizedDark]
    static func byId(_ id: String) -> Theme? { all.first(where: { $0.id == id }) }
}

// Global theme slot. Switch by assigning, callers MUST also broadcast
// the theme change (MainWindowController.applyTheme does the
// appearance + rebuildColors fan-out).
enum ThemeManager {
    private static let prefsKey = "xml-macker.themeID"
    static var current: Theme = load()

    // A theme id saved by an older version may no longer exist. Send it
    // to the nearest surviving theme rather than silently resetting the
    // user to the default.
    private static let retired: [String: String] = ["solarized-dark": "one-dark"]

    private static func load() -> Theme {
        let saved = UserDefaults.standard.string(forKey: prefsKey) ?? Theme.auroraDark.id
        let id = retired[saved] ?? saved
        return Theme.byId(id) ?? Theme.auroraDark
    }
    static func select(_ theme: Theme) {
        current = theme
        UserDefaults.standard.set(theme.id, forKey: prefsKey)
    }
}


extension NSWindow {
    /// Appearance and ground applied together. AppKit draws the window
    /// title from the appearance and the strip behind it from
    /// backgroundColor; setting one without the other is exactly how a
    /// near-black title landed on a near-black titlebar.
    func applyCurrentTheme(background: NSColor? = nil) {
        appearance = ThemeManager.current.appearance
        if let background { backgroundColor = background }
    }
}

extension NSView {
    /// Mark this view and everything inside it for redraw. A theme switch
    /// changes colours that live inside draw(_:), and those only reach the
    /// screen on the next repaint; setting the flag on the top level alone
    /// left nested controls (the chart's pills, the tab chips) wearing the
    /// previous palette.
    func needsDisplayRecursively() {
        needsDisplay = true
        for v in subviews { v.needsDisplayRecursively() }
    }
}


extension XMColor {
    /// The marker colours. Translucent, so marked text stays readable on
    /// every theme, and a touch stronger on a dark ground where a wash
    /// disappears.
    static func marker(_ c: HighlightColor) -> NSColor {
        let a: CGFloat = ThemeManager.current.isDark ? 0.34 : 0.30
        switch c {
        case .none:   return .clear
        case .red:    return NSColor(srgbRed: 0.98, green: 0.30, blue: 0.34, alpha: a)
        case .blue:   return NSColor(srgbRed: 0.30, green: 0.60, blue: 1.00, alpha: a)
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.85, blue: 0.20, alpha: a)
        case .green:  return NSColor(srgbRed: 0.30, green: 0.85, blue: 0.45, alpha: a)
        }
    }
}
