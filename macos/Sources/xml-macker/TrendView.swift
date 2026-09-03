import Cocoa

// Sparkline / bar chart for the inspector.
//
//   .line → values drawn left→right as an accent-blue curve with
//           small dots at each data point. Used for time series.
//   .bar  → values drawn as tinted vertical bars with the value
//           written on top. Used for "at a fixed year, across
//           categories" comparisons. Bar kind gets a different
//           mint/violet tint so the two modes are visually distinct.
//
// Hover highlights: a vertical crosshair line runs from the top of
// the plot down through the hovered data point, the point itself
// gets a glow ring, and a pill tooltip shows "label: value" above it.
final class TrendView: NSView {

    var series: TrendSeries? {
        didSet { hoverIndex = nil; needsDisplay = true }
    }
    // When true, the chart draws each value's number above the
    // point (line kind) or bar (bar kind). Off in the inline
    // inspector card (too cramped); on in the pop-out window.
    var showLabels: Bool = false { didSet { needsDisplay = true } }
    // Text size multiplier, the pop-out window sets 1.5 so titles,
    // value labels and axis numbers read comfortably at full size.
    var fontScale: CGFloat = 1 { didSet { needsDisplay = true } }
    // Fires when the user clicks the ↗ pop-out button in the
    // top-right corner of the chart. MainWindowController opens a
    // ChartPopoutWindow with a bigger version + extra controls.
    var onPopoutRequested: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var hoverIndex: Int?
    private var popoutButtonRect: NSRect = .zero
    // Chart Builder (v1.0.2): the "Build" pill left of "Open ↗".
    var onBuildRequested: (() -> Void)?
    private var buildButtonRect: NSRect = .zero

    // When rendering for copy / save-image we need an OPAQUE dark
    // backdrop (otherwise the image pastes gray because the
    // inspector's on-screen card is semi-transparent over the
    // Aurora glass, which doesn't exist on the pasteboard). Callers
    // toggle this flag around cacheDisplay(in:to:).
    var isRenderingForExport: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the radius + border on the CA layer for the on-screen
        // look, but DO NOT set layer.backgroundColor, NSView's
        // cacheDisplay(in:to:) doesn't capture layer background in a
        // bitmap, so when the user copied/saved the chart the image
        // came out gray. Painting the bg inside draw(_:) makes the
        // cached bitmap carry the real chart background.
        layer?.cornerRadius = 8
        layer?.borderColor = XMColor.hairline.cgColor
        layer?.borderWidth = XMMetric.hairline
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The border lives on a CALayer, so a redraw alone cannot refresh it
    /// after a theme switch.
    func rebuildColors() {
        layer?.borderColor = XMColor.hairline.cgColor
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if popoutButtonRect.contains(p) {
            onPopoutRequested?()
        } else if buildButtonRect.contains(p) {
            onBuildRequested?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let series = series else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rect = plotRect()
        guard rect.contains(p), series.values.count >= 2 else {
            if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
            return
        }
        let idx: Int
        switch series.kind {
        case .line:
            // Irregular GCAM years use their real horizontal distances, so
            // hover must locate the nearest drawn point rather than round an
            // equal-width slot.
            idx = series.values.indices.min(by: {
                abs(lineX(for: $0, series: series, in: rect) - p.x)
                    < abs(lineX(for: $1, series: series, in: rect) - p.x)
            }) ?? 0
        case .bar:
            let slot = rect.width / CGFloat(series.values.count)
            idx = Int((p.x - rect.minX) / slot)
        }
        let clamped = max(0, min(series.values.count - 1, idx))
        if clamped != hoverIndex { hoverIndex = clamped; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    // How the labels under a bar chart are set. On a 32-region chart
    // they ran into each other, so the chart now picks the
    // tightest style that still reads: flat while the names fit, tilted
    // when they do not, straight up and down when even a tilt collides.
    enum XLabelMode { case flat, angled, vertical }

    // One font for the names under a bar chart, so the room reserved for
    // them is measured in exactly what gets drawn.
    private static func xLabelFont(_ scale: CGFloat) -> NSFont { XMFont.ui(10 * scale, .semibold) }

    // Room kept on the right of the plot. The numbers used to live in
    // this gutter; they moved to a proper y axis on the left, so only a
    // small breathing margin is left here.
    private static let plotRightInset: CGFloat = 14

    private func plotLeftInset(for series: TrendSeries?) -> CGFloat {
        guard let series else { return 10 }
        return 10 + yAxisInset(series: series)
    }

    private func plotContentWidth(for series: TrendSeries) -> CGFloat {
        max(10, bounds.width - plotLeftInset(for: series) - Self.plotRightInset)
    }

    /// How wide this chart wants to be so every bar keeps its own slot
    /// and the y-axis numbers still fit. The pop-out sizes its sideways
    /// scrolling area from this instead of guessing, which is what let
    /// 16.5 pt value labels collide inside 46 pt slots.
    func preferredWidth(barSlot slot: CGFloat) -> CGFloat {
        guard let s = series, s.kind == .bar, s.values.count >= 2 else { return 0 }
        let chrome = plotLeftInset(for: s) + Self.plotRightInset + 6
        return chrome + slot * fontScale * CGFloat(s.values.count)
    }

    private func plotRect() -> NSRect {
        // Top area reserves 28 pt for the title row (which now
        // contains the "Open ↗" pill on the right) so the pop-out
        // button no longer intersects the bars or y-axis labels.
        // Crowded bar charts reserve extra room for rotated labels.
        // Measured, not guessed: XMFont already folds the zoom slider into
        // its sizes, so a plain multiple of fontScale clipped every label
        // once the zoom was raised.
        let labelH = ("Xg" as NSString).size(withAttributes: [.font: Self.xLabelFont(fontScale)]).height
        let bottom = max(16 * fontScale, 6 + labelH)
        let left = plotLeftInset(for: series)
        let width = max(10, bounds.width - left - Self.plotRightInset)
        // The label band never gets to squeeze the plot out of existence:
        // on a short inspector card the names give way to the chart.
        let room = bounds.height - 28 - bottom
        let wanted = series.map { barLabelLayout(series: $0).inset } ?? 0
        let extra = max(0, min(wanted, room - 40))
        return NSRect(x: left, y: bottom + extra, width: width,
                      height: max(10, room - extra))
    }

    // THE vertical scale, read by the bars, the curve, the hover dot and
    // the axis labels alike, so a bar top always lands on the gridline
    // whose number it matches. autoScaleRange picks the window (including
    // the zoom-in on near-identical values); this rounds that window
    // out to whole ticks.
    private func visualRange(for series: TrendSeries) -> (Double, Double) {
        let (lo, hi) = autoScaleRange(series: series, preferZeroBaseline: false)
        let ticks = niceTicks(min: lo, max: hi)
        guard ticks.count >= 2 else { return (lo, hi) }
        let step = ticks[1] - ticks[0]
        guard step > 0, step.isFinite else { return (lo, hi) }
        let snappedLo = (lo / step).rounded(.down) * step
        let snappedHi = (hi / step).rounded(.up) * step
        guard snappedHi > snappedLo, snappedLo.isFinite, snappedHi.isFinite else { return (lo, hi) }
        return (snappedLo, snappedHi)
    }

    // Width the y-axis numbers need on the left, measured from the
    // widest tick label so the scale never sits on top of the plot.
    private func yAxisInset(series: TrendSeries) -> CGFloat {
        guard series.values.count >= 2 else { return 0 }
        let (visMin, visMax) = visualRange(for: series)
        let ticks = niceTicks(min: visMin, max: visMax)
        guard !ticks.isEmpty else { return 0 }
        let font = XMFont.mono(9 * fontScale, .medium)
        let widest = ticks.reduce(CGFloat(0)) { w, t in
            max(w, (formatNumber(t) as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(96, widest + 12)
    }

    // Round tick values (1, 2, 5 or 10 times a power of ten) covering
    // the visible range, so the axis reads 0, 50, 100 rather than
    // 17.3333, 51.9999.
    private func niceTicks(min lo: Double, max hi: Double, target: Int = 5) -> [Double] {
        guard lo.isFinite, hi.isFinite, hi > lo else { return [] }
        let raw = (hi - lo) / Double(max(1, target))
        guard raw > 0, raw.isFinite else { return [] }
        let mag = pow(10, (log10(raw)).rounded(.down))
        guard mag > 0, mag.isFinite else { return [] }
        let norm = raw / mag
        let step: Double
        if norm < 1.5       { step = mag }
        else if norm < 3    { step = 2 * mag }
        else if norm < 7    { step = 5 * mag }
        else                { step = 10 * mag }
        var ticks: [Double] = []
        var t = (lo / step).rounded(.down) * step
        var safety = 0
        while t <= hi + step * 0.001, safety < 64 {
            if t >= lo - step * 0.001 { ticks.append(t) }
            t += step
            safety += 1
        }
        return ticks
    }

    // Trim a label with an ellipsis until it fits the room we have.
    private func elide(_ s: String, to maxWidth: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        guard maxWidth > 8 else { return "" }
        if (s as NSString).size(withAttributes: attrs).width <= maxWidth { return s }
        var chars = Array(s)
        while chars.count > 1 {
            chars.removeLast()
            let candidate = String(chars) + "\u{2026}"
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth { return candidate }
        }
        return "\u{2026}"
    }

    // Draw text so that it ENDS at `anchor`, turned counter-clockwise by
    // `angle`. At 45 degrees the label runs down and to the left of the
    // bar; at 90 degrees it stands straight up under it.
    private func drawRotated(_ text: NSAttributedString, endingAt anchor: NSPoint,
                             angle: CGFloat, ctx: CGContext) {
        let s = text.size()
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: angle)
        text.draw(at: NSPoint(x: -s.width, y: -s.height / 2))
        ctx.restoreGState()
    }

    // Pick the label style, the room it needs below the plot, how many
    // labels to skip when even vertical text collides, and how long a
    // label may be before it is trimmed.
    private func barLabelLayout(series: TrendSeries) -> (mode: XLabelMode, inset: CGFloat, step: Int, maxWidth: CGFloat) {
        guard series.kind == .bar, !series.xLabels.isEmpty else { return (.flat, 0, 1, 0) }
        let font = Self.xLabelFont(fontScale)
        let lineH = ("Xg" as NSString).size(withAttributes: [.font: font]).height
        let slot = plotContentWidth(for: series) / CGFloat(max(1, series.values.count))
        let widest = series.xLabels.reduce(CGFloat(0)) { w, l in
            max(w, (l as NSString).size(withAttributes: [.font: font]).width)
        }
        if widest <= slot - 6 { return (.flat, 0, 1, slot) }
        // Room below the plot we are willing to spend on labels.
        let cap = min(150 * fontScale, max(44, bounds.height * 0.38))
        if slot >= lineH * 1.5 {
            // Tilted 45 degrees: neighbours clear each other once the
            // sideways gap times cos(45) is at least one line of text.
            let shown = min(widest, cap / 0.7071)
            return (.angled, min(cap, shown * 0.7071 + 10 * fontScale), 1, shown)
        }
        // Straight up and down: neighbours only need one line of width
        // each. Below that, show every Nth name instead of a smear.
        let step = max(1, Int((Double(lineH) / Double(max(slot, 1))).rounded(.up)))
        let shown = min(widest, cap - 10 * fontScale)
        return (.vertical, min(cap, shown + 10 * fontScale), step, shown)
    }

    private func lineX(for index: Int, series: TrendSeries, in plot: NSRect) -> CGFloat {
        if let positions = series.xPositions,
           positions.count == series.values.count,
           let first = positions.first,
           let last = positions.last,
           first.isFinite, last.isFinite, last > first {
            let value = positions[index]
            if value.isFinite {
                return plot.minX + CGFloat((value - first) / (last - first)) * plot.width
            }
        }
        let step = plot.width / CGFloat(max(1, series.values.count - 1))
        return plot.minX + CGFloat(index) * step
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background, painted here (not via layer) so cacheDisplay
        // captures it. Fully opaque during export so copied/saved
        // images have a solid dark backdrop; translucent on-screen
        // to keep the Aurora glass feel.
        let bgAlpha: CGFloat = isRenderingForExport ? 1.0 : 0.35
        ctx.setFillColor(XMColor.bgDeep.withAlphaComponent(bgAlpha).cgColor)
        let bgPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Build / Open ↗ pills stay available even when the chart is
        // blank: the builder reaches the whole file.
        drawHeaderPills(ctx: ctx)

        guard let series = series else {
            drawPlaceholder(ctx: ctx)
            return
        }

        // Bold + theme text color so the title is legible on EVERY
        // theme, hardcoded white here was invisible on Light, where the
        // pop-out drew all axis text white-on-white. Constrained
        // to a rect so it truncates with ellipsis instead of running
        // under the Open ↗ pill on the right.
        let titlePS = NSMutableParagraphStyle()
        titlePS.lineBreakMode = .byTruncatingTail
        let titleAS = NSAttributedString(string: series.title.uppercased(), attributes: [
            .font: XMFont.ui(11 * fontScale, .bold),
            .foregroundColor: XMColor.text,
            .paragraphStyle: titlePS
        ])
        let titleWidth = max(80, bounds.width - (onBuildRequested != nil ? 165 : 90))
        titleAS.draw(in: NSRect(x: 10, y: bounds.height - 18 * fontScale,
                                width: titleWidth, height: 16 * fontScale))


        let plot = plotRect()
        guard plot.width > 10, plot.height > 10, series.values.count >= 2 else { return }

        // Gridlines and the numbered scale go down first so the bars and
        // the line sit on top of them.
        drawYAxis(ctx: ctx, series: series, plot: plot)

        // Proper x/y axis lines. Theme hairline color works on both dark
        // and light grounds.
        ctx.setStrokeColor(XMColor.text3.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: plot.minX, y: plot.maxY))          // y-axis
        ctx.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))       // x-axis
        ctx.strokePath()

        switch series.kind {
        case .line: drawLine(ctx: ctx, series: series, plot: plot)
        case .bar:  drawBars(ctx: ctx, series: series, plot: plot)
        }

        // The old min / max pair in the right gutter is gone: the y axis
        // on the left now carries the whole scale.

        // Shared hover overlay, crosshair + highlighted point + tooltip.
        if let i = hoverIndex, i < series.values.count {
            drawHover(ctx: ctx, series: series, plot: plot, i: i)
        }
    }

    // The scale on the left: a faint gridline across the plot, a short
    // tick, and the number, for each round step in the visible range.
    // No unit is shown, the scale only has to be readable.
    private func drawYAxis(ctx: CGContext, series: TrendSeries, plot: NSRect) {
        let (visMin, visMax) = visualRange(for: series)
        let ticks = niceTicks(min: visMin, max: visMax)
        guard ticks.count >= 2 else { return }
        let span = max(visMax - visMin, 1e-12)
        // Line charts inset the plot by 4 pt vertically, bars do not;
        // match whichever mapping the marks themselves use so a gridline
        // lands exactly where its value does.
        let inner = plot.insetBy(dx: 0, dy: series.kind == .line ? 4 : 0)
        let font = XMFont.mono(9 * fontScale, .medium)
        for t in ticks {
            let raw = inner.minY + CGFloat((t - visMin) / span) * inner.height
            guard raw.isFinite, raw >= plot.minY - 0.5, raw <= plot.maxY + 0.5 else { continue }
            let y = raw.rounded() + 0.5
            ctx.setStrokeColor(XMColor.text3.withAlphaComponent(0.16).cgColor)
            ctx.setLineWidth(1)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.strokePath()
            ctx.setStrokeColor(XMColor.text3.withAlphaComponent(0.5).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: plot.minX - 3, y: y))
            ctx.addLine(to: CGPoint(x: plot.minX, y: y))
            ctx.strokePath()
            let l = NSAttributedString(string: formatNumber(t), attributes: [
                .font: font,
                .foregroundColor: XMColor.text2
            ])
            let s = l.size()
            // The gutter is capped, so a very wide number (scientific
            // notation at a big zoom) is pushed back inside the view
            // rather than drawn off the left edge.
            let lx = max(2, plot.minX - 6 - s.width)
            guard lx + s.width <= plot.minX - 2 else { continue }
            l.draw(at: NSPoint(x: lx, y: raw - s.height / 2))
        }
    }

    private func drawLine(ctx: CGContext, series: TrendSeries, plot: NSRect) {
        let (visMin, visMax) = visualRange(for: series)
        let span = max(visMax - visMin, 1e-12)
        let pad: CGFloat = 4
        let innerY = plot.insetBy(dx: 0, dy: pad)
        let yFor: (Double) -> CGFloat = { v in
            let clamped = min(visMax, max(visMin, v))
            let t = (clamped - visMin) / span
            return innerY.minY + CGFloat(t) * innerY.height
        }
        let xFor: (Int) -> CGFloat = { [self] i in
            lineX(for: i, series: series, in: plot)
        }

        // Area under the curve, vertical gradient (strong at the
        // line, fading to nothing at the baseline) instead of a flat
        // tint. Cheap modernization that reads on every theme.
        let area = CGMutablePath()
        area.move(to: CGPoint(x: xFor(0), y: plot.minY))
        for (i, v) in series.values.enumerated() {
            area.addLine(to: CGPoint(x: xFor(i), y: yFor(v)))
        }
        area.addLine(to: CGPoint(x: xFor(series.values.count - 1), y: plot.minY))
        area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area)
        ctx.clip()
        let areaColors = [XMColor.accent.withAlphaComponent(0.32).cgColor,
                          XMColor.accent.withAlphaComponent(0.02).cgColor]
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: areaColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: plot.midX, y: plot.maxY),
                                   end: CGPoint(x: plot.midX, y: plot.minY),
                                   options: [])
        }
        ctx.restoreGState()

        // Line.
        ctx.setStrokeColor(XMColor.accent.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.beginPath()
        for (i, v) in series.values.enumerated() {
            let pt = CGPoint(x: xFor(i), y: yFor(v))
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.strokePath()

        ctx.setFillColor(XMColor.accent.cgColor)
        for (i, v) in series.values.enumerated() {
            let pt = CGPoint(x: xFor(i), y: yFor(v))
            ctx.fillEllipse(in: NSRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4))
            if showLabels {
                let l = NSAttributedString(string: formatNumber(v), attributes: [
                    .font: XMFont.mono(11 * fontScale, .bold),
                    .foregroundColor: XMColor.text
                ])
                let s = l.size()
                l.draw(at: NSPoint(x: pt.x - s.width / 2, y: pt.y + 6))
            }
        }

        // X labels placed by MEASURED position, left to right.
        //
        // The old rule was a fixed index stride plus a force-appended last
        // label, and on the real GCAM year axis, which is irregular, that
        // put "2100" about 20 pt from "2095" for a 33 pt label: they
        // overlapped. Now the LAST label is reserved first, anchored
        // inside the right edge, and nothing is allowed to reach it; the
        // first is drawn if it clears; every middle label is drawn only
        // when it clears the previous one plus a gap. Widening the window
        // simply reveals more years.
        let labelFont = XMFont.ui(10 * fontScale, .semibold)
        let gap: CGFloat = 8
        func label(_ i: Int) -> NSAttributedString {
            NSAttributedString(string: series.xLabels[i], attributes: [
                .font: labelFont, .foregroundColor: XMColor.text2])
        }
        func place(_ i: Int) -> (text: NSAttributedString, x: CGFloat, width: CGFloat) {
            let a = label(i)
            let w = a.size().width
            var x = xFor(i) - w / 2
            x = max(plot.minX - 8, min(plot.maxX - w, x))
            return (a, x, w)
        }
        let y = plot.minY - 4 - label(0).size().height
        let count = series.values.count
        guard count > 0 else { return }

        let last = place(count - 1)
        var drawn: [(CGFloat, CGFloat)] = []            // x, width
        last.text.draw(at: NSPoint(x: last.x, y: y))
        drawn.append((last.x, last.width))

        if count > 1 {
            let first = place(0)
            if first.x + first.width + gap <= last.x {
                first.text.draw(at: NSPoint(x: first.x, y: y))
                drawn.insert((first.x, first.width), at: 0)
            }
            var cursor = drawn.first!.0 + drawn.first!.1
            for i in 1..<(count - 1) {
                let p = place(i)
                guard p.x >= cursor + gap, p.x + p.width + gap <= last.x else { continue }
                p.text.draw(at: NSPoint(x: p.x, y: y))
                cursor = p.x + p.width
            }
        }
    }

    private func drawBars(ctx: CGContext, series: TrendSeries, plot: NSRect) {
        let fill   = XMColor.syntaxText.withAlphaComponent(0.50)
        let stroke = XMColor.syntaxText.withAlphaComponent(0.90)
        let slot = plot.width / CGFloat(series.values.count)
        let barW = max(4, min(slot * 0.70, 40))

        // Auto-zoom the y-axis to the actual data spread. If the
        // values are all nearly identical (range < 1% of |mean|),
        // pad around the mean so variations are still visible
        // instead of collapsing into invisible nubs. The case that
        // forced this: 4 AgProductionTechnologies all ≈0.01131 → bars
        // should show the small differences, not flatline.
        let (visMin, visMax) = visualRange(for: series)
        let span = max(visMax - visMin, 1e-12)
        let yFor: (Double) -> CGFloat = { v in
            let clamped = min(visMax, max(visMin, v))
            let t = (clamped - visMin) / span
            return plot.minY + CGFloat(t) * plot.height
        }
        let baseY = plot.minY

        for (i, v) in series.values.enumerated() {
            let cx = plot.minX + slot * CGFloat(i) + slot / 2
            let y  = yFor(v)
            // Minimum visible height so flat data still shows a
            // baseline rectangle the user can see.
            let h = max(2, abs(y - baseY))
            let rect = NSRect(x: cx - barW / 2,
                              y: baseY,
                              width: barW,
                              height: h)
            // Rounded bar with a vertical gradient, replaces the flat
            // "old style" rectangle the pop-out used to draw.
            let rTop = min(4, barW / 3)
            let barPath = CGPath(roundedRect: rect, cornerWidth: rTop, cornerHeight: rTop, transform: nil)
            ctx.saveGState()
            ctx.addPath(barPath)
            ctx.clip()
            let barColors = [fill.withAlphaComponent(0.90).cgColor,
                             fill.withAlphaComponent(0.35).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: barColors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY),
                                       options: [])
            } else {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(rect)
            }
            ctx.restoreGState()
            ctx.addPath(barPath)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            if showLabels {
                let l = NSAttributedString(string: formatNumber(v), attributes: [
                    .font: XMFont.mono(11 * fontScale, .bold),
                    .foregroundColor: XMColor.text
                ])
                let s = l.size()
                if s.width <= slot - 3 {
                    // Room to lie flat above the bar.
                    let above = rect.maxY + 2
                    let fits = above + s.height < plot.maxY
                    let ly = fits ? above : max(rect.minY + 2, rect.maxY - s.height - 2)
                    l.draw(at: NSPoint(x: rect.midX - s.width / 2, y: ly))
                } else if slot >= s.height + 1 {
                    // Too narrow to lie flat: stand the number up rather
                    // than let neighbours run together into 175.4175.4.
                    let top = rect.maxY + 4
                    if top + s.width < plot.maxY {
                        drawRotated(l, endingAt: NSPoint(x: rect.midX, y: top + s.width),
                                    angle: .pi / 2, ctx: ctx)
                    } else if rect.height > s.width + 8 {
                        drawRotated(l, endingAt: NSPoint(x: rect.midX, y: rect.maxY - 4),
                                    angle: .pi / 2, ctx: ctx)
                    }
                }
                // Anything narrower than that stays in the hover tooltip
                // and the data table, where it is still readable.
            }
        }

        // x-label under each bar. Flat while the names fit, tilted 45
        // degrees when the bars get narrow, standing straight up when
        // even a tilt would collide, and thinned to every Nth name when
        // there is not even room for that. The full label is always in
        // the hover tooltip.
        let layout = barLabelLayout(series: series)
        let labelFont = Self.xLabelFont(fontScale)
        // A 45 degree label extends left by about 0.71 of its length, far
        // enough to run through the y-axis numbers and off the view. Clip
        // the band so it can only ever paint below the plot.
        // The band is only clipped VERTICALLY, at the foot of the plot.
        // The y-axis numbers live above that line, so a tilted label is
        // free to lean into the left gutter, which is where the first
        // one has to go, without ever touching them.
        ctx.saveGState()
        ctx.clip(to: NSRect(x: 0, y: 0, width: bounds.width, height: max(0, plot.minY - 3)))
        defer { ctx.restoreGState() }
        for (i, label) in series.xLabels.enumerated() where i < series.values.count {
            if layout.step > 1, i % layout.step != 0 { continue }
            let cx = plot.minX + slot * CGFloat(i) + slot / 2
            switch layout.mode {
            case .flat:
                let xl = NSAttributedString(string: label, attributes: [
                    .font: labelFont,
                    .foregroundColor: XMColor.text2,
                    .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle; p.alignment = .center; return p }()
                ])
                let w = max(8, slot - 2)
                // Measured height, bottom-anchored in the band plotRect
                // already reserved: a flat 14 x fontScale box clipped the
                // text once the zoom slider pushed the real line height
                // past it at the pop-out's 1.5 scale.
                let h = ("Xg" as NSString).size(withAttributes: [.font: labelFont]).height
                xl.draw(in: NSRect(x: cx - w / 2, y: plot.minY - 4 - h, width: w, height: h))
            case .angled, .vertical:
                let shown = elide(label, to: layout.maxWidth, font: labelFont)
                guard !shown.isEmpty else { continue }
                let xl = NSAttributedString(string: shown, attributes: [
                    .font: labelFont,
                    .foregroundColor: XMColor.text2])
                drawRotated(xl, endingAt: NSPoint(x: cx, y: plot.minY - 6),
                            angle: layout.mode == .angled ? .pi / 4 : .pi / 2, ctx: ctx)
            }
        }
    }

    // Compute (visual-min, visual-max) for the y-axis. When the data
    // range is large relative to the magnitude we use min/max as-is
    // (classic behavior). When values are nearly identical we zoom
    // in around the mean by ±5% so small variations are visible.
    // `preferZeroBaseline` is reserved for line charts that want
    // to include zero when values are all positive; we don't use it
    // for bar charts, which keep the full auto-scale instead.
    private func autoScaleRange(series: TrendSeries, preferZeroBaseline: Bool) -> (Double, Double) {
        let mn = series.min
        let mx = series.max
        let range = mx - mn
        let magnitude = max(Swift.abs(mx), Swift.abs(mn))
        // "Flat-ish" = spread less than 1% of the magnitude.
        if magnitude > 0 && range < magnitude * 0.01 {
            let mean = (mx + mn) / 2
            let pad = max(magnitude * 0.05, range * 4)
            return (mean - pad, mean + pad)
        }
        if range == 0 {
            // Exactly zero, nothing to compare, give a unit window.
            return (mn - 0.5, mx + 0.5)
        }
        return (mn, mx)
    }

    private func drawHover(ctx: CGContext, series: TrendSeries, plot: NSRect, i: Int) {
        let v = series.values[i]
        let (visMin, visMax) = visualRange(for: series)
        let span = max(visMax - visMin, 1e-12)

        let pointX: CGFloat
        let pointY: CGFloat
        switch series.kind {
        case .line:
            let innerY = plot.insetBy(dx: 0, dy: 4)
            let clamped = min(visMax, max(visMin, v))
            pointX = lineX(for: i, series: series, in: plot)
            pointY = innerY.minY + CGFloat((clamped - visMin) / span) * innerY.height
        case .bar:
            let slot = plot.width / CGFloat(series.values.count)
            let clamped = min(visMax, max(visMin, v))
            pointX = plot.minX + slot * CGFloat(i) + slot / 2
            pointY = plot.minY + CGFloat((clamped - visMin) / span) * plot.height
        }

        // Vertical crosshair guideline (thin accent, dashed).
        ctx.saveGState()
        ctx.setStrokeColor(XMColor.accent.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.8)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        ctx.beginPath()
        ctx.move(to: CGPoint(x: pointX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: pointX, y: plot.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        // Point ring.
        ctx.setStrokeColor(XMColor.accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: NSRect(x: pointX - 5, y: pointY - 5, width: 10, height: 10))
        ctx.setFillColor(XMColor.accent.cgColor)
        ctx.fillEllipse(in: NSRect(x: pointX - 2, y: pointY - 2, width: 4, height: 4))

        // Tooltip pill.
        let tip = "\(series.xLabels[i]): \(formatNumber(v))"
        let tipAS = NSAttributedString(string: tip, attributes: [
            .font: XMFont.mono(10 * fontScale, .semibold),
            .foregroundColor: XMColor.text
        ])
        let s = tipAS.size()
        var tipRect = NSRect(x: pointX - s.width / 2 - 6, y: pointY + 8,
                             width: s.width + 12, height: s.height + 6)
        // Keep the tip inside the part of the chart that is on screen
        // (the pop-out chart can be wider than its window).
        let vis = visibleRect.isEmpty ? bounds : visibleRect
        if tipRect.maxY > vis.maxY - 2 {
            tipRect.origin.y = pointY - tipRect.height - 8
        }
        tipRect.origin.x = max(vis.minX + 2, min(vis.maxX - tipRect.width - 2, tipRect.origin.x))
        ctx.setFillColor(XMColor.bg.withAlphaComponent(0.92).cgColor)
        ctx.setStrokeColor(XMColor.accent.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        let p = CGPath(roundedRect: tipRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(p)
        ctx.drawPath(using: .fillStroke)
        tipAS.draw(at: NSPoint(x: tipRect.minX + 6, y: tipRect.minY + 3))
    }

    // Empty-state wording, overridable so the inspector can say WHY
    // there's no chart ("No comparison available for 'addTimeValue'")
    // instead of silently keeping the previous variable's series.
    var placeholderText: String = "No trend" { didSet { needsDisplay = true } }

    // Header pills, right-aligned: "Open ↗" only when there is a chart
    // to open, "Build" always, since the builder reaches the
    // whole file even when this element has nothing to chart.
    private func drawHeaderPills(ctx: CGContext) {
        popoutButtonRect = .zero
        buildButtonRect = .zero
        let textFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let padX: CGFloat = 10
        var rightEdge = bounds.width - 6
        if onPopoutRequested != nil, series != nil {
            // Not white: on the Hacker theme the accent is neon green and
            // white on it is barely legible. The deep background colour
            // reads on every palette.
            let as_ = NSAttributedString(string: "Open ↗", attributes: [
                .font: textFont, .foregroundColor: XMColor.bgDeep])
            let textSize = as_.size()
            let r = NSRect(x: rightEdge - textSize.width - padX * 2,
                           y: bounds.height - textSize.height - 10,
                           width: textSize.width + padX * 2,
                           height: textSize.height + 6)
            popoutButtonRect = r
            let pillPath = CGPath(roundedRect: r, cornerWidth: r.height / 2,
                                  cornerHeight: r.height / 2, transform: nil)
            ctx.addPath(pillPath)
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.95).cgColor)
            ctx.fillPath()
            ctx.addPath(pillPath)
            ctx.setStrokeColor(XMColor.accent.cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            as_.draw(at: NSPoint(x: r.minX + padX, y: r.minY + (r.height - textSize.height) / 2))
            rightEdge = r.minX - 8
        }
        if onBuildRequested != nil {
            let bAS = NSAttributedString(string: "Build", attributes: [
                .font: textFont, .foregroundColor: XMColor.accent])
            let bSize = bAS.size()
            let br = NSRect(x: rightEdge - bSize.width - padX * 2,
                            y: bounds.height - bSize.height - 10,
                            width: bSize.width + padX * 2, height: bSize.height + 6)
            buildButtonRect = br
            let bPath = CGPath(roundedRect: br, cornerWidth: br.height / 2,
                               cornerHeight: br.height / 2, transform: nil)
            ctx.addPath(bPath)
            ctx.setFillColor(XMColor.accent.withAlphaComponent(0.14).cgColor)
            ctx.fillPath()
            ctx.addPath(bPath)
            ctx.setStrokeColor(XMColor.accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokePath()
            bAS.draw(at: NSPoint(x: br.minX + padX, y: br.minY + (br.height - bSize.height) / 2))
        }
    }

    private func drawPlaceholder(ctx: CGContext) {
        let t = NSAttributedString(string: placeholderText, attributes: [
            .font: XMFont.uiCaption,
            .foregroundColor: XMColor.text3
        ])
        let s = t.size()
        t.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }

    private func formatNumber(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if v == 0 { return "0" }
        if abs < 0.001 || abs >= 10_000 {
            return String(format: "%.2e", v)
        }
        let f = NumberFormatter()
        f.maximumSignificantDigits = 4
        f.minimumSignificantDigits = 1
        f.usesSignificantDigits = true
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
