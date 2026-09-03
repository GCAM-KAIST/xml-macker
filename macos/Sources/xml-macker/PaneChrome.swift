import Cocoa

// Lightweight per-pane chrome: a 24-pt titlebar on top of the pane's
// content with three traffic-light-style buttons on the right:
//
//   ×  close      → fires onClose; MainWindowController hides the pane
//                   (same effect as the View menu toggle)
//   □  maximize   → fires onMaximize; controller hides every other
//                   top-level pane so this one fills the window
//   −  minimize   → fires onMinimize; controller collapses the pane's
//                   content to header-only (content hidden, header
//                   stays visible)
//
// The content host (`contentContainer`) is where the pane's actual
// view is planted. We hide ONLY the contentContainer on minimize so
// the header bar still draws and the minimize/maximize/close buttons
// stay clickable, so users can un-minimize from the same control.
final class PaneChrome: NSView {

    var onClose:    (() -> Void)?
    var onMaximize: (() -> Void)?
    var onMinimize: (() -> Void)?
    // Pop-out moved OFF the green button (v0.23.1): green carries the
    // macOS meaning of expand, so opening a window from it was
    // surprising. Pop-out now lives on the dedicated ↗ button
    // at the right edge of the header.
    var onPopOut:   (() -> Void)?

    let contentContainer = NSView()
    let headerView: NSView = PaneHeaderView()
    private let titleLabel = NSTextField(labelWithString: "")
    // The dots used to hardcode Aurora Dark's amber, mint and red, so
    // they stayed Aurora-coloured in every other theme. They read the
    // palette now and are re-tinted on a theme switch.
    private let minButton   = PaneDotButton(symbol: "-", fill: XMColor.warn)
    private let maxButton   = PaneDotButton(symbol: "+", fill: XMColor.ok)
    private let closeButton = PaneDotButton(symbol: "×", fill: XMColor.err)
    private let popOutButton = PaneDotButton(symbol: "↗", fill: XMColor.text3)
    // Stored so rebuildFonts() can recompute the header height when
    // the global zoom slider changes, makes the chrome shrink/grow
    // with the slider instead of staying fixed at 22 pt.
    private let headerSeparator = CALayer()
    private var headerHeightCon: NSLayoutConstraint?
    private var buttonStack: NSStackView?
    private var stackLeadingCon: NSLayoutConstraint?
    private var titleLeadingCon: NSLayoutConstraint?
    private var titleTrailingCon: NSLayoutConstraint?
    private var popOutTrailingCon: NSLayoutConstraint?
    private var controlConstraints: [NSLayoutConstraint] = []
    private var titleConstraints: [NSLayoutConstraint] = []
    private weak var headerAccessory: NSView?
    private var accessoryCommonConstraints: [NSLayoutConstraint] = []
    private var accessoryWithControls: [NSLayoutConstraint] = []
    private var accessoryWithoutControls: [NSLayoutConstraint] = []
    private var accessoryLeadingWithControlsCon: NSLayoutConstraint?
    private var accessoryTrailingWithControlsCon: NSLayoutConstraint?
    private var accessoryLeadingWithoutControlsCon: NSLayoutConstraint?
    private var accessoryTrailingWithoutControlsCon: NSLayoutConstraint?
    private var headerControlsHidden = false
    private static let baseHeaderHeight: CGFloat = 22
    private static let baseButtonSpacing: CGFloat = 6
    private static let baseLeadingPadding: CGFloat = 10
    private static let baseTitleGap: CGFloat = 10
    private static let baseTrailingGap: CGFloat = 8
    private static let baseAccessoryVerticalPadding: CGFloat = 2

    private var rawTitle: String = ""
    var title: String {
        get { rawTitle }
        set {
            rawTitle = newValue
            applyTitleStyle()
            updateButtonDescriptions()
        }
    }
    private func applyTitleStyle() {
        titleLabel.attributedStringValue = NSAttributedString(
            string: rawTitle.uppercased(),
            attributes: [.font: XMFont.uiCaption,
                         .foregroundColor: XMColor.text2,
                         .kern: 0.9])
    }

    // Green button state: expanded-in-place (pane took its column's
    // spare space) shows the restore glyph.
    var isMaximized: Bool = false {
        didSet {
            maxButton.symbolGlyph = isMaximized ? "↩" : "+"
            updateButtonDescriptions()
        }
    }
    // ↗ button state: pane currently lives in its own window.
    var isPoppedOut: Bool = false {
        didSet {
            popOutButton.symbolGlyph = isPoppedOut ? "↙" : "↗"
            updateButtonDescriptions()
        }
    }
    // Hidden while the pane floats in its own window, the real
    // window title bar takes over; two stacked title bars looked
    // like a screenshot glitch. Dock back = close the window.
    var headerHidden: Bool = false {
        didSet {
            headerView.isHidden = headerHidden
            applyScaledMetrics()
        }
    }

    // Side-by-side panes fold to a narrow strip: the title would only
    // show as "…", so drop it and leave the dots.
    var hidesTitleWhenMinimized = false

    // Popped-out panes keep a slim header with ONLY the grey ↙ button, so
    // the pane docks back from the same spot it left. The window's own
    // title bar carries the name; the dots and title stay hidden.
    func showDockOnlyHeader(_ on: Bool) {
        headerHidden = false
        buttonStack?.isHidden = on || headerControlsHidden
        titleLabel.isHidden = on || headerAccessory != nil
        popOutButton.isHidden = headerControlsHidden
        applyScaledMetrics()
    }

    var isMinimized: Bool = false {
        didSet {
            contentContainer.isHidden = isMinimized
            minButton.symbolGlyph = isMinimized ? "+" : "-"
            if hidesTitleWhenMinimized, headerAccessory == nil {
                titleLabel.isHidden = isMinimized
            }
            updateButtonDescriptions()
        }
    }

    private func updateButtonDescriptions() {
        let pane = rawTitle.isEmpty ? "pane" : "\(rawTitle) pane"
        closeButton.setActionDescription("Close \(pane)")
        minButton.setActionDescription(isMinimized ? "Restore \(pane)" : "Minimize \(pane)")
        maxButton.setActionDescription(isMaximized ? "Restore \(pane) size" : "Expand \(pane)")
        popOutButton.setActionDescription(isPoppedOut
            ? "Dock \(pane) in the main window"
            : "Open \(pane) in its own window")
    }

    // Keep every piece of the header on the same scale. Previously
    // only the header itself changed height, leaving 12-pt controls and
    // fixed gaps inside an 11-pt header at 50% zoom.
    private func applyScaledMetrics() {
        var headerHeight = XMMetric.s(Self.baseHeaderHeight)
        // AppKit's mini segmented control retains a native minimum height even
        // when its font shrinks. Give header accessories enough room at the
        // 50% endpoint instead of clipping them into the pane content.
        if let accessory = headerAccessory, !accessory.isHidden {
            let intrinsicHeight = accessory.intrinsicContentSize.height
            let fittingHeight = accessory.fittingSize.height
            let accessoryHeight = max(intrinsicHeight > 0 ? intrinsicHeight : 0,
                                      fittingHeight > 0 ? fittingHeight : 0)
            if accessoryHeight.isFinite {
                headerHeight = max(headerHeight,
                                   ceil(accessoryHeight
                                        + 2 * XMMetric.s(Self.baseAccessoryVerticalPadding)))
            }
        }
        headerHeightCon?.constant = headerHidden ? 0 : headerHeight
        buttonStack?.spacing = XMMetric.s(Self.baseButtonSpacing)
        stackLeadingCon?.constant = XMMetric.s(Self.baseLeadingPadding)
        titleLeadingCon?.constant = XMMetric.s(Self.baseTitleGap)
        titleTrailingCon?.constant = -XMMetric.s(Self.baseTrailingGap)
        popOutTrailingCon?.constant = -XMMetric.s(Self.baseTrailingGap)
        accessoryLeadingWithControlsCon?.constant = XMMetric.s(Self.baseTitleGap)
        accessoryTrailingWithControlsCon?.constant = -XMMetric.s(Self.baseTrailingGap)
        accessoryLeadingWithoutControlsCon?.constant = XMMetric.s(Self.baseLeadingPadding)
        accessoryTrailingWithoutControlsCon?.constant = -XMMetric.s(Self.baseTrailingGap)
        closeButton.rebuildMetrics()
        minButton.rebuildMetrics()
        maxButton.rebuildMetrics()
        popOutButton.rebuildMetrics()
    }

    // Global zoom slider hook, re-queries XMFont helpers AND
    // recomputes the header height so the whole pane chrome
    // (close/min/max buttons + title) shrinks/grows with the slider.
    func rebuildFonts() {
        applyTitleStyle()
        applyScaledMetrics()
    }

    // Theme hook. The header's cached cgColor was baked at init,
    // so re-apply it from the fresh theme palette. titleLabel's
    // textColor also picks up the new theme's text2.
    func rebuildColors() {
        headerView.layer?.backgroundColor = XMColor.bg.withAlphaComponent(0.85).cgColor
        headerSeparator.backgroundColor = XMColor.hairlineS.cgColor
        minButton.fillColor = XMColor.warn
        maxButton.fillColor = XMColor.ok
        closeButton.fillColor = XMColor.err
        popOutButton.fillColor = XMColor.text3
        applyTitleStyle()
        needsDisplay = true
    }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        // Double-click the title strip does what the green button does.
        (headerView as? PaneHeaderView)?.onDoubleClick = { [weak self] in self?.onMaximize?() }
        // v0.32.0 visual pass: more solid header + a hairline
        // separator under it, panes read as distinct cards instead
        // of content bleeding into the title strip.
        headerView.layer?.backgroundColor = XMColor.bg.withAlphaComponent(0.85).cgColor
        headerSeparator.backgroundColor = XMColor.hairlineS.cgColor
        headerView.layer?.addSublayer(headerSeparator)
        addSubview(headerView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // Hard clip: whatever happens inside the pane (transient
        // over-compression during live divider drags included), its
        // content can NEVER paint over the title bar.
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        addSubview(contentContainer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.uiCaption
        titleLabel.textColor = XMColor.text2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        headerView.addSubview(titleLabel)
        self.rawTitle = title
        applyTitleStyle()

        let stack = NSStackView(views: [closeButton, minButton, maxButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = XMMetric.s(Self.baseButtonSpacing)
        stack.orientation = .horizontal
        headerView.addSubview(stack)
        self.buttonStack = stack

        closeButton.onClick = { [weak self] in self?.onClose?() }
        minButton.onClick   = { [weak self] in self?.onMinimize?() }
        maxButton.onClick   = { [weak self] in self?.onMaximize?() }
        popOutButton.onClick = { [weak self] in self?.onPopOut?() }
        headerView.addSubview(popOutButton)

        let headerH = headerView.heightAnchor.constraint(equalToConstant: XMMetric.s(Self.baseHeaderHeight))
        let stackLeading = stack.leadingAnchor.constraint(
            equalTo: headerView.leadingAnchor,
            constant: XMMetric.s(Self.baseLeadingPadding))
        let titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: stack.trailingAnchor,
            constant: XMMetric.s(Self.baseTitleGap))
        let titleTrailing = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: popOutButton.leadingAnchor,
            constant: -XMMetric.s(Self.baseTrailingGap))
        let popOutTrailing = popOutButton.trailingAnchor.constraint(
            equalTo: headerView.trailingAnchor,
            constant: -XMMetric.s(Self.baseTrailingGap))
        // Never REQUIRED: a pane folded to a narrow strip must degrade
        // gracefully instead of making Auto Layout break constraints.
        for c in [stackLeading, titleLeading, popOutTrailing] {
            c.priority = NSLayoutConstraint.Priority(999)
        }
        self.headerHeightCon = headerH
        self.stackLeadingCon = stackLeading
        self.titleLeadingCon = titleLeading
        self.titleTrailingCon = titleTrailing
        self.popOutTrailingCon = popOutTrailing
        let stackCenterY = stack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        let titleCenterY = titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        let popOutCenterY = popOutButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        self.controlConstraints = [stackLeading, stackCenterY, popOutTrailing, popOutCenterY]
        self.titleConstraints = [titleLeading, titleTrailing, titleCenterY]
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerH,
            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + controlConstraints + titleConstraints)
        updateButtonDescriptions()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        headerSeparator.frame = CGRect(x: 0, y: 0,
                                       width: headerView.bounds.width,
                                       height: 1)
    }

    // Plant `view` into the content area, full-bleed.
    func setContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    /// Replaces the title text with a compact control that remains available
    /// even while this pane's content is collapsed. Used by the right detail
    /// rail to switch Inspector / Chart / Preview without stacking three full
    /// panels in a short window.
    func setHeaderAccessory(_ view: NSView) {
        NSLayoutConstraint.deactivate(accessoryCommonConstraints
                                      + accessoryWithControls
                                      + accessoryWithoutControls)
        headerAccessory?.removeFromSuperview()
        headerAccessory = view
        titleLabel.isHidden = true
        NSLayoutConstraint.deactivate(titleConstraints)
        view.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(view)
        let leadingWithControls = view.leadingAnchor.constraint(
            equalTo: buttonStack!.trailingAnchor,
            constant: XMMetric.s(Self.baseTitleGap))
        let trailingWithControls = view.trailingAnchor.constraint(
            lessThanOrEqualTo: popOutButton.leadingAnchor,
            constant: -XMMetric.s(Self.baseTrailingGap))
        let leadingWithoutControls = view.leadingAnchor.constraint(
            greaterThanOrEqualTo: headerView.leadingAnchor,
            constant: XMMetric.s(Self.baseLeadingPadding))
        let trailingWithoutControls = view.trailingAnchor.constraint(
            lessThanOrEqualTo: headerView.trailingAnchor,
            constant: -XMMetric.s(Self.baseTrailingGap))
        accessoryLeadingWithControlsCon = leadingWithControls
        accessoryTrailingWithControlsCon = trailingWithControls
        accessoryLeadingWithoutControlsCon = leadingWithoutControls
        accessoryTrailingWithoutControlsCon = trailingWithoutControls
        accessoryCommonConstraints = [
            view.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ]
        accessoryWithControls = [leadingWithControls, trailingWithControls]
        accessoryWithoutControls = [
            leadingWithoutControls,
            trailingWithoutControls,
            view.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
        ]
        NSLayoutConstraint.activate(accessoryCommonConstraints
                                    + (headerControlsHidden
                                       ? accessoryWithoutControls
                                       : accessoryWithControls))
        applyScaledMetrics()
    }

    /// A conventional inspector header needs navigation, not a second set of
    /// window-like traffic lights. The main detail rail uses this to remove
    /// close/minimize/expand/pop-out affordances that competed with its tabs.
    func setHeaderControlsHidden(_ hidden: Bool) {
        headerControlsHidden = hidden
        buttonStack?.isHidden = hidden
        popOutButton.isHidden = hidden
        if hidden {
            NSLayoutConstraint.deactivate(controlConstraints + titleConstraints)
        } else {
            NSLayoutConstraint.activate(controlConstraints)
            if headerAccessory == nil {
                titleLabel.isHidden = false
                NSLayoutConstraint.activate(titleConstraints)
            }
        }
        guard headerAccessory != nil else {
            applyScaledMetrics()
            return
        }
        NSLayoutConstraint.deactivate(accessoryWithControls + accessoryWithoutControls)
        NSLayoutConstraint.activate(hidden ? accessoryWithoutControls : accessoryWithControls)
        applyScaledMetrics()
    }
}

// The title strip: a double-click expands the pane like the green
// button. Single clicks fall through to the window (drag etc.).
private final class PaneHeaderView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

// Small circular "traffic light" button with a symbol glyph. Glyph
// appears only on hover, matches the macOS title-bar idiom.
private final class PaneDotButton: NSView {
    var onClick: (() -> Void)?
    var symbolGlyph: String { didSet { needsDisplay = true } }
    var fillColor: NSColor { didSet { needsDisplay = true } }
    private var isHover: Bool = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private var widthCon: NSLayoutConstraint?
    private var heightCon: NSLayoutConstraint?
    private static let baseDiameter: CGFloat = 12
    private static let minimumDiameter: CGFloat = 8

    init(symbol: String, fill: NSColor) {
        self.symbolGlyph = symbol
        self.fillColor = fill
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let diameter = Self.scaledDiameter
        let widthCon = widthAnchor.constraint(equalToConstant: diameter)
        let heightCon = heightAnchor.constraint(equalToConstant: diameter)
        self.widthCon = widthCon
        self.heightCon = heightCon
        NSLayoutConstraint.activate([widthCon, heightCon])

        // This is a custom-drawn NSView rather than an NSButton, so it
        // must opt into accessibility explicitly for VoiceOver to see
        // it as an actionable control.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var scaledDiameter: CGFloat {
        // Eight points is still compact, but prevents the dots becoming
        // nearly impossible to hit at the slider's 50% endpoint.
        max(minimumDiameter, XMMetric.s(baseDiameter))
    }

    func rebuildMetrics() {
        let diameter = Self.scaledDiameter
        widthCon?.constant = diameter
        heightCon?.constant = diameter
        needsDisplay = true
    }

    func setActionDescription(_ description: String) {
        toolTip = description
        setAccessibilityLabel(description)
        setAccessibilityHelp(description)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHover = true  }
    override func mouseExited(with event: NSEvent)  { isHover = false }
    override func mouseDown(with event: NSEvent)    { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = max(0.5, XMFont.globalScale)
        let r = bounds.insetBy(dx: inset, dy: inset)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillEllipse(in: r)
        if isHover {
            let glyphAS = NSAttributedString(string: symbolGlyph, attributes: [
                .font: XMFont.ui(8.5, .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.65)
            ])
            let s = glyphAS.size()
            glyphAS.draw(at: NSPoint(x: bounds.midX - s.width / 2,
                                     y: bounds.midY - s.height / 2))
        }
    }
}
