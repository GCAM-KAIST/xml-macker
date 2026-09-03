import Cocoa

// Floating magnifier panel that sits next to the minimap and shows
// a zoomed-in chunk of the source at the hovered line. Think of it
// as "Preview with a magnifying glass", the hover bar on the minimap
// picks the line, the panel renders ±12 surrounding lines in readable
// SF Mono 11 pt with syntax-ish coloring (tags violet, attr values
// amber), and highlights the hovered line itself in accent.
//
// Technical notes:
// - The panel is a borderless, non-activating NSPanel so it can show
//   while the main window remains key. Level is .floating so it
//   stays above the main window when it moves.
// - We keep it *as a child of the main window* via addChildWindow to
//   ensure it disappears if the window minimizes or is hidden.
// - Drawing is done with a custom NSView that renders an attributed
//   string, cheaper than embedding a full NSTextView for just a
//   peek that re-renders every mouseMoved event.
final class MinimapMagnifier {

    // Fires when the user clicks a line inside the magnifier. The
    // MinimapView wires this to scroll the source editor to that
    // line, same as clicking the minimap itself but line-accurate.
    var onLineClicked: ((Int) -> Void)?

    private let panel: NSPanel
    private let contentView = MagnifierContentView()
    private weak var parent: NSWindow?
    // Debounced-hide token. When the mouse leaves the minimap we
    // don't hide immediately, we wait ~120 ms so the mouse can
    // travel into the magnifier without the panel closing on them.
    // Moving back into either region cancels the pending hide.
    private var pendingHide: DispatchWorkItem?
    // First-line character offset of the content currently shown,
    // so click-to-line math knows what index the top line maps to.
    private var firstLineNumber: Int = 1

    init() {
        let rect = NSRect(x: 0, y: 0, width: 380, height: 240)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = ThemeManager.current.appearance
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true   // never linger over another app
        panel.contentView = contentView
        contentView.frame = rect
        contentView.onPointerEntered = { [weak self] in self?.cancelPendingHide() }
        contentView.onPointerExited  = { [weak self] in self?.scheduleHide() }
        contentView.onLineClicked    = { [weak self] rowIndex in
            guard let self else { return }
            self.onLineClicked?(self.firstLineNumber + rowIndex)
        }
    }

    func cancelPendingHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func scheduleHide() {
        cancelPendingHide()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    func attach(to window: NSWindow) {
        guard parent !== window else { return }
        if let old = parent { old.removeChildWindow(panel) }
        parent = window
        window.addChildWindow(panel, ordered: .above)
    }

    // Show the magnifier anchored near `anchorPointInScreen` (we
    // place the panel to the LEFT of this point so it doesn't block
    // the minimap bars). `text` is the surrounding source slice, and
    // `highlightLocal` is the (begin, end) char range inside `text`
    // to emphasize as the hovered line.
    func show(text: String,
              highlightLocal: NSRange,
              lineNumber: Int,
              firstLineNumber: Int,
              anchorInScreen: NSPoint) {
        cancelPendingHide()
        self.firstLineNumber = firstLineNumber
        contentView.update(text: text, highlight: highlightLocal, lineNumber: lineNumber)
        var f = panel.frame
        f.origin.x = anchorInScreen.x - f.width - 12
        f.origin.y = anchorInScreen.y - f.height / 2
        // Clamp to the parent's screen so the magnifier doesn't
        // drift off-screen on smaller displays.
        if let screen = parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            f.origin.x = max(visible.minX + 8, min(visible.maxX - f.width - 8, f.origin.x))
            f.origin.y = max(visible.minY + 8, min(visible.maxY - f.height - 8, f.origin.y))
        }
        panel.setFrame(f, display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        scheduleHide()
    }
}

// Custom content view: dark rounded-rect bg, hairline border,
// attributed-string drawing with the hovered line rect drawn behind
// the text in an accent tint. Kept small so redraws on mouseMoved
// are cheap.
private final class MagnifierContentView: NSView {
    private var displayText: NSAttributedString = NSAttributedString(string: "")
    private var title: String = ""
    private var lineHeight: CGFloat = 14
    /// Rows actually drawn, the highlighted row among them, and where
    /// that block starts inside the chunk it was cut from.
    private var rowCount: Int = 0
    private var highlightRow: Int = -1
    private(set) var firstShownRow: Int = 0

    var onPointerEntered: (() -> Void)?
    var onPointerExited:  (() -> Void)?
    var onLineClicked:    ((Int) -> Void)?   // row index within shown chunk

    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent)  { onPointerExited?() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard lineHeight > 0, rowCount > 0 else { return }
        // Rows run top-down from the top of the text rect, the same way
        // draw() places the highlight band.
        let r = textRect()
        let row = Int(((r.maxY - p.y) / lineHeight).rounded(.down))
        let clamped = max(0, min(rowCount - 1, row))
        // Report the row within the whole chunk, not within the window we
        // happened to draw, so the caller's firstLineNumber still applies.
        onLineClicked?(firstShownRow + clamped)
    }

    /// The rect the preview text is drawn in. Shared by draw() and the
    /// click mapping so the two can never disagree about where a row is.
    private func textRect() -> NSRect {
        bounds.insetBy(dx: 4, dy: 4).insetBy(dx: 10, dy: 8).offsetBy(dx: 0, dy: -10)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let panelRect = bounds.insetBy(dx: 4, dy: 4)
        let p = CGPath(roundedRect: panelRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(p)
        ctx.setFillColor(XMColor.bgDeep.withAlphaComponent(0.97).cgColor)
        ctx.setStrokeColor(XMColor.hairlineS.cgColor)
        ctx.setLineWidth(0.5)
        ctx.drawPath(using: .fillStroke)

        let titleAS = NSAttributedString(string: title.uppercased(), attributes: [
            .font: XMFont.uiCaption,
            .foregroundColor: XMColor.text3
        ])
        titleAS.draw(at: NSPoint(x: panelRect.minX + 10, y: panelRect.maxY - 18))

        let r = textRect()
        // An attributed string is typeset from the TOP of its rect, so the
        // highlight has to be measured from the top too. It used to be
        // measured up from the bottom on the assumption that the whole
        // chunk was drawn, which stopped being true the moment the chunk
        // was taller than the panel: the band landed eight rows above the
        // element it was supposed to be marking.
        if rowCount > 0, highlightRow >= 0, highlightRow < rowCount {
            let y = r.maxY - CGFloat(highlightRow + 1) * lineHeight
            let hr = NSRect(x: r.minX - 6, y: y, width: r.width + 12, height: lineHeight)
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.20).cgColor)
            ctx.fill(hr)
            ctx.setFillColor(XMColor.accent.cgColor)
            ctx.fill(NSRect(x: hr.minX, y: hr.minY, width: 2, height: hr.height))
        }
        displayText.draw(in: r)
    }

    func update(text: String, highlight: NSRange, lineNumber: Int) {
        title = "line \(lineNumber) · preview"
        // Build syntax-like attributed string. This is a one-off pass
        // on ~25 lines so there's no perf concern using regex-lite
        // coloring.
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byClipping
        ps.lineSpacing = 1
        let font = XMFont.mono(11, .regular)
        // Measured, not estimated: the highlight band has to sit exactly
        // on the row the text lands on.
        let lineH = NSLayoutManager().defaultLineHeight(for: font) + ps.lineSpacing
        lineHeight = lineH

        let ns = text as NSString
        let prefix = ns.substring(with: NSRange(location: 0,
                                                length: min(highlight.location, ns.length)))
        let hitRow = prefix.components(separatedBy: "\n").count - 1

        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }

        // Draw only the rows that fit, centred on the hovered one, so the
        // element the magnet latched onto is the row in the middle with
        // the band on it rather than something clipped off the edge.
        let fits = max(1, Int(textRect().height / lineH))
        var first = 0
        if rows.count > fits {
            first = max(0, min(rows.count - fits, hitRow - fits / 2))
        }
        let last = min(rows.count, first + fits)
        let shown = first < last ? Array(rows[first..<last]) : rows

        let attr = NSMutableAttributedString(string: shown.joined(separator: "\n"), attributes: [
            .font: font,
            .foregroundColor: XMColor.text,
            .paragraphStyle: ps
        ])
        colorize(attr)

        firstShownRow = first
        rowCount = shown.count
        highlightRow = hitRow - first
        displayText = attr
        needsDisplay = true
    }

    // Minimal XML-aware coloring: tag names in violet, attribute
    // names in aqua, quoted values in amber. Doesn't need to be
    // perfect, the point is "this is readable source", not "this
    // is the primary editor". We bound the work to a few regex
    // passes on ~25 lines at most.
    private func colorize(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        let full = NSRange(location: 0, length: s.length)
        func apply(_ pattern: String, color: NSColor, group: Int = 0) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            rx.enumerateMatches(in: attr.string, options: [], range: full) { m, _, _ in
                guard let m = m, m.numberOfRanges > group else { return }
                let r = m.range(at: group)
                if r.location != NSNotFound {
                    attr.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }
        apply(#"</?([A-Za-z_][\w\-.:]*)"#, color: XMColor.syntaxTag, group: 1)
        apply(#"\s([A-Za-z_][\w\-.:]*)\s*="#, color: XMColor.syntaxAttr, group: 1)
        apply(#"=\s*(\"[^\"]*\"|'[^']*')"#, color: XMColor.syntaxVal, group: 1)
        apply(#"<!--[\s\S]*?-->"#, color: XMColor.syntaxCom)
    }
}
