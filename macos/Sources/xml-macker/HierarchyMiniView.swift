import Cocoa

// Hierarchy flame-map, v0.27.0 redesign of the old boxes-and-arrows
// diagram. Three stacked rows, profiler-style (like Instruments'
// flame graphs):
//
//   row 0  the selected element, spanning the full width
//   row 1  its child elements, each segment sized by how much it
//          contains (an element with 30 periods reads wider than an
//          empty flag), small stragglers fold into a "+N" segment
//   row 2  grandchildren, nested inside their parent's span
//
// v0.44.1 "Structure only": the interesting rows are the main
// elements, the ones with a tree under them, and everything else was
// mostly noise. So rows 1 and 2 show only elements that CONTAIN other
// elements; the plain values (share-weights, speeds, flags…) fold
// into one quiet "N values" bar.
// When nothing under the selection is a container, the values are the
// content and are shown as before. Toggle lives in the pane header and
// is shared with Orbit (StructureFilter).
//
// Hover highlights a segment and shows a tooltip with the tag, its
// key attribute and child count; click navigates (same tree-select
// path as before). Big things look big, you can see at a glance
// where the data actually lives, which arrows never showed.
final class HierarchyMiniView: NSView {
    var onChildClicked: ((XMLTreeNode) -> Void)?

    private var node: XMLTreeNode?
    private var hitRegions: [(NSRect, XMLTreeNode)] = []
    // Non-navigable segments ("+N", "12 values") still get a hover
    // explanation; they carry a tip string instead of a node.
    private var tipRegions: [(NSRect, String)] = []
    private var hoverRect: NSRect?
    private var hoverNode: XMLTreeNode?
    private var hoverTip: String?
    private var tracking: NSTrackingArea?
    private var structureObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = XMMetric.radiusCard
        layer?.borderColor = XMColor.hairline.cgColor
        layer?.borderWidth = XMMetric.hairline
        structureObserver = NotificationCenter.default.addObserver(
            forName: StructureFilter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let o = structureObserver { NotificationCenter.default.removeObserver(o) }
    }

    func setNode(_ node: XMLTreeNode?) {
        self.node = node
        clearHover()
        needsDisplay = true
    }

    private func clearHover() {
        hoverRect = nil; hoverNode = nil; hoverTip = nil
    }

    // Theme hook, the layer's cached bg/border cgColors were baked
    // at init, so re-apply from the fresh theme palette.
    func rebuildColors() {
        layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35).cgColor
        layer?.borderColor = XMColor.hairline.cgColor
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: XMMetric.s(120))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsDisplay = true
    }

    // MARK: helpers

    private func keyAttr(_ n: XMLTreeNode) -> (name: String, value: String)? {
        n.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })
            ?? n.attributes.first
    }

    private func elementKids(_ n: XMLTreeNode) -> [XMLTreeNode] {
        n.children.filter { $0.kind == .element }
    }

    // Weight = how much a subtree "contains", 1 + direct element
    // children. Cheap (no deep walk on 12M-node trees) yet enough to
    // make a 30-period tech visibly wider than an empty flag.
    private func weight(_ n: XMLTreeNode) -> CGFloat {
        CGFloat(1 + elementKids(n).count)
    }

    // Depth-tinted segment palette, cycling theme syntax hues so the
    // map stays coherent across all four themes.
    private var palette: [NSColor] {
        [XMColor.accent, XMColor.syntaxText, XMColor.syntaxAttr, XMColor.syntaxVal]
    }

    private func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        hitRegions.removeAll()
        tipRegions.removeAll()
        guard let node = node else { drawPlaceholder(ctx: ctx); return }

        let pad: CGFloat = 8
        let rowGap: CGFloat = 3
        let rows: CGFloat = 3
        let rowH = max(20, min(30, (bounds.height - pad * 2 - rowGap * (rows - 1)) / rows))
        let fullW = bounds.width - pad * 2
        let topY = bounds.height - pad - rowH

        let labelPS = NSMutableParagraphStyle()
        labelPS.lineBreakMode = .byTruncatingMiddle
        labelPS.alignment = .center

        // One segment: rounded bar + label ("tag · key" when roomy).
        func drawSegment(_ rect: NSRect, node segNode: XMLTreeNode?,
                         fill: NSColor, stroke: NSColor, label: String,
                         labelColor: NSColor, bold: Bool = false) {
            let r = min(4, rect.height / 4)
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            let hovered = (segNode != nil && segNode === hoverNode)
                || (segNode == nil && hoverTip != nil && hoverRect == rect)
            ctx.addPath(path)
            ctx.setFillColor(fill.withAlphaComponent(hovered ? min(1, fill.alphaComponent + 0.14) : fill.alphaComponent).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(hovered ? 1.2 : 0.5)
            ctx.strokePath()
            if rect.width >= 34 {
                let text = NSAttributedString(string: label, attributes: [
                    .font: XMFont.mono(10.5, bold ? .semibold : .medium),
                    .foregroundColor: labelColor,
                    .paragraphStyle: labelPS
                ])
                text.draw(in: NSRect(x: rect.minX + 4,
                                     y: rect.midY - 7,
                                     width: rect.width - 8,
                                     height: 14))
            }
            if let segNode { hitRegions.append((rect, segNode)) }
        }

        func labelFor(_ n: XMLTreeNode, wide: Bool) -> String {
            if wide, let a = keyAttr(n) { return "\(n.name) · \(a.value)" }
            return n.name
        }

        // Quiet summary bar for the plain values folded away by
        // "Structure only", same look in both rows.
        func drawValuesSummary(_ rect: NSRect, count: Int, hue: NSColor, tip: String) {
            guard rect.width >= 10 else { return }
            drawSegment(rect, node: nil,
                        fill: hue.withAlphaComponent(0.06),
                        stroke: hue.withAlphaComponent(0.25),
                        label: plural(count, "value"), labelColor: XMColor.text3)
            tipRegions.append((rect, tip))
        }

        // ---- Row 0: the selected element ----
        let rootRect = NSRect(x: pad, y: topY, width: fullW, height: rowH)
        drawSegment(rootRect, node: node,
                    fill: XMColor.syntaxTag.withAlphaComponent(0.20),
                    stroke: XMColor.syntaxTag.withAlphaComponent(0.55),
                    label: "<\(labelFor(node, wide: rootRect.width > 160))>",
                    labelColor: XMColor.syntaxTag, bold: true)

        let allKids = elementKids(node)
        guard !allKids.isEmpty else {
            // Leaf: show its text value as a single mint bar.
            let val = node.textValue
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = val.isEmpty ? "(no child elements)" : val
            let valRect = NSRect(x: pad, y: topY - rowGap - rowH, width: fullW, height: rowH)
            drawSegment(valRect, node: nil,
                        fill: XMColor.syntaxText.withAlphaComponent(val.isEmpty ? 0.06 : 0.15),
                        stroke: XMColor.syntaxText.withAlphaComponent(val.isEmpty ? 0.2 : 0.5),
                        label: msg, labelColor: val.isEmpty ? XMColor.text3 : XMColor.syntaxText)
            return
        }

        // Structure only: containers get the map, plain values fold
        // into one bar at the end of the row (see StructureFilter).
        let kids = StructureFilter.apply(allKids)
        let hiddenValues = allKids.count - kids.count

        // ---- Row 1: children, width ∝ weight ----
        // Fold everything that would fall below 26pt into one "+N".
        let gap: CGFloat = 2
        let minSeg: CGFloat = 26
        let valW: CGFloat = hiddenValues > 0 ? 60 : 0
        let totalWeight = kids.reduce(0) { $0 + weight($1) }
        var visible: [XMLTreeNode] = []
        var folded: [XMLTreeNode] = []
        for kid in kids.sorted(by: { weight($0) > weight($1) }) {
            let w = weight(kid) / totalWeight * (fullW - valW)
            if w >= minSeg && visible.count < 40 { visible.append(kid) } else { folded.append(kid) }
        }
        if visible.isEmpty && !folded.isEmpty {
            // Everything tiny (e.g. 100 equal flags), show as many
            // equal slices as fit, fold the rest.
            let fitCount = max(1, Int((fullW - valW) / (minSeg + gap)))
            visible = Array(folded.prefix(fitCount - (folded.count > fitCount ? 1 : 0)))
            folded = Array(folded.dropFirst(visible.count))
        }
        // Preserve document order for the visible ones.
        visible.sort { $0.startLine < $1.startLine }

        let foldW: CGFloat = folded.isEmpty ? 0 : 34
        let reserved = foldW + (folded.isEmpty ? 0 : gap) + valW + (hiddenValues > 0 ? gap : 0)
        let visWeight = visible.reduce(0) { $0 + weight($1) }
        let rowW = fullW - reserved - gap * CGFloat(max(0, visible.count - 1))
        let row1Y = topY - rowGap - rowH

        var x = pad
        var childRects: [(XMLTreeNode, NSRect)] = []
        for (i, kid) in visible.enumerated() {
            let w = max(minSeg, weight(kid) / max(visWeight, 1) * rowW)
            let rect = NSRect(x: x, y: row1Y, width: min(w, pad + fullW - x), height: rowH)
            let hue = palette[i % palette.count]
            drawSegment(rect, node: kid,
                        fill: hue.withAlphaComponent(0.16),
                        stroke: hue.withAlphaComponent(0.5),
                        label: labelFor(kid, wide: rect.width > 110),
                        labelColor: XMColor.text)
            childRects.append((kid, rect))
            x += rect.width + gap
        }
        if !folded.isEmpty {
            let remaining = pad + fullW - x
            let w = hiddenValues > 0 ? max(minSeg, remaining - valW - gap) : max(minSeg, remaining)
            let rect = NSRect(x: x, y: row1Y, width: min(w, remaining), height: rowH)
            drawSegment(rect, node: nil,
                        fill: XMColor.hairline,
                        stroke: XMColor.hairlineS,
                        label: "+\(folded.count)", labelColor: XMColor.text3)
            tipRegions.append((rect, "+\(folded.count) more too small to draw, see Subtags"))
            x += rect.width + gap
        }
        if hiddenValues > 0 {
            drawValuesSummary(NSRect(x: x, y: row1Y, width: pad + fullW - x, height: rowH),
                              count: hiddenValues, hue: XMColor.syntaxText,
                              tip: "\(plural(hiddenValues, "plain value")) hidden by Structure only, see Subtags")
        }

        // ---- Row 2: grandchildren nested under their parent ----
        let row2Y = row1Y - rowGap - rowH
        for (i, (kid, kidRect)) in childRects.enumerated() {
            let allGrand = elementKids(kid)
            guard !allGrand.isEmpty else { continue }
            let hue = palette[i % palette.count]
            let grand = StructureFilter.enabled
                ? allGrand.filter(StructureFilter.isContainer) : allGrand
            if grand.isEmpty {
                // Structure only, and nothing but values under this
                // child: one quiet summary instead of a strip of noise.
                drawValuesSummary(NSRect(x: kidRect.minX, y: row2Y, width: kidRect.width, height: rowH),
                                  count: allGrand.count, hue: hue,
                                  tip: "\(plural(allGrand.count, "plain value")) inside <\(kid.name)>")
                continue
            }
            let gTotal = grand.reduce(0) { $0 + weight($1) }
            var gVisible: [XMLTreeNode] = []
            var gFolded = 0
            for g in grand {
                let w = weight(g) / gTotal * kidRect.width
                if w >= minSeg && gVisible.count < 12 { gVisible.append(g) } else { gFolded += 1 }
            }
            if gVisible.isEmpty {
                // All tiny: one summary segment for the whole span.
                let rect = NSRect(x: kidRect.minX, y: row2Y, width: kidRect.width, height: rowH)
                drawSegment(rect, node: nil,
                            fill: hue.withAlphaComponent(0.08),
                            stroke: hue.withAlphaComponent(0.3),
                            label: "\(grand.count) × \(grand[0].name)",
                            labelColor: XMColor.text3)
                tipRegions.append((rect, "\(grand.count) × <\(grand[0].name)> inside <\(kid.name)>"))
                continue
            }
            let gVisWeight = gVisible.reduce(0) { $0 + weight($1) }
            let gFoldW: CGFloat = gFolded > 0 ? 26 : 0
            let gRowW = kidRect.width - gFoldW - gap * CGFloat(max(0, gVisible.count - (gFolded > 0 ? 0 : 1)))
            var gx = kidRect.minX
            for g in gVisible {
                let w = max(minSeg, weight(g) / max(gVisWeight, 1) * gRowW)
                let rect = NSRect(x: gx, y: row2Y,
                                  width: min(w, kidRect.maxX - gx), height: rowH)
                if rect.width < 10 { break }
                drawSegment(rect, node: g,
                            fill: hue.withAlphaComponent(0.09),
                            stroke: hue.withAlphaComponent(0.35),
                            label: labelFor(g, wide: rect.width > 110),
                            labelColor: XMColor.text2)
                gx += rect.width + gap
            }
            if gFolded > 0, kidRect.maxX - gx >= 18 {
                let rect = NSRect(x: gx, y: row2Y, width: kidRect.maxX - gx, height: rowH)
                drawSegment(rect, node: nil,
                            fill: XMColor.hairline,
                            stroke: XMColor.hairlineS,
                            label: "+\(gFolded)", labelColor: XMColor.text3)
                tipRegions.append((rect, "+\(gFolded) more inside <\(kid.name)>"))
            }
        }

        // ---- Hover tooltip ----
        var tipText: String?
        if let hn = hoverNode {
            if hn === node {
                // Top row = up-button; say so.
                if let parent = node.parent, parent.kind == .element {
                    tipText = "↑ up to <\(parent.name)>"
                }
            } else {
                let inside = elementKids(hn)
                let groups = inside.filter(StructureFilter.isContainer).count
                var tip = hn.name
                if let a = keyAttr(hn) { tip += "  \(a.name)=\(a.value)" }
                if inside.isEmpty {
                    if !hn.textValue.isEmpty { tip += "  =  \(hn.textValue.prefix(24))" }
                } else if groups > 0 && groups < inside.count {
                    tip += "  ·  \(plural(groups, "group")) · \(plural(inside.count - groups, "value"))"
                } else {
                    tip += "  ·  \(inside.count) inside"
                }
                tipText = tip
            }
        } else {
            tipText = hoverTip
        }
        if let tip = tipText, let hr = hoverRect {
            let tipAS = NSAttributedString(string: tip, attributes: [
                .font: XMFont.mono(10, .semibold),
                .foregroundColor: XMColor.text
            ])
            let s = tipAS.size()
            var tipRect = NSRect(x: hr.midX - s.width / 2 - 6, y: hr.maxY + 4,
                                 width: s.width + 12, height: s.height + 6)
            if tipRect.maxY > bounds.height - 2 { tipRect.origin.y = hr.minY - tipRect.height - 4 }
            tipRect.origin.x = max(2, min(bounds.width - tipRect.width - 2, tipRect.origin.x))
            let p = CGPath(roundedRect: tipRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(XMColor.bg.withAlphaComponent(0.94).cgColor)
            ctx.setStrokeColor(XMColor.accent.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(0.5)
            ctx.drawPath(using: .fillStroke)
            tipAS.draw(at: NSPoint(x: tipRect.minX + 6, y: tipRect.minY + 3))
        }
    }

    private func drawPlaceholder(ctx: CGContext) {
        let t = NSAttributedString(string: "No selection", attributes: [
            .font: XMFont.uiCaption,
            .foregroundColor: XMColor.text3
        ])
        let s = t.size()
        t.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }

    // MARK: interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Later regions draw on top; scan back-to-front.
        for (r, n) in hitRegions.reversed() where r.contains(p) {
            if n !== hoverNode || hoverTip != nil {
                hoverNode = n; hoverRect = r; hoverTip = nil; needsDisplay = true
            }
            return
        }
        for (r, t) in tipRegions.reversed() where r.contains(p) {
            if t != hoverTip || hoverNode != nil {
                hoverNode = nil; hoverRect = r; hoverTip = t; needsDisplay = true
            }
            return
        }
        if hoverNode != nil || hoverTip != nil { clearHover(); needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverNode != nil || hoverTip != nil { clearHover(); needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, n) in hitRegions.reversed() where r.contains(p) {
            if n !== node {
                onChildClicked?(n)
            } else if let parent = node?.parent, parent.kind == .element {
                // Clicking the TOP row = go UP one level, so the
                // flame map becomes its own navigator.
                onChildClicked?(parent)
            }
            return
        }
    }
}
