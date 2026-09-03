import Cocoa

// NSTextView subclass that paints a single-line background highlight
// without touching the text storage or layout manager internals. The
// previous approach used temporary attributes on NSLayoutManager, but
// that interacts badly with allowsNonContiguousLayout + on-demand
// glyph generation and crashed in fillGlyphHoleForCharacterRange.
//
// Instead we draw a rectangle ourselves in `draw(_:)` at the Y
// position computed from the line number and the font's line height.
// Monospaced font + no wrapping in practice means this is pixel-
// perfect for GCAM XML.
final class HighlightingTextView: XMLDropForwardingTextView {
    // We highlight by CHARACTER RANGE, not line number, so the draw
    // uses the layout manager's own bounding-rect query instead of
    // our own line-height math. That avoids the ~2-line drift we saw
    // with the font-height estimate: NSTextView's real per-line
    // spacing differs from font.boundingRectForFont.height by a few
    // points, and the error compounds down the document.
    //
    // boundingRect(forGlyphRange:in:) is safe with
    // allowsNonContiguousLayout = true, it lays out only what's
    // needed for this range.
    var highlightedCharRange: NSRange? {
        didSet {
            guard highlightedCharRange != oldValue else { return }
            if let old = oldValue { invalidateForRange(old) }
            if let new = highlightedCharRange { invalidateForRange(new) }
        }
    }
    // The WHOLE selected element (opening-tag line through closing-tag
    // line) gets a soft wash + full-height stripe: selecting <region>
    // marks the whole region, not just its first line.
    // Drawing needs layout only at the two ENDPOINT lines, so this is
    // O(1) even when <region> spans 400k lines of a 655 MB file.
    var highlightedBoxRange: NSRange? {
        didSet {
            guard highlightedBoxRange != oldValue else { return }
            needsDisplay = true
        }
    }
    // Per-theme muted editor-selection color (VS Code-style), the
    // old accent-alpha band read as abnormally loud.
    var highlightColor: NSColor = XMColor.lineHighlight
    var highlightStripeColor: NSColor = XMColor.accent

    // The marker's strokes, drawn over exactly the marked characters.
    var markerStrokes: TextHighlights?
    /// While the marker is on the pointer becomes a pen and a drag paints.
    var markerOn = false {
        didSet {
            guard markerOn != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The colour the pointer is drawn in, so the pen in your hand is the
    /// colour it will paint with.
    var markerCursorColor: NSColor = XMColor.marker(.yellow) {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    /// Fired on mouse-up while the marker is on, with the range the user
    /// dragged over (empty when it was a plain click).
    var onMarkerStroke: ((NSRange) -> Void)?
    /// Escape leaves marker mode.
    var onMarkerCancel: (() -> Void)?

    // Use `lineFragmentRect(forGlyphAt:)` to get exactly ONE line's
    // fragment. boundingRect(forGlyphRange:) can return a two-line
    // rect when the range touches a line boundary (glyphs for a full
    // line + the trailing newline can straddle fragments). Using the
    // line fragment of the FIRST glyph guarantees single-line height.
    private func lineFragmentViewRect(for range: NSRange) -> NSRect? {
        guard range.length > 0, let lm = layoutManager, textContainer != nil else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var effective = NSRange()
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location,
                                           effectiveRange: &effective)
        return NSRect(x: 0,
                      y: lineRect.origin.y + textContainerOrigin.y,
                      width: bounds.width,
                      height: lineRect.height)
    }

    private func invalidateForRange(_ range: NSRange) {
        if let r = lineFragmentViewRect(for: range) {
            setNeedsDisplay(r)
        } else {
            needsDisplay = true
        }
    }

    // Band covering the box range: from the first line fragment's top
    // to the last line fragment's bottom, full width. Only the two
    // endpoint glyphs are laid out.
    private func boxViewRect(for range: NSRange) -> NSRect? {
        guard range.length > 0, let lm = layoutManager, textContainer != nil else { return nil }
        let startG = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                   actualCharacterRange: nil)
        let lastLoc = max(range.location, NSMaxRange(range) - 1)
        let endG = lm.glyphRange(forCharacterRange: NSRange(location: lastLoc, length: 1),
                                 actualCharacterRange: nil)
        guard startG.length > 0, endG.length > 0 else { return nil }
        var eff = NSRange()
        let r1 = lm.lineFragmentRect(forGlyphAt: startG.location, effectiveRange: &eff)
        let r2 = lm.lineFragmentRect(forGlyphAt: endG.location, effectiveRange: &eff)
        let minY = min(r1.minY, r2.minY) + textContainerOrigin.y
        let maxY = max(r1.maxY, r2.maxY) + textContainerOrigin.y
        return NSRect(x: 0, y: minY, width: bounds.width, height: maxY - minY)
    }

    // Chrome-style middle-click autoscroll: one middle click arms it
    // (anchor set under the cursor), moving the mouse up/down scrolls
    // with speed proportional to the distance, and a second click, 
    // middle or left, disarms. No click-and-hold needed.
    private var autoScrollTimer: Timer?
    private var autoScrollAnchor: NSPoint?   // window coordinates

    override func otherMouseDown(with event: NSEvent) {
        // buttonNumber 2 = middle wheel click.
        if event.buttonNumber == 2 {
            if autoScrollTimer != nil { stopAutoScroll() } else { startAutoScroll(event) }
            return
        }
        super.otherMouseDown(with: event)
    }

    // ⌘-click an underlined linked file opens it, like a hyperlink.
    var onOpenLinkedFile: ((URL) -> Void)?

    private func linkAttribute(at event: NSEvent) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard idx >= 0, idx < storage.length else { return nil }
        return storage.attribute(SyntaxHighlighter.linkKey, at: idx, effectiveRange: nil) as? URL
    }

    override func mouseDown(with event: NSEvent) {
        if autoScrollTimer != nil { stopAutoScroll(); return }
        if event.modifierFlags.contains(.command),
           let url = linkAttribute(at: event) ?? linkedFile(at: event) {
            onOpenLinkedFile?(url)
            return
        }
        super.mouseDown(with: event)
        // NSTextView runs its OWN event loop inside mouseDown and tracks
        // the drag there, so mouseUp never reaches the view. The marker
        // therefore paints when mouseDown RETURNS, by which point the
        // selection is exactly the words that were dragged over.
        if markerOn { onMarkerStroke?(selectedRange()) }
    }

    private func startAutoScroll(_ event: NSEvent) {
        autoScrollAnchor = event.locationInWindow
        NSCursor.resizeUpDown.set()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
        RunLoop.main.add(t, forMode: .common)
        autoScrollTimer = t
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollAnchor = nil
        NSCursor.iBeam.set()
    }

    private func autoScrollTick() {
        guard let anchor = autoScrollAnchor, let win = window,
              let sv = enclosingScrollView else { stopAutoScroll(); return }
        let mouse = win.mouseLocationOutsideOfEventStream
        let dy = mouse.y - anchor.y          // window coords: +y is up
        let dead: CGFloat = 6
        guard abs(dy) > dead else { return }
        // Speed grows with distance from the anchor, move a little
        // for a crawl, a lot for a sprint (like Chrome).
        let speed = (abs(dy) - dead) * 0.35
        var origin = sv.contentView.bounds.origin
        origin.y += dy < 0 ? speed : -speed  // mouse below anchor → scroll down
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
        origin.y = max(0, min(maxY, origin.y))
        sv.contentView.setBoundsOrigin(origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    // Right-click with a selection gains a "Share Selection ▸" side
    // menu (same targets as the Share menu bar). Actions resolve up
    // the responder chain to MainWindowController.
    // Config-style entries under the pointer (../input/foo.xml) open in a
    // new tab; MainWindowController supplies the resolver because only it
    // knows the document's folder.
    var linkedFileResolver: ((String) -> URL?)?

    private func linkedFile(at event: NSEvent) -> URL? {
        guard let resolver = linkedFileResolver, let storage = textStorage else { return nil }
        let ns = storage.mutableString
        guard ns.length > 0 else { return nil }
        let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let lr = ns.lineRange(for: NSRange(location: max(0, min(idx, ns.length - 1)), length: 0))
        guard lr.length > 0, lr.length < 4000 else { return nil }
        let line = ns.substring(with: lr) as NSString
        var candidates: [String] = []
        for pattern in ["=\"([^\"]+)\"", ">([^<>]+)<"] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: line as String, range: NSRange(location: 0, length: line.length))
            where m.numberOfRanges > 1 {
                candidates.append(line.substring(with: m.range(at: 1)))
            }
        }
        return candidates.lazy.compactMap(resolver).first
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let url = linkedFile(at: event) {
            let it = NSMenuItem(title: "Open Linked File: \(url.lastPathComponent)",
                                action: #selector(MainWindowController.openLinkedFileFromMenu(_:)),
                                keyEquivalent: "")
            it.representedObject = url
            menu.insertItem(it, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        guard selectedRange().length > 0 else { return menu }
        menu.addItem(.separator())
        // Define in Learn sits at the top level, not only inside Share.
        menu.addItem(NSMenuItem(title: "✨ Define in Learn",
                                action: #selector(MainWindowController.learnChipClicked(_:)),
                                keyEquivalent: ""))
        let shareItem = NSMenuItem(title: "Share Selection", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Share Selection")
        for target in LLMTarget.allCases {
            let it = NSMenuItem(title: "Send to \(target.displayName)",
                                action: #selector(MainWindowController.shareToLLM(_:)),
                                keyEquivalent: "")
            it.representedObject = [target.rawValue, "selection"]
            sub.addItem(it)
        }

        sub.addItem(NSMenuItem(title: "Print Selection…",
                               action: #selector(MainWindowController.sharePrintSelection(_:)),
                               keyEquivalent: ""))
        shareItem.submenu = sub
        menu.addItem(shareItem)
        return menu
    }

    /// A pen while the marker is on, so it is obvious the next drag will
    /// paint rather than select.
    override func resetCursorRects() {
        if markerOn {
            addCursorRect(bounds, cursor: penCursor)
        } else {
            super.resetCursorRects()
        }
    }

    private var penCursor: NSCursor { Self.markerCursor(markerCursorColor) }

    private static var cursorCache: [String: NSCursor] = [:]

    /// A highlighter, drawn: a chisel tip at the pointer, a pale collar
    /// and a barrel in the marker's own colour, leaning back the way a
    /// pen does in the hand. An emoji was too vague to read as "this
    /// paints now".
    static func markerCursor(_ color: NSColor) -> NSCursor {
        let key = color.description
        if let hit = cursorCache[key] { return hit }
        let size = NSSize(width: 28, height: 28)
        let tip = NSPoint(x: 5, y: 5)              // in bottom-left coordinates
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        ctx.rotate(by: -.pi / 4)                   // tip down-left, barrel up-right

        // Pen space: the tip sits at the origin and the barrel runs up.
        let w: CGFloat = 8
        let nib = NSBezierPath()
        nib.move(to: NSPoint(x: 1, y: 0))
        nib.line(to: NSPoint(x: w - 1, y: 0))
        nib.line(to: NSPoint(x: w, y: 4.5))
        nib.line(to: NSPoint(x: 0, y: 4.5))
        nib.close()

        let collar = NSBezierPath(rect: NSRect(x: 0, y: 4.5, width: w, height: 2.5))
        let barrel = NSBezierPath(roundedRect: NSRect(x: 0, y: 7, width: w, height: 13),
                                  xRadius: 2, yRadius: 2)

        // A white edge first, so the pen reads on a dark editor too.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for path in [nib, collar, barrel] {
            path.lineWidth = 2.2
            path.stroke()
        }

        color.withAlphaComponent(1).setFill()
        barrel.fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        collar.fill()
        color.withAlphaComponent(0.55).setFill()
        nib.fill()

        NSColor(white: 0.15, alpha: 0.85).setStroke()
        for path in [nib, collar, barrel] {
            path.lineWidth = 0.9
            path.stroke()
        }
        ctx.restoreGState()
        image.unlockFocus()

        // hotSpot is measured from the TOP-left of the image.
        let cursor = NSCursor(image: image,
                              hotSpot: NSPoint(x: tip.x, y: size.height - tip.y))
        cursorCache[key] = cursor
        return cursor
    }

    override func cancelOperation(_ sender: Any?) {
        if markerOn { onMarkerCancel?() } else { super.cancelOperation(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Soft wash over the entire selected element, drawn first so
        // the landing-line band stays the strongest signal.
        if let box = highlightedBoxRange, let br = boxViewRect(for: box),
           dirtyRect.intersects(br) {
            highlightColor.withAlphaComponent(0.10).set()
            br.fill()
            highlightStripeColor.withAlphaComponent(0.55).set()
            NSRect(x: br.origin.x, y: br.origin.y, width: 2, height: br.height).fill()
        }
        // Marker strokes, over the wash and under the landing band.
        //
        // Bounded on purpose: only the characters actually on screen are
        // asked about. An earlier attempt at drawing over filler rows in
        // the Diff walked every run on every repaint and hung the app, so
        // nothing here asks the layout engine about more than the visible
        // rectangle.
        if let strokes = markerStrokes, !strokes.isEmpty,
           let lm = layoutManager, let tc = textContainer, let storage = textStorage {
            let visibleGlyphs = lm.glyphRange(forBoundingRect: dirtyRect, in: tc)
            let visible = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            let origin = textContainerOrigin
            let whole = NSRange(location: 0, length: storage.length)
            for stroke in strokes.intersecting(from: visible.location, to: NSMaxRange(visible)) {
                let clamped = NSIntersectionRange(NSRange(location: stroke.start, length: stroke.length), whole)
                guard clamped.length > 0 else { continue }
                let gr = lm.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
                XMColor.marker(stroke.color).setFill()
                lm.enumerateEnclosingRects(forGlyphRange: gr,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: tc) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
        }

        guard let range = highlightedCharRange,
              let r = lineFragmentViewRect(for: range),
              dirtyRect.intersects(r) else { return }
        // Fill highlight
        highlightColor.set()
        r.fill()
        // 2 pt left accent stripe (Aurora touch)
        let stripe = NSRect(x: r.origin.x, y: r.origin.y, width: 2, height: r.height)
        highlightStripeColor.set()
        stripe.fill()
    }
}

// Full-file source editor using TextKit 2 (NSTextLayoutManager).
//
// TextKit 2 lays out only the visible viewport on demand, so a 655 MB
// document can scroll smoothly after the initial content load. The
// entire file is loaded into the content storage, this takes a few
// seconds on 655 MB but produces a normal editor where the whole file
// is visible and every character is editable.
//
// Parse-time line index gives byte-accurate jump-to-line for tree
// selections. We keep the same LineIndex here but repurpose it to map
// *line numbers* to *character offsets within the loaded text*, which
// is what TextKit needs.
final class SourceViewController: NSViewController {
    private var scroll: NSScrollView!
    private var textView: NSTextView!
    // TextKit 1 (default NSTextView) with non-contiguous layout is the
    // key to fast navigation on huge documents. TextKit 2 forced us to
    // lay out everything from the top to any click destination
    // (~30 s on 655 MB). TextKit 1 + allowsNonContiguousLayout = true
    // lets the layout manager skip directly to the target viewport.
    private var textStorageRef: NSTextStorage? { textView?.textStorage }
    private let header = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var currentURL: URL?
    private var fileSize: Int = 0
    private(set) var currentTextEncoding: XMLTextEncoding = .utf8
    // Map from line-number (1-based) → character offset within the
    // currently-loaded text. Computed on load.
    private var lineStarts: [Int] = [0]
    // Previously used for in-editor temp-attribute highlights; removed
    // because it proved unsafe with allowsNonContiguousLayout on huge
    // docs (crashes in NSLayoutManager.fillGlyphHoleForCharacterRange).
    // We now surface the selected-element view via a separate Element
    // Preview window instead.
    private var highlightedRanges: [NSRange] = []

    // Fires after the text storage changed (debounced 200 ms). The
    // parent controller uses it to live-refresh the inspector when the
    // user types directly in the source editor.
    var onSourceChanged: (() -> Void)?
    // Fires once after the file finishes loading AND lineStarts has
    // been populated. Needed because loadFile(url:fileSize:) kicks
    // off an async file read, anything that depends on lineStarts
    // (the minimap in particular) must wait for this callback.
    var onFileLoaded: (() -> Void)?
    // A failed read or decode must unwind the loading tab. Previously the
    // editor stayed locked forever, and invalid UTF-8 became an empty string.
    var onFileLoadFailed: ((_ message: String) -> Void)?
    // Fires on EVERY real document mutation (typed or programmatic)
    //, powers the unsaved-changes ("dirty") flag. Loads are excluded
    // via suppressMutationEvents.
    var onDocumentMutated: (() -> Void)?
    private var suppressMutationEvents = false
    var onSelectionChanged: (() -> Void)?

    // Set during inspector-driven edits so the observer knows to skip
    // scheduling an inspector refresh (we'll refresh ourselves).
    // lineStarts is still maintained via the observer for both paths.
    private var applyingProgrammaticEdit: Bool = false
    private var sourceDebounce: DispatchWorkItem?

    private var highlighter: SyntaxHighlighter?
    // Linked-file resolver for the hyperlink pass (set by MainWindowController).
    var linkedFileResolver: ((String) -> URL?)? {
        didSet { highlighter?.linkResolver = linkedFileResolver }
    }
    // Exposed so MainWindowController can tell the highlighter to
    // clear its chunk cache after a theme switch (the cached color
    // attributes reference the OLD palette).
    var exposedHighlighter: SyntaxHighlighter? { highlighter }

    // Left-side line-number gutter. Visibility is driven by
    // `setLineNumbersVisible(_:)`, which the View menu toggles.
    // Restored from UserDefaults so the pref sticks across launches.
    private var lineNumberRuler: LineNumberRulerView?
    private static let lineNumbersPrefKey = "xml-macker.showLineNumbers"
    var isLineNumberVisibilityPersistedOn: Bool {
        UserDefaults.standard.object(forKey: Self.lineNumbersPrefKey) == nil
            ? true   // default ON for a first-run user
            : UserDefaults.standard.bool(forKey: Self.lineNumbersPrefKey)
    }

    // Source-editor zoom level: VS Code-style ⌘+/⌘- resizes the
    // source text. We compose a scaled font from the base
    // size on the fly so it round-trips cleanly through save/reload
    // (no persisted state to get out of sync).
    // baseFontSize is now a computed property that folds in the global
    // zoom slider. Each per-pane zoomStep still stacks on top, so
    // ⌘+/⌘- keeps working at any global scale. Clamped inside
    // currentFontSize so extremes don't break glyph layout.
    private var baseFontSize: CGFloat { 12 * XMFont.globalScale }
    private var zoomStep: Int = 0
    private var currentFontSize: CGFloat {
        // Clamped 5pt…40pt to accommodate global-scale × per-pane-zoom.
        max(5, min(40, baseFontSize + CGFloat(zoomStep)))
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = XMFont.uiCaption
        header.textColor = XMColor.text3
        header.lineBreakMode = .byTruncatingMiddle
        v.addSubview(header)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        v.addSubview(spinner)

        // Vanilla NSTextView uses TextKit 1 (NSLayoutManager), whose
        // allowsNonContiguousLayout flag enables O(1) jumps to any
        // viewport position without laying out intervening text.
        textView = HighlightingTextView(frame: .zero)
        // Non-contiguous layout is the fast-click win; do NOT also
        // enable background layout, its interaction with temp
        // attributes + on-demand glyph generation can crash
        // (fillGlyphHoleForCharacterRange in NSLayoutManager).
        textView.layoutManager?.allowsNonContiguousLayout = true
        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTextStorageEdited(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        // Per-tab undo (v0.35.0): NSTextView asks its delegate for the
        // undo manager; each DocumentSession owns one so undoing in
        // one tab can never replay ranges into another document.
        textView.delegate = self
        // Standard macOS find bar (with its built-in replace field).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = XMFont.monoCode
        textView.textColor = XMColor.text
        textView.backgroundColor = XMColor.bgDeep
        textView.drawsBackground = true
        textView.insertionPointColor = XMColor.accent
        pushMarkerState()
        textView.selectedTextAttributes = [
            .backgroundColor: XMColor.lineHighlight
        ]
        // Kill all the "helpful" auto-substitutions that corrupt XML:
        // smart quotes turn `"` into `“ ”` which breaks attribute regex
        // and actually breaks the XML; dashes turn `--` into `, `; auto
        // spelling/grammar adds noise. Editors for code/markup must
        // have these off.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = XMColor.bgDeep
        scroll.documentView = textView
        highlighter = SyntaxHighlighter(textView: textView, scrollView: scroll)
        highlighter?.linkResolver = linkedFileResolver

        // Left-side line-number gutter. Ruler-view AppKit idiom:
        // NSRulerView attached to the scroll view's vertical ruler
        // slot, with clientView = textView so drawing coords stay in
        // sync with scrolling. We route bounds-changed notifications
        // (emitted by scroll.contentView.postsBoundsChangedNotifications)
        // to invalidate the ruler so numbers track the viewport.
        let ruler = LineNumberRulerView(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = isLineNumberVisibilityPersistedOn
        self.lineNumberRuler = ruler
        // The SyntaxHighlighter already makes the clipView post
        // bounds-changed notifications; piggyback on that so the
        // ruler redraws on scroll. Frame-change too (window resize).
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak ruler] _ in ruler?.needsDisplay = true }
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak ruler] _ in ruler?.needsDisplay = true }

        v.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        view = v
    }

    // MARK: Public API

    func loadFile(url: URL, fileSize: Int) {
        self.currentURL = url
        self.fileSize = fileSize
        self.lineStarts = [0]

        let mb = Double(fileSize) / 1024 / 1024
        header.stringValue = "\(url.lastPathComponent) · \(String(format: "%.1f", mb)) MB · loading…"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        suppressMutationEvents = true
        textView.string = ""
        suppressMutationEvents = false
        textView.isEditable = false // locked during load

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // Data(.alwaysMapped) avoids a full physical read upfront.
                let data = try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
                let decoded = try XMLTextEncoding.decode(data)
                let startsIndex = Self.buildLineStarts(in: decoded.text)
                DispatchQueue.main.async {
                    // Ignore an obsolete completion if a different session was
                    // attached while this read was in flight.
                    guard self.currentURL == url else { return }
                    self.currentTextEncoding = decoded.encoding
                    self.applyLoadedText(decoded.text, lineStarts: startsIndex)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                DispatchQueue.main.async {
                    guard self.currentURL == url else { return }
                    self.setErrorHeader("Failed to open \(url.lastPathComponent)")
                    self.onFileLoadFailed?(message)
                }
            }
        }
    }

    // Called when a tree node is selected. Highlights the element's
    // block by marking ONLY its opening-tag line and closing-tag line
    // with a yellow background attribute on the text storage. Two
    // bounded ranges (~100 chars each) regardless of how big the
    // element is. TextKit 2 only applies attribute rendering to
    // visible line fragments, so nothing off-screen costs anything.
    //
    // We deliberately avoid `setSelectedRange` on the full element
    // range, that freezes because selection highlighting forces
    // TextKit to lay out and draw rectangles across every line in
    // the range.
    func showElement(_ node: XMLTreeNode) {
        guard !lineStarts.isEmpty else { return }
        let docLen = (textView.string as NSString).length

        let startRange = lineCharRange(for: node.startLine, docLen: docLen)

        // Ask the layout manager to lay out the target line. With
        // allowsNonContiguousLayout = true this is effectively O(1), 
        // it jumps to the range, lays out just that line, and leaves
        // a gap between it and the previously-laid-out area.
        //
        // Without this step NSTextView's frame height only reflects
        // what's been laid out, so a clip-view scroll past that
        // clamps back, which was why clicking a far-down region did
        // nothing.
        if let lm = textView.layoutManager {
            lm.ensureLayout(forCharacterRange: startRange)
        }

        // Now NSTextView's own scrollRangeToVisible knows the glyph
        // position and scrolls accurately, including extending the
        // clip view's scrollable range.
        textView.scrollRangeToVisible(startRange)

        textView.setSelectedRange(NSRange(location: startRange.location, length: 0))

        if let hv = textView as? HighlightingTextView {
            hv.highlightedCharRange = startRange
            // Whole-element wash: needs layout at the CLOSING line too
            // (cheap with non-contiguous layout, one extra jump).
            if let box = charRangeForElement(node), box.length > 0 {
                let endProbe = NSRange(location: max(box.location, NSMaxRange(box) - 1), length: 1)
                textView.layoutManager?.ensureLayout(forCharacterRange: endProbe)
                hv.highlightedBoxRange = box
            } else {
                hv.highlightedBoxRange = nil
            }
        }
    }

    // Character range of the selected element in the source editor, 
    // from the start of its opening-tag line to the end of its
    // closing-tag line. Used by the Element Preview window to show
    // just that element's bytes.
    func charRangeForElement(_ node: XMLTreeNode) -> NSRange? {
        guard !lineStarts.isEmpty else { return nil }
        let docLen = (textView.string as NSString).length
        let startLine = max(1, min(node.startLine, lineStarts.count))
        let startOff = lineStarts[startLine - 1]
        let endLineIdx = max(node.endLine, node.startLine) + 1
        let endOff: Int
        if endLineIdx <= lineStarts.count {
            endOff = max(startOff, lineStarts[endLineIdx - 1] - 1)
        } else {
            endOff = docLen
        }
        let safeStart = min(startOff, docLen)
        let length = max(0, min(endOff - safeStart, docLen - safeStart))
        return NSRange(location: safeStart, length: length)
    }

    // Returns a bounded substring of the text storage for a character
    // range. Capped so a click on <scenario> (which spans the whole
    // file) doesn't copy 655 MB into the preview window.
    func substring(in range: NSRange, cap: Int = 1_000_000) -> (text: String, truncated: Bool) {
        guard let storage = textStorageRef else { return ("", false) }
        let docLen = storage.length
        if range.location >= docLen { return ("", false) }
        let safeStart = range.location
        let safeLen = min(range.length, docLen - safeStart)
        let clippedLen = min(safeLen, cap)
        let r = NSRange(location: safeStart, length: clippedLen)
        let text = storage.mutableString.substring(with: r)
        return (text, clippedLen < safeLen)
    }

    // Open-ended window from `offset` to the cap (or the document end,
    // whichever comes first). Used by the scoped live validator: after
    // edits the tree's endLine data is stale, so instead of trusting a
    // computed element END, the validator over-extracts from the
    // element's START and lets the linter find the true end itself
    // (it stops once the scope's root element closes).
    // `reachedDocEnd` tells the linter whether "still-open elements at
    // the end of the window" is a real error (true) or just the cut
    // (false).
    func substring(from offset: Int, cap: Int) -> (text: String, reachedDocEnd: Bool) {
        guard let storage = textStorageRef else { return ("", true) }
        let docLen = storage.length
        guard offset < docLen else { return ("", true) }
        var len = min(cap, docLen - offset)
        if offset + len < docLen {
            // Cut on a line boundary so the linter never sees half a tag.
            let nl = storage.mutableString.range(of: "\n", options: .backwards,
                                                 range: NSRange(location: offset, length: len))
            if nl.location != NSNotFound, nl.location > offset { len = nl.location - offset + 1 }
        }
        let text = storage.mutableString.substring(with: NSRange(location: offset, length: len))
        return (text, offset + len >= docLen)
    }

    // Character offset where the element's opening-tag LINE begins in
    // the live text. Start lines stay valid across edits made inside
    // or below the element (the overwhelmingly common case); only
    // newline edits ABOVE the element shift them, and the next full
    // parse re-syncs everything.
    func elementStartOffset(_ node: XMLTreeNode) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        let idx = max(1, min(node.startLine, lineStarts.count)) - 1
        let off = lineStarts[idx]
        let docLen = (textView.string as NSString).length
        return off < docLen ? off : nil
    }

    private func lineCharRange(for line: Int, docLen: Int) -> NSRange {
        guard !lineStarts.isEmpty else { return NSRange(location: 0, length: 0) }
        let clamped = max(1, min(line, lineStarts.count))
        let start = lineStarts[clamped - 1]
        let end: Int
        if clamped < lineStarts.count {
            end = max(start, lineStarts[clamped] - 1) // exclude the \n
        } else {
            end = docLen
        }
        let safeStart = min(start, docLen)
        let length = max(0, min(end - safeStart, docLen - safeStart))
        return NSRange(location: safeStart, length: length)
    }

    // MARK: Text-storage change observer
    //
    // Kept intentionally lightweight: we do NOT iterate `lineStarts`
    // here (that's ~12 M entries on the 655 MB test file, shifting
    // them per keystroke froze the UI). We schedule a debounced
    // callback for source→inspector sync and nothing else.
    //
    // Inspector-driven edits update `lineStarts` manually via
    // applyAttrEdit / applyTextEdit (we know exactly what changed).
    // Direct user typing in the editor leaves lineStarts mildly stale;
    // that only affects scrollToLine / findAttributeValueRange for
    // other parts of the file, which is an acceptable trade vs. freezing.
    @objc private func onTextStorageEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage else { return }
        guard storage.editedMask.contains(.editedCharacters) else { return }
        // Marker strokes move with the text. This is the app's single
        // funnel for a character edit, so every path that changes the
        // document, typing, a fix, a diff copy, drags the strokes along.
        if let strokes = hlView?.markerStrokes {
            let edited = storage.editedRange
            let inserted = edited.length
            let removed = inserted - storage.changeInLength
            strokes.shiftForEdit(start: edited.location, removed: max(0, removed), inserted: inserted)
        }
        if !suppressMutationEvents { onDocumentMutated?() }
        if applyingProgrammaticEdit { return }

        sourceDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSourceChanged?()
        }
        sourceDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
    }

    // Binary-search for the 1-based line number containing charOffset.
    private func lineNumber(at charOffset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charOffset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    // Scan up to 16 KB starting from the node's opening line and return
    // the character range of the node's opening tag (from `<` through `>`
    // with attribute quotes handled). Uses storage.mutableString so the
    // search is in-place, no substring allocation, critical when the
    // search runs many times per tree click or per keystroke.
    private func openingTagRange(for node: XMLTreeNode) -> NSRange? {
        guard !lineStarts.isEmpty else { return nil }
        guard let storage = textStorageRef else { return nil }
        let ns = storage.mutableString
        let docLen = storage.length
        let lineIdx = max(1, min(node.startLine, lineStarts.count)) - 1
        let start = lineStarts[lineIdx]
        let scanLen = min(16384, docLen - start)
        guard scanLen > 0 else { return nil }

        let searchRange = NSRange(location: start, length: scanLen)
        let ltRange = ns.range(of: "<", options: [], range: searchRange)
        guard ltRange.location != NSNotFound else { return nil }

        let endScan = start + scanLen
        var gtLoc = -1
        var inQuote: unichar = 0
        var i = ltRange.location + 1
        while i < endScan {
            let c = ns.character(at: i)
            if inQuote != 0 {
                if c == inQuote { inQuote = 0 }
            } else if c == 0x22 /*"*/ || c == 0x27 /*'*/ {
                inQuote = c
            } else if c == 0x3E /*>*/ {
                gtLoc = i
                break
            }
            i += 1
        }
        guard gtLoc >= 0 else { return nil }
        let length = gtLoc - ltRange.location + 1
        return NSRange(location: ltRange.location, length: length)
    }

    // Returns the character range of `attrName`'s VALUE (between the
    // quotes) within the node's opening tag. Nil if not found.
    private func findAttributeValueRange(node: XMLTreeNode, attrName: String) -> NSRange? {
        guard let tagRange = openingTagRange(for: node) else { return nil }
        guard let storage = textStorageRef else { return nil }
        let ns = storage.mutableString
        // substring(with:) on NSMutableString is a bounded copy (≤ 16 KB
        // since that's our open-tag scan cap). Cheap enough for regex.
        let tagText = ns.substring(with: tagRange)
        let escaped = NSRegularExpression.escapedPattern(for: attrName)
        // Plain alternation, accepts straight or curly quotes (smart-
        // quote substitution may have sneaked them in).
        let pattern = "(?<![\\w\\-.:])\(escaped)\\s*=\\s*(?:[\"\u{201C}\u{201D}]([^\"\u{201C}\u{201D}]*)[\"\u{201C}\u{201D}]|['\u{2018}\u{2019}]([^'\u{2018}\u{2019}]*)['\u{2018}\u{2019}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let tagNs = tagText as NSString
        guard let m = regex.firstMatch(in: tagText,
                                       range: NSRange(location: 0, length: tagNs.length)) else {
            return nil
        }
        // Group 1 = double-quoted value, Group 2 = single-quoted value;
        // exactly one of the two will have location != NSNotFound.
        let dq = m.range(at: 1)
        let sq = m.range(at: 2)
        let v = dq.location != NSNotFound ? dq : sq
        guard v.location != NSNotFound else { return nil }
        return NSRange(location: tagRange.location + v.location, length: v.length)
    }

    // Apply an attribute-value edit: replace the text in the source
    // editor, update the node model, and shift our line-start index for
    // the (small) length delta introduced by the edit. Returns true on
    // success so the caller knows to refresh the tree/inspector.
    //
    // Values are lightly XML-escaped so users can type "&", "<", " " etc.
    // without breaking the attribute.
    func applyAttrEdit(node: XMLTreeNode, attrName: String, newValue: String) -> Bool {
        guard let storage = textStorageRef else { return false }
        guard let range = findAttributeValueRange(node: node, attrName: attrName) else { return false }

        let sanitized = newValue
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let delta = (sanitized as NSString).length - range.length

        applyingProgrammaticEdit = true
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: sanitized)
        storage.endEditing()
        applyingProgrammaticEdit = false

        if let idx = node.attributes.firstIndex(where: { $0.name == attrName }) {
            node.attributes[idx] = (attrName, newValue)
        }

        // Attribute values never contain newlines, so shift lineStarts
        // entries for every line AFTER the edited one by `delta`.
        if delta != 0 {
            let editLine = lineNumber(at: range.location) // 1-based
            lineStarts.withUnsafeMutableBufferPointer { buf in
                if editLine >= 0 && editLine < buf.count {
                    for i in editLine..<buf.count {
                        buf[i] += delta
                    }
                }
            }
        }

        // Clear any stale element highlights that point past the doc end.
        let docLen = storage.length
        highlightedRanges = highlightedRanges.compactMap { r in
            if r.location >= docLen { return nil }
            let safeLen = min(r.length, docLen - r.location)
            return safeLen > 0 ? NSRange(location: r.location, length: safeLen) : nil
        }
        return true
    }

    // Rename an element's tag, BOTH the opening tag and the matching
    // closing tag, as ONE undoable edit (a single ⌘Z restores both).
    // Every touched range is verified to still contain the exact old
    // name before anything is replaced; on any mismatch (stale tree,
    // minified same-name ambiguity) the edit is refused rather than
    // risking a corrupt document.
    func applyTagRename(node: XMLTreeNode, newName: String) -> Bool {
        guard let storage = textStorageRef, !newName.isEmpty else { return false }
        let ns = storage.mutableString
        let oldName = node.name
        let oldLen = (oldName as NSString).length
        guard let openTag = openingTagRange(for: node), openTag.length >= oldLen + 2 else { return false }

        // Verify "<oldName" + delimiter at the recorded position.
        let openName = NSRange(location: openTag.location + 1, length: oldLen)
        guard NSMaxRange(openName) < NSMaxRange(openTag),
              ns.substring(with: openName) == oldName else { return false }
        let after = ns.character(at: NSMaxRange(openName))
        guard after == 0x20 /* space */ || after == 0x3E /* > */ || after == 0x2F /* / */ ||
              after == 0x09 || after == 0x0A || after == 0x0D else { return false }

        // Self-closing ("<a/>") has only one place to rename.
        let isSelfClosing = openTag.length >= 2 &&
            ns.character(at: NSMaxRange(openTag) - 2) == 0x2F

        var closeName: NSRange? = nil
        if !isSelfClosing {
            // The parser recorded which line the element CLOSES on, 
            // search "</oldName>" only within that line and require
            // exactly ONE hit. Pretty-printed XML always has one;
            // minified same-name-twice-on-a-line is refused instead of
            // guessing the wrong close tag.
            guard node.endLine >= 1, node.endLine <= lineStarts.count else { return false }
            let lineStart = lineStarts[node.endLine - 1]
            let lineEnd = node.endLine < lineStarts.count ? lineStarts[node.endLine] : storage.length
            let needle = "</\(oldName)>"
            var searchRange = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
            var hits: [NSRange] = []
            while hits.count < 2 {
                let hit = ns.range(of: needle, options: [], range: searchRange)
                if hit.location == NSNotFound { break }
                hits.append(hit)
                let next = NSMaxRange(hit)
                searchRange = NSRange(location: next, length: max(0, lineEnd - next))
            }
            guard hits.count == 1, hits[0].location >= NSMaxRange(openTag) else { return false }
            closeName = NSRange(location: hits[0].location + 2, length: oldLen)
        }

        // Replace back-to-front so the first edit can't shift the
        // second; grouped so undo restores both tags together.
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        var ok = true
        if let c = closeName { ok = performEdit(range: c, replacement: newName) }
        if ok { ok = performEdit(range: openName, replacement: newName) }
        undo?.endUndoGrouping()
        return ok
    }

    // Character range of the text BETWEEN the node's opening `>` and
    // its matching `</tag>`. Returns nil for self-closing elements or
    // if the closing tag isn't found within a reasonable look-ahead.
    //
    // Uses storage.mutableString.range(of:options:range:) so the search
    // runs in place against the live text buffer, no multi-MB substring
    // copy, which was the main freeze on huge files.
    private func findTextContentRange(for node: XMLTreeNode) -> NSRange? {
        guard let storage = textStorageRef else { return nil }
        guard let tagRange = openingTagRange(for: node) else { return nil }
        let ns = storage.mutableString
        // Self-closing elements end with "/>", their tag range's second-
        // to-last character is '/'.
        if tagRange.length >= 2 {
            let secondLast = ns.character(at: tagRange.location + tagRange.length - 2)
            if secondLast == 0x2F /* '/' */ { return nil }
        }

        let contentStart = tagRange.location + tagRange.length
        let docLen = storage.length
        guard contentStart <= docLen else { return nil }
        let scanLen = min(4 * 1024 * 1024, docLen - contentStart)
        if scanLen <= 0 { return NSRange(location: contentStart, length: 0) }

        let searchRange = NSRange(location: contentStart, length: scanLen)
        let closeTag = "</\(node.name)>"
        let hit = ns.range(of: closeTag, options: [], range: searchRange)
        guard hit.location != NSNotFound else { return nil }
        return NSRange(location: contentStart, length: hit.location - contentStart)
    }

    // Replace a node's TEXT CONTENT with `newText`. Works for both
    // leaf elements like <emiss-coef>0.5</emiss-coef> and any element
    // whose content is a plain string. Not suitable for elements that
    // have child ELEMENTS, the inspector's text-content field is
    // hidden in that case.
    func applyTextEdit(node: XMLTreeNode, newText: String) -> Bool {
        guard let storage = textStorageRef else { return false }
        guard let range = findTextContentRange(for: node) else { return false }

        // XML-escape so the content stays syntactically valid.
        let sanitized = newText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let newNSLen = (sanitized as NSString).length
        let delta = newNSLen - range.length
        let sanitizedContainsNewline = sanitized.contains("\n")

        applyingProgrammaticEdit = true
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: sanitized)
        storage.endEditing()
        applyingProgrammaticEdit = false

        node.textValue = newText

        // For the common case (short numeric / string values with no
        // newlines), fast-shift lineStarts[editLine+1…]. If the new text
        // contains a newline we'd need a full rebuild (~2s), avoid it
        // unless strictly needed.
        if delta != 0 && !sanitizedContainsNewline {
            let editLine = lineNumber(at: range.location)
            lineStarts.withUnsafeMutableBufferPointer { buf in
                if editLine >= 0 && editLine < buf.count {
                    for i in editLine..<buf.count {
                        buf[i] += delta
                    }
                }
            }
        }

        // Drop stale highlights past the new doc end.
        let docLen = storage.length
        highlightedRanges = highlightedRanges.compactMap { r in
            if r.location >= docLen { return nil }
            let len = min(r.length, docLen - r.location)
            return len > 0 ? NSRange(location: r.location, length: len) : nil
        }
        return true
    }

    // Re-read a node's textValue from the current source text.
    //
    // IMPORTANT: bail early for elements that contain child elements, 
    // their text content is always empty (mixed content aside), and a
    // close-tag scan on a container like <region> would chew through
    // many MB of text hunting for </region> that lives far beyond our
    // 4 MB scan window. Doing this eagerly froze the UI on region select.
    func refreshTextValue(for node: XMLTreeNode) {
        if node.children.contains(where: { $0.kind == .element }) {
            node.textValue = ""
            return
        }
        guard let range = findTextContentRange(for: node) else {
            node.textValue = ""
            return
        }
        guard let storage = textStorageRef else { return }
        let docLen = storage.length
        if range.location >= docLen { return }
        let safeLen = min(range.length, docLen - range.location)
        let safe = NSRange(location: range.location, length: safeLen)
        let raw = storage.attributedSubstring(from: safe).string
        let decoded = raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        node.textValue = decoded
    }

    // Rebuild the entire line-start index from the given storage. Used
    // when an edit introduces newlines we can't delta-shift.
    /// Fires whenever the line index is rebuilt, so views that cache a
    /// copy of it (the minimap) do not drift out of step with the text.
    var onLineStartsChanged: (([Int]) -> Void)?

    private func rebuildLineStarts(from storage: NSTextStorage) {
        let text = storage.string
        lineStarts = Self.buildLineStarts(in: text)
        onLineStartsChanged?(lineStarts)
    }

    // Re-parse the node's attribute list from the current text in the
    // source editor. Called when a tree node becomes selected so that
    // direct edits typed into the source pane are picked up.
    func refreshAttributes(for node: XMLTreeNode) {
        guard let tagRange = openingTagRange(for: node) else {
            Diag.log("refreshAttributes: node=\(node.name) no tagRange")
            return
        }
        guard let storage = textStorageRef else { return }
        let tagText = storage.mutableString.substring(with: tagRange)
        // The tag's own text is deliberately not logged: a log is a file
        // on disk, and the document belongs to whoever opened it.
        Diag.log("refreshAttributes: node=\(node.name) tagRange=\(tagRange) length=\(tagText.count)")

        // Pick up the tag NAME too, the first identifier after `<`.
        // Without this, renaming <Non-CO2> to <Non-sdf> in the source
        // editor wouldn't propagate to the tree / inspector title.
        if let nameRegex = try? NSRegularExpression(pattern: "<\\s*([A-Za-z_][\\w\\-.:]*)") {
            let tagNs = tagText as NSString
            if let m = nameRegex.firstMatch(in: tagText,
                                            range: NSRange(location: 0, length: tagNs.length)) {
                let name = tagNs.substring(with: m.range(at: 1))
                if !name.isEmpty && name != node.name {
                    node.name = name
                }
            }
        }
        // Attribute regex using plain alternation. Accept BOTH straight
        // and curly quotes (" ' “ ” ‘ ’) because macOS's smart-quote
        // substitution may have sneaked curly quotes into the source
        // before we disabled it on the text view.
        let pattern = "([A-Za-z_][\\w\\-.:]*)\\s*=\\s*(?:[\"\u{201C}\u{201D}]([^\"\u{201C}\u{201D}]*)[\"\u{201C}\u{201D}]|['\u{2018}\u{2019}]([^'\u{2018}\u{2019}]*)['\u{2018}\u{2019}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let tagNs = tagText as NSString
        let matches = regex.matches(in: tagText, range: NSRange(location: 0, length: tagNs.length))
        Diag.log("refreshAttributes: node=\(node.name) matches=\(matches.count)")
        var newAttrs: [(name: String, value: String)] = []
        newAttrs.reserveCapacity(matches.count)
        for m in matches {
            let name = tagNs.substring(with: m.range(at: 1))
            let dqRange = m.range(at: 2)
            let sqRange = m.range(at: 3)
            let raw: String
            if dqRange.location != NSNotFound {
                raw = tagNs.substring(with: dqRange)
            } else if sqRange.location != NSNotFound {
                raw = tagNs.substring(with: sqRange)
            } else {
                continue
            }
            let value = raw
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            newAttrs.append((name, value))
        }
        node.attributes = newAttrs
    }

    func scrollToLine(_ line: Int) {
        guard !lineStarts.isEmpty else { return }
        let clamped = max(1, min(line, lineStarts.count))
        let offset = lineStarts[clamped - 1]
        let docLen = (textView.string as NSString).length
        let safe = min(offset, max(0, docLen - 1))
        let target = NSRange(location: safe, length: 0)
        // Critical on huge files with allowsNonContiguousLayout: without
        // ensureLayout, scrollRangeToVisible clamps to the already-laid-
        // out region and the caret lands near the last-visited area
        // instead of the requested line. showElement has the same call;
        // this path (Go to Line ⌘L, error-row jumps) needs it too.
        if let lm = textView.layoutManager {
            lm.ensureLayout(forCharacterRange: target)
        }
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        // Paint the accent band + stripe on the landing line so the
        // user can SEE where the jump ended up (same visual language
        // as tree-select). Without it the only feedback was a bare
        // caret, easy to lose in a 600k-line file.
        let lineRange = lineCharRange(for: clamped, docLen: docLen)
        if let hv = textView as? HighlightingTextView, lineRange.length > 0 {
            hv.highlightedCharRange = lineRange
        }
    }

    // Apply a one-click linter repair. Verifies the document still
    // contains `original` at `range`, the user may have typed between
    // the lint run and the click, in which case the offsets are stale
    // and editing blind would corrupt an unrelated spot. Routed through
    // shouldChangeText/didChangeText so the repair lands on the undo
    // stack (⌘Z works) and fires the normal text-changed pipeline
    // (dirty flag, debounced re-validation) exactly like hand typing.
    func applyFix(range: NSRange, original: String, replacement: String) -> Bool {
        guard let storage = textStorageRef else { return false }
        let docLen = storage.length
        guard range.location >= 0, NSMaxRange(range) <= docLen else { return false }
        if range.length > 0, storage.mutableString.substring(with: range) != original {
            return false
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        if let lm = textView.layoutManager {
            lm.ensureLayout(forCharacterRange: range)
        }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.didChangeText()

        // Repairs are single-line (no newlines on either side), so we
        // can keep lineStarts exact the same way applyAttrEdit does:
        // shift every entry after the edited line by the length delta.
        let delta = (replacement as NSString).length - range.length
        if delta != 0, !original.contains("\n"), !replacement.contains("\n") {
            let editLine = lineNumber(at: range.location) // 1-based
            lineStarts.withUnsafeMutableBufferPointer { buf in
                if editLine >= 0 && editLine < buf.count {
                    for i in editLine..<buf.count {
                        buf[i] += delta
                    }
                }
            }
        }

        // Reveal the repaired spot with the same landing-line visual
        // as an error jump.
        let caret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        if let lm = textView.layoutManager {
            lm.ensureLayout(forCharacterRange: caret)
        }
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        let newDocLen = storage.length
        let ln = lineNumber(at: min(range.location, max(0, newDocLen - 1)))
        let lineRange = lineCharRange(for: ln, docLen: newDocLen)
        if let hv = textView as? HighlightingTextView, lineRange.length > 0 {
            hv.highlightedCharRange = lineRange
        }
        return true
    }

    // ---- v0.28.0: editing + find/replace primitives ----

    var fullDocumentRange: NSRange {
        NSRange(location: 0, length: (textView.string as NSString).length)
    }

    var documentText: String { textView.string }

    func refreshLineStarts() {
        if let storage = textStorageRef { rebuildLineStarts(from: storage) }
    }

    // Undo-friendly raw edit (tree context menu: cut / duplicate /
    // delete). Goes through shouldChangeText/didChangeText so Cmd-Z
    // works and the normal changed pipeline (dirty flag, debounced
    // revalidation) fires.
    @discardableResult
    func performEdit(range: NSRange, replacement: String) -> Bool {
        guard let storage = textStorageRef,
              range.location >= 0, NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        if let lm = textView.layoutManager { lm.ensureLayout(forCharacterRange: NSRange(location: range.location, length: 0)) }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.didChangeText()
        return true
    }

    // Replace-all within a range as ONE undoable edit. Returns the
    // occurrence count, or -1 when the scope is too large to copy
    // (100 M character cap keeps a 655 MB file from spiking memory).
    func replaceAll(find: String, with replacement: String,
                    caseSensitive: Bool, wholeWord: Bool = false, in range: NSRange) -> Int {
        guard !find.isEmpty, let storage = textStorageRef else { return 0 }
        let docLen = storage.length
        var r = range
        r.location = max(0, min(r.location, docLen))
        r.length = min(r.length, docLen - r.location)
        guard r.length > 0 else { return 0 }
        guard r.length <= 100_000_000 else { return -1 }
        let segment = NSMutableString(string: storage.mutableString.substring(with: r))
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let count: Int
        if wholeWord {
            var n = 0
            var cursor = 0
            let replLen = (replacement as NSString).length
            while cursor < segment.length {
                let window = NSRange(location: cursor, length: segment.length - cursor)
                let hit = segment.range(of: find, options: opts, range: window)
                guard hit.location != NSNotFound else { break }
                if wholeWordOK(segment, hit) {
                    segment.replaceCharacters(in: hit, with: replacement)
                    cursor = hit.location + max(1, replLen)
                    n += 1
                } else {
                    cursor = hit.location + max(1, hit.length)
                }
            }
            count = n
        } else {
            count = segment.replaceOccurrences(of: find, with: replacement,
                                               options: opts,
                                               range: NSRange(location: 0, length: segment.length))
        }
        guard count > 0 else { return 0 }
        guard performEdit(range: r, replacement: segment as String) else { return 0 }
        refreshLineStarts()   // bulk edits shift everything; keep jumps exact
        return count
    }

    // ---- Search primitives for the Find panel + toolbar field ----

    private func clamp(_ r: NSRange, to len: Int) -> NSRange {
        let loc = max(0, min(r.location, len))
        return NSRange(location: loc, length: min(r.length, len - loc))
    }

    // XML "word" characters, letters, digits, _ and '-' (so
    // "price" does NOT whole-word-match inside "price-elasticity").
    private func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D || c > 0x7F
    }
    private func wholeWordOK(_ ns: NSString, _ r: NSRange) -> Bool {
        if r.location > 0, isWordChar(ns.character(at: r.location - 1)) { return false }
        let end = NSMaxRange(r)
        if end < ns.length, isWordChar(ns.character(at: end)) { return false }
        return true
    }

    // Next/previous occurrence, wrapping WITHIN the scope.
    func matchRange(of needle: String, from position: Int, forward: Bool,
                    caseSensitive: Bool, wholeWord: Bool = false, in scope: NSRange) -> NSRange? {
        guard !needle.isEmpty, let storage = textStorageRef else { return nil }
        let ns = storage.mutableString
        let sc = clamp(scope, to: ns.length)
        guard sc.length > 0 else { return nil }
        var opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        if !forward { opts.insert(.backwards) }

        // Raw finder over one window, skipping non-whole-word hits.
        func scan(_ window: NSRange) -> NSRange? {
            var w = window
            while w.length > 0 {
                let hit = ns.range(of: needle, options: opts, range: w)
                guard hit.location != NSNotFound else { return nil }
                if !wholeWord || wholeWordOK(ns, hit) { return hit }
                if forward {
                    let next = hit.location + 1
                    w = NSRange(location: next, length: max(0, NSMaxRange(window) - next))
                } else {
                    w = NSRange(location: window.location,
                                length: max(0, NSMaxRange(hit) - 1 - window.location))
                }
            }
            return nil
        }

        let pos = max(sc.location, min(position, NSMaxRange(sc)))
        if forward {
            if let hit = scan(NSRange(location: pos, length: NSMaxRange(sc) - pos)) { return hit }
            return scan(NSRange(location: sc.location, length: pos - sc.location))
        } else {
            if let hit = scan(NSRange(location: sc.location, length: max(0, pos - sc.location))) { return hit }
            return scan(NSRange(location: pos, length: NSMaxRange(sc) - pos))
        }
    }

    // Every occurrence in the scope, capped (Find All results table).
    func allMatchRanges(of needle: String, caseSensitive: Bool,
                        wholeWord: Bool = false,
                        in scope: NSRange, cap: Int = 5000) -> [NSRange] {
        guard !needle.isEmpty, let storage = textStorageRef else { return [] }
        let ns = storage.mutableString
        let sc = clamp(scope, to: ns.length)
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var out: [NSRange] = []
        var cursor = sc.location
        while cursor < NSMaxRange(sc), out.count < cap {
            let window = NSRange(location: cursor, length: NSMaxRange(sc) - cursor)
            let hit = ns.range(of: needle, options: opts, range: window)
            guard hit.location != NSNotFound else { break }
            if !wholeWord || wholeWordOK(ns, hit) { out.append(hit) }
            cursor = hit.location + max(1, hit.length)
        }
        return out
    }

    // Scroll + select + paint the landing line for a match.
    func revealMatch(_ r: NSRange) {
        guard let storage = textStorageRef else { return }
        let docLen = storage.length
        guard r.location < docLen else { return }
        if let lm = textView.layoutManager { lm.ensureLayout(forCharacterRange: r) }
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        let ln = lineNumber(at: min(r.location, max(0, docLen - 1)))
        let lineRange = lineCharRange(for: ln, docLen: docLen)
        if let hv = textView as? HighlightingTextView, lineRange.length > 0 {
            hv.highlightedCharRange = lineRange
        }
    }

    func lineNumber(forOffset offset: Int) -> Int { lineNumber(at: offset) }

    func lineText(forLine line: Int, cap: Int = 300) -> String {
        guard let storage = textStorageRef else { return "" }
        var r = lineCharRange(for: line, docLen: storage.length)
        r.length = min(r.length, cap)
        return storage.mutableString.substring(with: r)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Text container width must follow the scroll view's content width
    // so word wrap reflows on window resize. TextKit 2 doesn't always
    // propagate this automatically for containers we build ourselves.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateContainerWidth()
    }

    private func updateContainerWidth() {
        guard let container = textView.textContainer else { return }
        let w = scroll.contentSize.width - textView.textContainerInset.width * 2
        container.size = NSSize(width: max(40, w), height: CGFloat.greatestFiniteMagnitude)
        var f = textView.frame
        f.size.width = scroll.contentSize.width
        textView.frame = f
    }

    // MARK: Internals

    private func setErrorHeader(_ msg: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        header.stringValue = msg
    }

    private func applyLoadedText(_ text: String, lineStarts: [Int]) {
        let mb = Double(fileSize) / 1024 / 1024
        let lineCount = lineStarts.count
        Diag.log("applyLoadedText: \(text.count) chars, \(lineCount) lines")
        self.lineStarts = lineStarts
        suppressMutationEvents = true
        Diag.time("textView.string = text") {
            textView.string = text
        }
        suppressMutationEvents = false
        textView.isEditable = true
        // With TextKit 1 + allowsNonContiguousLayout, clicks scroll
        // instantly regardless of distance, no prewarm needed.
        header.stringValue = "\(currentURL?.lastPathComponent ?? "") · \(String(format: "%.1f", mb)) MB · \(lineCount) lines · \(currentTextEncoding.displayName)"
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        // Initial viewport coloring pass.
        highlighter?.colorInitialViewport()
        // Hand the ruler the fresh line index + widen it enough for
        // the biggest line number in this file.
        lineNumberRuler?.lineStarts = lineStarts
        lineNumberRuler?.recomputeThickness(forTotalLines: lineCount)
        lineNumberRuler?.needsDisplay = true
        onFileLoaded?()
    }

    // ── Multi-tab session swap (v0.35.0) ─────────────────────────
    // The active tab's undo stack, supplied by MainWindowController.
    var sessionUndoManager: UndoManager?

    var currentStorage: NSTextStorage? { textStorageRef }
    func snapshotScroll() -> NSPoint { scroll.contentView.bounds.origin }

    func restoreScroll(_ origin: NSPoint) {
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // Point the editor at a parked session's document. Everything
    // bound to the old NSTextStorage object (the edit observer, the
    // syntax highlighter, the ruler's line index) is re-bound, 
    // replaceTextStorage alone leaves them talking to the old text.
    func attachSession(url: URL, fileSize: Int, storage: NSTextStorage,
                       lineStarts: [Int], scrollOrigin: NSPoint,
                       textEncoding: XMLTextEncoding = .utf8) {
        if let old = textStorageRef {
            NotificationCenter.default.removeObserver(
                self, name: NSTextStorage.didProcessEditingNotification, object: old)
        }
        textView.layoutManager?.replaceTextStorage(storage)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onTextStorageEdited(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
        highlighter?.rebind()

        currentURL = url
        self.fileSize = fileSize
        self.lineStarts = lineStarts
        self.currentTextEncoding = textEncoding
        textView.isEditable = true
        if let hv = textView as? HighlightingTextView {
            hv.highlightedCharRange = nil
            hv.highlightedBoxRange = nil
        }
        let mb = Double(fileSize) / 1024 / 1024
        header.stringValue = "\(url.lastPathComponent) · \(String(format: "%.1f", mb)) MB · \(lineStarts.count) lines · \(textEncoding.displayName)"
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        lineNumberRuler?.lineStarts = lineStarts
        lineNumberRuler?.recomputeThickness(forTotalLines: lineStarts.count)
        lineNumberRuler?.needsDisplay = true

        // Restore where the user was. Lay out around the target first
        // so the clip view doesn't clamp the offset back to the
        // already-laid-out region (same trick as showElement).
        if let lm = textView.layoutManager, storage.length > 0 {
            let anchorLine = lineNumber(at: 0)
            _ = anchorLine // layout at doc start is enough to seed NCL
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: 0))
        }
        scroll.contentView.setBoundsOrigin(scrollOrigin)
        scroll.reflectScrolledClipView(scroll.contentView)
        highlighter?.colorInitialViewport()
    }

    /// Keep the live editor's file identity and encoding synchronized after a
    /// successful Save As or an encoding-declaration change. Without this,
    /// the next tab snapshot could restore the pre-save encoding and write
    /// bytes that no longer matched the XML declaration.
    func adoptSavedDocument(url: URL, fileSize: Int,
                            textEncoding: XMLTextEncoding) {
        currentURL = url
        self.fileSize = fileSize
        currentTextEncoding = textEncoding
        let mb = Double(fileSize) / 1024 / 1024
        header.stringValue = "\(url.lastPathComponent) · \(String(format: "%.1f", mb)) MB · \(lineStarts.count) lines · \(textEncoding.displayName)"
    }

    // Fresh empty storage for a brand-new tab, so the load path's
    // `textView.string = ""` can't wipe the document we just parked.
    func detachToFreshStorage() {
        attachSession(url: URL(fileURLWithPath: "/untitled.xml"), fileSize: 0,
                      storage: NSTextStorage(), lineStarts: [0], scrollOrigin: .zero,
                      textEncoding: .utf8)
        currentURL = nil
        header.stringValue = ""
        textView.isEditable = false
    }

    // Reset the editor to its empty no-file state. Called from
    // File > Close File, without this the old file's text stayed
    // in the editor (still editable!) after the rest of the UI had
    // reset, which read as "the close didn't work".
    func clear() {
        currentURL = nil
        fileSize = 0
        currentTextEncoding = .utf8
        lineStarts = [0]
        suppressMutationEvents = true
        textView.string = ""
        suppressMutationEvents = false
        textView.isEditable = false
        if let hv = textView as? HighlightingTextView {
            hv.highlightedCharRange = nil
        }
        header.stringValue = ""
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        lineNumberRuler?.lineStarts = [0]
        lineNumberRuler?.needsDisplay = true
    }

    // MARK: Line-number ruler, public API
    //
    // Wired from the View menu's "Show Line Numbers" toggle. State
    // persists via UserDefaults so the preference survives relaunch.
    func setLineNumbersVisible(_ visible: Bool) {
        scroll.rulersVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.lineNumbersPrefKey)
        lineNumberRuler?.needsDisplay = true
    }
    var isLineNumbersVisible: Bool { scroll.rulersVisible }

    // Expose read-only access to the scroll view / text view for the
    // Minimap attachment in MainWindowController.
    var exposedScrollView: NSScrollView { scroll }
    var exposedTextView: NSTextView { textView }

    // MARK: the marker
    //
    // The strokes belong to the document, so the controller only passes
    // them through to the view that draws them and reports where the user
    // dragged.

    private var hlView: HighlightingTextView? { textView as? HighlightingTextView }

    // Stored here rather than forwarded straight through, because the
    // window wires these up before the text view necessarily exists, and a
    // setter that wrote into a nil view would drop them silently. They are
    // pushed to the view by pushMarkerState(), which the view's own setup
    // calls once it is ready.
    private var markerStrokesStore: TextHighlights?
    private var markerOnStore = false
    private var markerCursorColorStore: NSColor = XMColor.marker(.yellow)
    private var onMarkerStrokeStore: ((NSRange) -> Void)?
    private var onMarkerCancelStore: (() -> Void)?

    func pushMarkerState() {
        guard let v = hlView else { return }
        v.markerStrokes = markerStrokesStore
        v.markerOn = markerOnStore
        v.markerCursorColor = markerCursorColorStore
        v.onMarkerStroke = onMarkerStrokeStore
        v.onMarkerCancel = onMarkerCancelStore
        v.needsDisplay = true
    }

    var markerStrokes: TextHighlights? {
        get { markerStrokesStore }
        set { markerStrokesStore = newValue; pushMarkerState() }
    }

    var markerOn: Bool {
        get { markerOnStore }
        set { markerOnStore = newValue; pushMarkerState() }
    }

    /// The colour the pointer is drawn in while the marker is out.
    var markerCursorColor: NSColor {
        get { markerCursorColorStore }
        set { markerCursorColorStore = newValue; pushMarkerState() }
    }

    /// Reported on mouse-up while the marker is on: the dragged range, or
    /// an empty range for a plain click.
    var onMarkerStroke: ((NSRange) -> Void)? {
        get { onMarkerStrokeStore }
        set { onMarkerStrokeStore = newValue; pushMarkerState() }
    }

    var onMarkerCancel: (() -> Void)? {
        get { onMarkerCancelStore }
        set { onMarkerCancelStore = newValue; pushMarkerState() }
    }

    /// The whole line containing `offset`, which is what a plain click
    /// with the marker paints.
    func lineCharRange(containing offset: Int) -> NSRange {
        guard let storage = textStorageRef else { return NSRange(location: offset, length: 0) }
        return (storage.string as NSString).lineRange(for: NSRange(location: min(offset, storage.length), length: 0))
    }

    func redrawMarker() { textView?.needsDisplay = true }
    var currentLineStarts: [Int] { lineStarts }

    // Zoom API, called from the View menu / ⌘+ ⌘- ⌘0. Applies to the
    // entire text storage in one pass (fast: single typingAttributes +
    // addAttribute call, no per-character work).
    func zoomIn()     { zoomStep += 1; applyZoom() }
    func zoomOut()    { zoomStep -= 1; applyZoom() }
    func zoomReset()  { zoomStep  = 0; applyZoom() }

    private func applyZoom() {
        let newFont = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        // ONE pass over the storage. `textView.font = …` also walks the
        // entire text (NSText applies a font to all of it), so setting
        // both re-fonted 39 MB twice per zoom tick and made the zoom
        // slider feel heavy (v0.44.3). The storage pass keeps the
        // highlighter's foreground colors in place; typing attributes
        // pick up the size for newly typed text.
        textView.typingAttributes[.font] = newFont
        if let storage = textView.textStorage, storage.length > 0 {
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: newFont, range: full)
            storage.endEditing()
        } else {
            textView.font = newFont
        }
        textView.needsDisplay = true
    }

    // Called by MainWindowController when the global zoom slider
    // changes. Re-applies every font this VC owns so the slider's new
    // XMFont.globalScale takes effect immediately.
    func rebuildFonts() {
        header.font = XMFont.uiCaption
        applyZoom()
        lineNumberRuler?.digitFont = XMFont.mono(10, .regular)
        lineNumberRuler?.recomputeThickness(forTotalLines: lineStarts.count)
        lineNumberRuler?.needsDisplay = true
    }

    // Theme hook, re-apply NSColor backgrounds (stored once at init
    // and not updated automatically when ThemeManager.current swaps)
    // plus insertion/selection colors that live on the text view.
    func rebuildColors() {
        textView.backgroundColor = XMColor.bgDeep
        textView.textColor = XMColor.text
        textView.insertionPointColor = XMColor.accent
        textView.selectedTextAttributes = [
            .backgroundColor: XMColor.lineHighlight
        ]
        scroll.backgroundColor = XMColor.bgDeep
        header.textColor = XMColor.text3
        // The landing-line band caches an NSColor, re-fetch the new
        // theme's lineHighlight or the band keeps the old palette.
        if let hv = textView as? HighlightingTextView {
            hv.highlightColor = XMColor.lineHighlight
            hv.highlightStripeColor = XMColor.accent
        }
        lineNumberRuler?.gutterBackground = XMColor.bgDeep.withAlphaComponent(0.6)
        lineNumberRuler?.digitColor = XMColor.text2
        lineNumberRuler?.dividerColor = XMColor.hairline
        lineNumberRuler?.needsDisplay = true
        highlighter?.rebuildColors()
    }

    // Build a line-start offset table in O(n). Index i holds the
    // character offset at which line (i+1) begins, so line 1 is
    // lineStarts[0], line 2 is lineStarts[1], and so on.
    static func buildLineStarts(in text: String) -> [Int] {
        var starts: [Int] = [0]
        starts.reserveCapacity(max(1024, text.utf16.count / 40))
        let utf16 = text.utf16
        var i = 0
        for unit in utf16 {
            i += 1
            if unit == 0x000A {
                starts.append(i)
            }
        }
        return starts
    }
}

// Per-tab undo: the text view asks here instead of using the window's
// shared undo manager.
extension SourceViewController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        return sessionUndoManager
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChanged?()
    }
}
