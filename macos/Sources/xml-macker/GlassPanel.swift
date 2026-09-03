import Cocoa

// Liquid Glass container: an NSView with NSVisualEffectView behind,
// hairline border, rounded corners, and an optional top-inner
// highlight to mimic Tahoe-style inset gloss.
//
// Add your content as a subview of `.contentView`, the glass layers
// sit behind and don't need constraint babysitting.
//
// Usage:
//   let panel = GlassPanel(config: GlassConfig(...))
//   panel.contentView.addSubview(myContent)
//
// Wrapping every pane/card in this is how the Aurora "every surface
// is glass" feel is produced without hand-rolling backdrop filters
// anywhere. NSVisualEffectView is the native AppKit equivalent of
// CSS backdrop-filter and is fully GPU accelerated.
final class GlassPanel: NSView {
    let contentView = NSView()
    private let effectView: NSVisualEffectView
    private let borderLayer = CALayer()
    private var highlightLayer: CAGradientLayer?
    private var tintLayer: CALayer?
    private let config: GlassConfig

    init(config: GlassConfig = GlassConfig()) {
        self.config = config
        self.effectView = NSVisualEffectView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = config.radius
        layer?.masksToBounds = true

        // Material comes from the active theme so Light themes get a
        // bright `.contentBackground` surface instead of the fixed
        // `.hudWindow` dark HUD (which stays dark under any
        // appearance). The per-GlassPanel config value is kept as a
        // legacy default for anyone constructing a GlassPanel
        // outside the main window (there aren't any right now, but
        // it's cheap to preserve).
        effectView.material = ThemeManager.current.glassMaterial
        effectView.blendingMode = config.blendingMode
        // Pinned to the flat (inactive) rendering. With
        // .followsWindowActiveState, focusing the window switched
        // every panel to full vibrancy and the desktop WALLPAPER bled
        // through the glass, so panels looked wrong while active and
        // right while inactive (a blue wallpaper tinted the Tree
        // pane). Colors now identical whether focused or not.
        effectView.state = .inactive
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        applySurface()

        // Optional tint wash over the blur, set tintAlpha > 0 to use.
        if let t = config.tint, config.tintAlpha > 0 {
            let tl = CALayer()
            tl.backgroundColor = t.withAlphaComponent(config.tintAlpha).cgColor
            tl.frame = bounds
            tl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(tl)
            tintLayer = tl
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // Border sits on top of everything inside; draw as a sublayer
        // so corner radius matches.
        borderLayer.borderColor = config.border.cgColor
        borderLayer.borderWidth = XMMetric.hairline
        borderLayer.cornerRadius = config.radius
        borderLayer.frame = bounds
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(borderLayer)

        // Inset-top highlight, thin bright line along the upper edge,
        // fading downward. Characteristic of Tahoe's glossy panels.
        if config.showInsetHighlight {
            let gl = CAGradientLayer()
            gl.colors = Self.glossColors()
            gl.startPoint = NSPoint(x: 0.5, y: 1.0)
            gl.endPoint   = NSPoint(x: 0.5, y: 0.0)
            gl.locations  = [0.0, 0.18]
            gl.frame = bounds
            gl.cornerRadius = config.radius
            gl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.insertSublayer(gl, below: borderLayer)
            highlightLayer = gl
        }

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Border & highlight auto-resize via autoresizingMask; nothing
        // extra to do here. Kept as a hook for future tweaks.
    }

    // Nuclear repair for window migration: NSVisualEffectView keeps
    // window-tied render state that survives neither reparenting nor
    // simple repaints (docked panes rendered flat grey until a manual
    // divider drag). Rip the effect view out, re-add it, re-pin it,
    // and cycle its state so it re-binds to the CURRENT window.
    func refreshAfterWindowMove() {
        effectView.removeFromSuperview()
        addSubview(effectView, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        effectView.material = ThemeManager.current.glassMaterial
        effectView.state = .active
        effectView.state = .inactive
        applySurface()
        needsDisplay = true
    }

    // Theme hook, re-apply cached cgColors baked at init AND swap
    // the NSVisualEffectView's material so Light themes get a bright
    // surface instead of the dark HUD material. tintLayer stays
    // untouched (tint is a per-panel decoration, not theme-driven).
    func rebuildColors() {
        effectView.material = ThemeManager.current.glassMaterial
        borderLayer.borderColor = XMColor.hairlineS.cgColor
        highlightLayer?.colors = Self.glossColors()
        applySurface()
    }

    // The top gloss follows the theme's own glassTop token instead of a
    // fixed white wash, which used to wash out the Light theme and dilute
    // the phosphor green of Hacker.
    private static func glossColors() -> [CGColor] {
        let top = XMColor.glassTop
        return [top.cgColor, top.withAlphaComponent(0).cgColor]
    }

    // Either blur the desktop (Aurora Dark and Light) or paint the
    // theme's real surface colour (every other theme).
    private func applySurface() {
        let theme = ThemeManager.current
        if theme.usesVibrancy {
            effectView.isHidden = false
            layer?.backgroundColor = nil
        } else {
            effectView.isHidden = true
            layer?.backgroundColor = theme.panelOpaque.cgColor
        }
    }
}
