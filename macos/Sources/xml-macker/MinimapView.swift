import Cocoa

// Thin column minimap docked to the right of the source editor.
//
// Draws horizontally-striped bars sampled from the document's line
// starts + a crude per-line "importance" heuristic (line length
// bucketed into 4 widths). Lines are NOT enumerated individually, 
// we sample `height / 2pt` slots proportionally across the line
// index. Exact content isn't the point; the point is the overall
// shape of the file + the moving viewport indicator.
//
// The viewport rect is overlaid on top and positioned from the
// source scroll view's clip bounds.
//
// Clicking jumps the source editor to that proportion of the
// document. Dragging scrubs.
final class MinimapView: NSView {
    weak var sourceScroll: NSScrollView?
    weak var sourceTextView: NSTextView?
    var lineStarts: [Int] = []
    // Optional per-line color index 0-3 (violet/aqua/mint/none). If
    // empty we fall back to flat text2 bars (brighter than text3 so
    // the minimap is actually visible against Aurora's dark bg).
    var lineColors: [UInt8] = []
    // "Magnet" snap targets: the start line of every element in the
    // FILE at the selection's own level (all regions when you are on a
    // region, all supplysectors when you are on a supplysector). See
    // LevelIndex. Hovering the left half snaps the hovered line to the
    // nearest entry within ~18 pt, so the popup latches onto element
    // boundaries instead of landing mid-element, the way an index in
    // a dictionary lands on whole entries.
    //
    // MUST be sorted ascending: the hover and the click binary-search
    // it, because a level can hold thousands of entries.
    var snapLines: [Int] = [] { didSet { rebuildTicks(); needsDisplay = true } }

    /// Magnet ticks already reduced to the pixel rows they land on, so
    /// draw() does not walk thousands of line numbers on every hover
    /// frame and every scroll notification just to overpaint the same
    /// rows. Rebuilt when the magnets, the line index or the size change.
    private var tickRows: [CGFloat] = []

    /// Marker strokes, shown as a coloured tick at the right edge so a
    /// mark can be found in a 600,000-line file without scrolling to it.
    var markerStrokes: TextHighlights? { didSet { needsDisplay = true } }
    /// Character offset of each line, needed to place a mark's tick.
    var charOffsets: [Int] = []

    private var barCache: [(y: CGFloat, w: CGFloat, color: NSColor)] = []
    private var viewportObserver: NSObjectProtocol?

    // Hover support, a floating magnifier panel shows ±N lines
    // around the hovered line in a readable font, with the hovered
    // line highlighted. Way more useful than the previous inline
    // hover label, which was cramped and truncated.
    private var hoverY: CGFloat? = nil
    private var trackingArea: NSTrackingArea?
    private let magnifier = MinimapMagnifier()
    // Cached [line → character offset] of the context chunk currently
    // shown in the magnifier. Click-to-line uses this to map a
    // chunk-local row index back to a file-wide line number and
    // scroll the source editor there. Same "jump" path as the
    // minimap's own scrub, just line-accurate.
    private var magnifierFirstLine: Int = 1
    // Fires when the user clicks a line inside the magnifier popup.
    // MainWindowController wires this to find the deepest containing
    // element and route through treeVC.select, so the full
    // handleTreeSelection refresh runs (tree + inspector + source
    // highlight + preview), same as clicking the tree. Doing this
    // instead of poking at textView directly avoids the messy
    // partial-layout artifact that showed up when scrolling happened
    // without also updating the selection state.
    var onLineClicked: ((Int) -> Void)?
    /// The small × at the top: puts the minimap away. View ▸ Show
    /// Minimap (⇧⌘M) brings it back.
    var onHide: (() -> Void)?

    private let hideButton = NSButton()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Route through bgDeep so the minimap surface flips with the
        // theme (dark → near-black, light → white) instead of staying
        // hardcoded dark under Light mode.
        layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = XMMetric.radiusCard
        layer?.borderColor = XMColor.hairlineS.cgColor
        layer?.borderWidth = XMMetric.hairline

        magnifier.onLineClicked = { [weak self] line in
            self?.onLineClicked?(line)
        }

        hideButton.title = "×"
        hideButton.font = XMFont.ui(11, .bold)
        hideButton.isBordered = false
        hideButton.contentTintColor = XMColor.text3
        hideButton.toolTip = "Hide the minimap (View ▸ Show Minimap brings it back)"
        hideButton.target = self
        hideButton.action = #selector(hideClicked(_:))
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hideButton)
        NSLayoutConstraint.activate([
            hideButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            hideButton.widthAnchor.constraint(equalToConstant: 16),
            hideButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @objc private func hideClicked(_ sender: Any?) { onHide?() }

    /// The strip the × sits in, so a click there is the button's and not
    /// a jump to line 1.
    private var hideButtonHitBox: NSRect {
        NSRect(x: bounds.width - 18, y: 0, width: 18, height: 16)
    }

    // Theme hook. Re-apply cached layer colors from the fresh palette.
    func rebuildColors() {
        layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.92).cgColor
        layer?.borderColor = XMColor.hairlineS.cgColor
        hideButton.contentTintColor = XMColor.text3
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent)   { updateHover(event) }
    override func mouseExited(with event: NSEvent)  {
        hoverY = nil
        magnifier.hide()
        needsDisplay = true
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverY = p.y
        guard !lineStarts.isEmpty, bounds.height > 0,
              let storage = sourceTextView?.textStorage,
              let window = self.window else { return }

        let t = max(0, min(1, p.y / bounds.height))
        var lineIdx = min(lineStarts.count - 1, Int(t * Double(lineStarts.count - 1)))
        // Dual-zone hover: only the LEFT half of the minimap applies
        // magnet-snap. Right half is pure-positional hover for quick
        // scrubbing without fighting the snap.
        let magnetZone = p.x < bounds.width / 2
        if magnetZone, let snapped = snappedLine(near: lineIdx + 1) {
            lineIdx = snapped - 1
        }
        let line = lineIdx + 1

        // Collect ±12 lines around the hovered line for the magnifier.
        let context = 12
        let first = max(0, lineIdx - context)
        let last  = min(lineStarts.count - 1, lineIdx + context)
        let startOff = lineStarts[first]
        let endOff   = last + 1 < lineStarts.count
                        ? lineStarts[last + 1] - 1
                        : storage.length
        let len = max(0, min(endOff - startOff, 4096))
        var chunk = ""
        if len > 0 {
            chunk = storage.mutableString.substring(with: NSRange(location: startOff, length: len))
        }

        // Local range within `chunk` corresponding to the hovered line.
        let hoverLocalStart = lineStarts[lineIdx] - startOff
        let hoverLocalEnd   = lineIdx + 1 < lineStarts.count
                                ? lineStarts[lineIdx + 1] - 1 - startOff
                                : (chunk as NSString).length
        let hl = NSRange(location: max(0, hoverLocalStart),
                         length: max(0, hoverLocalEnd - max(0, hoverLocalStart)))

        // Anchor the panel at the hovered Y in screen coordinates.
        let local  = NSPoint(x: 0, y: p.y)
        let inWin  = convert(local, to: nil)
        let screen = window.convertPoint(toScreen: inWin)

        magnifier.attach(to: window)
        magnifier.show(text: chunk,
                       highlightLocal: hl,
                       lineNumber: line,
                       firstLineNumber: first + 1,
                       anchorInScreen: screen)
        magnifierFirstLine = first + 1
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        magnifier.cancelPendingHide()
        updateHover(event)
    }

    /// Fresh line index after an edit. Without this the minimap kept the
    /// index it was handed at open, so every mapping (hover, ticks,
    /// click) drifted by one line per line the user added.
    func updateLineStarts(_ lineStarts: [Int]) {
        guard lineStarts != self.lineStarts else { return }
        self.lineStarts = lineStarts
        rebuildBars()
        rebuildTicks()
        needsDisplay = true
    }

    private func rebuildTicks() {
        tickRows.removeAll(keepingCapacity: true)
        guard !snapLines.isEmpty, lineStarts.count > 1, bounds.height > 0 else { return }
        let total = CGFloat(max(1, lineStarts.count - 1))
        var lastY: CGFloat = -10
        for s in snapLines {
            let y = CGFloat(s - 1) / total * bounds.height
            guard y - lastY >= 1.5 else { continue }
            lastY = y
            tickRows.append(y)
        }
    }

    func attach(scroll: NSScrollView, textView: NSTextView, lineStarts: [Int]) {
        self.sourceScroll = scroll
        self.sourceTextView = textView
        self.lineStarts = lineStarts
        rebuildBars()
        rebuildTicks()
        needsDisplay = true
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        if let o = viewportObserver { NotificationCenter.default.removeObserver(o) }
        viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    deinit {
        if let o = viewportObserver { NotificationCenter.default.removeObserver(o) }
    }

    override func layout() {
        super.layout()
        rebuildBars()
        rebuildTicks()      // tick rows are in view coordinates
    }

    private func rebuildBars() {
        barCache.removeAll(keepingCapacity: true)
        guard lineStarts.count > 1 else { return }

        let h = bounds.height
        guard h > 0 else { return }

        // One bar every 2 pt. Sample line index from proportion.
        let barSpacing: CGFloat = 2
        let slots = max(1, Int(h / barSpacing))
        let lineCount = lineStarts.count
        let w = bounds.width

        for slot in 0..<slots {
            let y = CGFloat(slot) * barSpacing + 0.5
            let t = Double(slot) / Double(max(1, slots - 1))
            let lineIdx = min(lineCount - 1, Int(t * Double(lineCount - 1)))

            // Bar width: use line length (bytes) bucketed to give the
            // minimap some texture. Small = narrow, large = wide.
            let thisStart = lineStarts[lineIdx]
            let nextStart = lineIdx + 1 < lineCount ? lineStarts[lineIdx + 1] : thisStart + 40
            let lineLen = max(0, nextStart - thisStart)
            let fraction: CGFloat
            switch lineLen {
            case ..<8:    fraction = 0.12
            case ..<24:   fraction = 0.28
            case ..<64:   fraction = 0.48
            case ..<160:  fraction = 0.72
            default:      fraction = 0.92
            }
            let barW = (w - 8) * fraction
            // Brighter than text3 so the map is actually visible against
            // Aurora's deep bg. Use syntaxTag (violet) for longer/deeper
            // lines, syntaxAttr (aqua) for shorter, text2 otherwise.
            let color: NSColor
            if lineIdx < lineColors.count {
                switch lineColors[lineIdx] {
                case 1: color = XMColor.syntaxTag.withAlphaComponent(0.80)
                case 2: color = XMColor.syntaxAttr.withAlphaComponent(0.80)
                case 3: color = XMColor.syntaxText.withAlphaComponent(0.80)
                default: color = XMColor.text2
                }
            } else {
                switch fraction {
                case ..<0.25: color = XMColor.syntaxAttr.withAlphaComponent(0.55)
                case ..<0.55: color = XMColor.text2
                case ..<0.80: color = XMColor.syntaxTag.withAlphaComponent(0.60)
                default:       color = XMColor.syntaxText.withAlphaComponent(0.65)
                }
            }
            barCache.append((y: y, w: barW, color: color))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Faint vertical guide at the magnet-zone boundary (center)
        // so users can see where the left (magnet) / right (free)
        // halves meet.
        ctx.setFillColor(XMColor.hairlineS.cgColor)
        ctx.fill(NSRect(x: bounds.width / 2 - 0.25, y: 0,
                        width: 0.5, height: bounds.height))

        // Snap-point tick marks on the LEFT edge, shows the user
        // where the magnet will latch. Drawn only on the left half
        // (the magnet zone).
        // Already reduced to pixel rows by rebuildTicks(), using the same
        // denominator the hover uses (count - 1) so a tick is drawn
        // exactly where it snaps rather than a hair above it.
        if !tickRows.isEmpty {
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.55).cgColor)
            for y in tickRows {
                ctx.fill(NSRect(x: 0, y: y - 0.5, width: 4, height: 1))
            }
        }

        // Sampled bars, 2.2 pt tall (≈ 2 pt spacing) for solid coverage.
        for b in barCache {
            ctx.setFillColor(b.color.cgColor)
            ctx.fill(NSRect(x: 4, y: b.y, width: b.w, height: 1.6))
        }
        // Hover line marker (thin accent)
        if let hy = hoverY {
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.85).cgColor)
            ctx.fill(NSRect(x: 0, y: hy - 0.5, width: bounds.width, height: 1))
        }

        // Marker ticks on the RIGHT edge, one per stroke.
        if let strokes = markerStrokes, !strokes.isEmpty, lineStarts.count > 1 {
            let total = CGFloat(max(1, lineStarts.count - 1))
            for r in strokes.ranges {
                // Binary search the line holding the stroke's first character.
                var lo = 0, hi = lineStarts.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if lineStarts[mid] <= r.start { lo = mid } else { hi = mid - 1 }
                }
                let y = CGFloat(lo) / total * bounds.height
                ctx.setFillColor(XMColor.marker(r.color).withAlphaComponent(0.95).cgColor)
                ctx.fill(NSRect(x: bounds.width - 5, y: y - 1, width: 5, height: 2))
            }
        }

        // Viewport overlay
        if let scroll = sourceScroll, let tv = sourceTextView {
            let docHeight = max(1, tv.frame.height)
            let clip = scroll.contentView.bounds
            let top = clip.origin.y / docHeight
            let height = clip.size.height / docHeight
            let y = top * bounds.height
            let h = max(14, height * bounds.height)
            let rect = NSRect(x: 1, y: y, width: bounds.width - 2, height: h)
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.14).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(XMColor.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The magnet nearest `line`, if one is inside the ~18 pt window.
    /// Binary search: a level can hold thousands of entries and this
    /// runs on every mouse move.
    private func snappedLine(near line: Int) -> Int? {
        guard !snapLines.isEmpty, lineStarts.count > 1, bounds.height > 0 else { return nil }
        let linesPerPx = CGFloat(lineStarts.count) / max(1, bounds.height)
        let window = max(1, Int(18 * linesPerPx))
        var lo = 0, hi = snapLines.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if snapLines[mid] < line { lo = mid + 1 } else { hi = mid }
        }
        var best = snapLines[lo]
        if lo > 0, abs(snapLines[lo - 1] - line) < abs(best - line) { best = snapLines[lo - 1] }
        return abs(best - line) <= window ? best : nil
    }

    private func hoveredLine(at p: NSPoint) -> Int? {
        guard !lineStarts.isEmpty, bounds.height > 0 else { return nil }
        let t = max(0, min(1, p.y / bounds.height))
        return min(lineStarts.count - 1, Int(t * Double(lineStarts.count - 1))) + 1
    }

    // Left (magnet) half: land on an element and select it, so a click
    // hops element by element the way the lane promises. It used to
    // only scroll, which left the tree, the inspector and the source
    // highlight behind, and on a level with no magnet nearby it looked
    // like nothing had happened at all. There is no silent click here
    // any more: with no magnet in range it selects whatever element
    // covers the clicked line.
    // Right half stays a free positional scrub, which is what it is for.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The × owns its corner: a click there must not also scrub.
        if hideButtonHitBox.contains(p) { return }
        scrub(event)
        guard p.x < bounds.width / 2, let line = hoveredLine(at: p) else { return }
        onLineClicked?(snappedLine(near: line) ?? line)
    }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        guard let scroll = sourceScroll, let tv = sourceTextView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = max(0, min(1, p.y / bounds.height))
        let docH = tv.frame.height
        let clip = scroll.contentView
        let visH = clip.bounds.height
        let targetY = max(0, min(docH - visH, t * docH - visH / 2))
        clip.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scroll.reflectScrolledClipView(clip)
    }
}
