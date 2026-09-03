import Cocoa

// First-launch tour (v1.0). Short by design: the screen dims except
// for the control being explained, one text box with bullets, a page
// number like 1/6, Escape or Close to leave, and it stays reachable
// from Help. Six pages; each cuts the control it talks about out of
// the dim layer. Built as a borderless child window over the document
// window so the toolbar dims too.
struct TourPage {
    let title: String
    let lines: [String]
    let anchors: [String]
}

enum TourPages {
    static let all: [TourPage] = [
        TourPage(title: "Four ways to look at a file", lines: [
            "Simple: the tree, a big source editor and the subtags strip.",
            "Inspect: adds the details rail (Inspector, Chart, Preview, Errors).",
            "Full: every pane at once.",
            "Learn: an AI chat beside your file. Select any text in the source, or right-click an element in the tree, and choose ✨ Define in Learn: the question is typed into the chat you picked, ready to send. Two buttons there are for the whole file: 📁 Folder selects it in Finder so you can drag it into the chat, and Copy File puts every line on the clipboard. Dragging beats pasting for anything large: drag an element out of the tree, or text you have selected in the source, straight into the chat box, or drop the file itself on the page.",
        ], anchors: ["workspace"]),
        TourPage(title: "Mark what matters", lines: [
            "Take the marker from the toolbar, or Edit ▸ Marker, and the pointer becomes a pen.",
            "Drag over words to mark them, click a line to mark the whole line, drag the same colour again to rub it out. Escape puts the pen away.",
            "The ⌄ next to the pen holds the four colours, the eraser and Remove All Marks; the ⌄ in a circle after it walks from one mark to the next, shift-click for the one before. Every mark also shows as a coloured tick on the minimap, and they stay with the file after you close it.",
        ], anchors: ["marker"]),
        TourPage(title: "The map beside the source", lines: [
            "Left half: hover and it snaps to the elements at your current level, so a click hops element by element.",
            "Right half: moves freely by line. Hover for a magnifier, click or drag to go there.",
            "Do not want it? The small × at its top corner puts it away and the editor takes the whole width. View ▸ Show Minimap (⇧⌘M) brings it back.",
        ], anchors: ["minimap"]),
        TourPage(title: "Diff", lines: [
            "Compare two open files side by side, walk the differences with Next and Previous, and copy a block from either side into the other.",
        ], anchors: ["diff"]),
        TourPage(title: "Search", lines: [
            "Simple: type in the search box and press Return to jump to the next match.",
            "Advanced: the magnifier opens Find & Replace, with Find All, Replace All, whole word and element scope.",
        ], anchors: ["search", "find"]),
        TourPage(title: "Orbit", lines: [
            "A map of the selected element: its children orbit around it, siblings arc above. Click to travel, use the right panel to move or edit, and turn on Structure only to hide plain values.",
        ], anchors: ["orbit"]),
        TourPage(title: "The details rail", lines: [
            "Inspector: attributes and text of the selected element, editable.",
            "Chart: numbers that repeat inside the element, drawn over years or across siblings.",
            "Preview: the element's raw XML.",
            "Errors: XML problems with one-click fixes; a red badge shows the count.",
        ], anchors: ["details"]),
        TourPage(title: "Zoom", lines: [
            "The slider at the bottom right scales the whole app, text and panes together, from 50% to 200%. Use − and + for small steps, ↺ to reset. It is remembered next time.",
            "One pane, or one window, zooms on its own too: hold ⌘ and turn the wheel over it, or pinch the trackpad the way you would on a photo. ⌘ + and ⌘ − do the same for whichever pane has the focus, and ⌘ 0 puts that one back.",
            "Diff, Orbit, a chart in its own window, Find and Replace and the validation list each carry their own zoom, so making one bigger leaves the rest alone.",
        ], anchors: ["zoom"]),
        TourPage(title: "You're set", lines: [
            "Drop any XML file onto the window to open it. Right-click almost anything. This tour is always in Help ▸ Show Tour.",
        ], anchors: []),
    ]
}

private final class TourWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TourWindowController: NSWindowController {
    private let overlay = TourOverlayView()
    private let card = TourCard()
    private weak var host: NSWindow?
    private let anchorProvider: (String) -> NSRect?
    private let pages: [TourPage]
    private var index = 0
    private var observers: [NSObjectProtocol] = []
    var onClose: (() -> Void)?

    init(host: NSWindow, pages: [TourPage], anchorProvider: @escaping (String) -> NSRect?) {
        self.host = host
        self.pages = pages
        self.anchorProvider = anchorProvider
        let win = TourWindow(contentRect: host.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.appearance = ThemeManager.current.appearance
        win.contentView = overlay
        super.init(window: win)
        overlay.addSubview(card)
        overlay.onAdvance = { [weak self] in self?.step(1) }
        overlay.onBack = { [weak self] in self?.step(-1) }
        overlay.onEscape = { [weak self] in self?.finish() }
        card.onNext = { [weak self] in self?.step(1) }
        card.onBack = { [weak self] in self?.step(-1) }
        card.onClose = { [weak self] in self?.finish() }
        host.addChildWindow(win, ordered: .above)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main) { [weak self] _ in self?.relayout() })
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func present() {
        index = 0
        relayout()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(overlay)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next >= pages.count { finish(); return }
        index = max(0, next)
        relayout()
    }

    func finish() {
        guard let win = window else { return }
        host?.removeChildWindow(win)
        win.orderOut(nil)
        onClose?()
        host?.makeKeyAndOrderFront(nil)
    }

    private func relayout() {
        guard let win = window, let host else { return }
        win.setFrame(host.frame, display: false)
        let page = pages[index]
        // Screen rects → this window's coordinates (same origin as the host).
        let rects = page.anchors.compactMap { anchorProvider($0) }.map { r -> NSRect in
            NSRect(x: r.minX - host.frame.minX, y: r.minY - host.frame.minY, width: r.width, height: r.height)
        }
        // One frame round the whole group: neighbouring controls read as a
        // single thing to look at, not as several separate spotlights.
        let holes: [NSRect] = rects.count > 1
            ? [rects.dropFirst().reduce(rects[0]) { $0.union($1) }] : rects
        overlay.holes = holes
        card.configure(page: page, position: "\(index + 1)/\(pages.count)",
                       isFirst: index == 0, isLast: index == pages.count - 1)
        var size = card.fittingSize
        // The band the card may use: the window, cropped to the part of the
        // screen that is not the menu bar or the Dock. The host window can
        // reach under both; the card must not follow it there.
        var band = overlay.bounds
        if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
            let local = NSRect(x: visible.minX - host.frame.minX, y: visible.minY - host.frame.minY,
                               width: visible.width, height: visible.height)
            if !local.intersection(band).isEmpty { band = local.intersection(band) }
        }
        size.width = min(size.width, max(160, band.width - 24))
        size.height = min(size.height, max(80, band.height - 24))
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            hi < lo ? lo : min(max(v, lo), hi)
        }
        var origin: NSPoint
        if let union = holes.first {
            // Under the group, else beside it (left, then right), else above.
            let below = union.minY - 18 - size.height
            let left = union.minX - 18 - size.width
            let right = union.maxX + 18
            if below >= band.minY + 12 {
                origin = NSPoint(x: union.midX - size.width / 2, y: below)
            } else if left >= band.minX + 12 {
                origin = NSPoint(x: left, y: union.maxY - size.height)
            } else if right + size.width <= band.maxX - 12 {
                origin = NSPoint(x: right, y: union.maxY - size.height)
            } else {
                origin = NSPoint(x: union.midX - size.width / 2, y: union.maxY + 18)
            }
        } else {
            origin = NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2)
        }
        origin.x = clamp(origin.x, band.minX + 12, band.maxX - size.width - 12)
        origin.y = clamp(origin.y, band.minY + 12, band.maxY - size.height - 12)
        card.frame = NSRect(origin: origin, size: size)
        overlay.needsDisplay = true
    }
}

// Dim layer with rounded cut-outs; clicks and keys drive the pages.
final class TourOverlayView: NSView {
    var holes: [NSRect] = [] { didSet { needsDisplay = true } }
    var onAdvance: (() -> Void)?
    var onBack: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.windingRule = .evenOdd
        for h in holes {
            path.append(NSBezierPath(roundedRect: h.insetBy(dx: -7, dy: -7), xRadius: 9, yRadius: 9))
        }
        XMColor.bgDeep.withAlphaComponent(ThemeManager.current.isDark ? 0.6 : 0.35).setFill()
        path.fill()
        for h in holes {
            let ring = NSBezierPath(roundedRect: h.insetBy(dx: -7, dy: -7), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            XMColor.accent.setStroke()
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onAdvance?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()                       // Escape
        case 123: onBack?()                        // ←
        case 124, 36, 49: onAdvance?()             // →, Return, Space
        default: super.keyDown(with: event)
        }
    }
}

// The text box: title, bullets, page counter, Back / Next / Close.
final class TourCard: NSView {
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private static let width: CGFloat = 400

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = XMColor.panel.withAlphaComponent(0.98).cgColor
        layer?.borderColor = XMColor.accent.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1

        title.font = XMFont.ui(15, .semibold)
        title.textColor = XMColor.text
        body.font = XMFont.ui(12.5, .regular)
        body.textColor = XMColor.text2
        body.preferredMaxLayoutWidth = Self.width - 40
        counter.font = XMFont.uiCaption
        counter.textColor = XMColor.text3

        for (b, sel) in [(backButton, #selector(back(_:))), (nextButton, #selector(next(_:))), (closeButton, #selector(close(_:)))] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            b.action = sel
        }
        nextButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"

        for v in [title, body, counter, backButton, nextButton, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            counter.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            counter.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: counter.trailingAnchor, constant: 12),
            nextButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            nextButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: backButton.leadingAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(page: TourPage, position: String, isFirst: Bool, isLast: Bool) {
        title.stringValue = page.title
        body.stringValue = page.lines.count == 1
            ? page.lines[0]
            : page.lines.map { "•  " + $0 }.joined(separator: "\n\n")
        counter.stringValue = position
        backButton.isEnabled = !isFirst
        nextButton.title = isLast ? "Done" : "Next"
        layoutSubtreeIfNeeded()
    }

    @objc private func back(_ sender: Any?) { onBack?() }
    @objc private func next(_ sender: Any?) { onNext?() }
    @objc private func close(_ sender: Any?) { onClose?() }
}
