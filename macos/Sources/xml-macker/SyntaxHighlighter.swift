import Cocoa

// Viewport-only syntax highlighter for the XML source editor.
//
// Coloring the whole 655 MB file would be pointless and expensive, 
// the user only sees ~50 lines at a time. This class watches the
// scroll view, computes the visible character range (via the layout
// manager), and colors only that window. A bitmap of "already
// colored" ranges (coarse, per 4 KB chunk) avoids re-coloring on
// scroll-back.
//
// Storage edits (user typing) invalidate the cache for the edited
// chunks so the new characters get colored next time the viewport
// includes them.
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var storageObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var throttle: DispatchWorkItem?

    // Chunk-based cache. Each chunk is 4096 characters; cleared on
    // edits that touch it. Using chunk-granularity avoids per-line
    // bookkeeping cost.
    private static let chunkSize = 4096
    private var coloredChunks = Set<Int>()

    // Tab switching replaces the text view's NSTextStorage. The edit
    // observer above is bound to the OLD storage object, and the chunk
    // cache describes the old text, re-bind both to the current
    // storage or the new document never gets colored.
    func rebind() {
        if let old = storageObserver { NotificationCenter.default.removeObserver(old) }
        storageObserver = nil
        coloredChunks.removeAll()
        guard let storage = textView?.textStorage else { return }
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard storage.editedMask.contains(.editedCharacters) else { return }
            self.invalidateChunks(around: storage.editedRange)
            self.scheduleColorVisible()
        }
        scheduleColorVisible()
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        guard let storage = textView.textStorage else { return }

        // Storage edits: invalidate affected chunks.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard storage.editedMask.contains(.editedCharacters) else { return }
            self.invalidateChunks(around: storage.editedRange)
            self.scheduleColorVisible()
        }

        // Scroll/resize: re-color viewport (throttled).
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleColorVisible()
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleColorVisible()
        }
        clip.postsFrameChangedNotifications = true
    }

    deinit {
        if let o = storageObserver { NotificationCenter.default.removeObserver(o) }
        if let o = scrollObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Kick an initial coloring pass (after string is loaded).
    func colorInitialViewport() {
        scheduleColorVisible()
    }

    /// Theme-change hook. The chunk cache holds "this chunk has been
    /// colored" markers, but the actual NSColor attributes inside
    /// each chunk reference the OLD theme palette. Clear the cache
    /// and re-color the visible viewport so fresh XMColor values
    /// paint on top.
    func rebuildColors() {
        coloredChunks.removeAll()
        scheduleColorVisible()
    }

    // MARK: Throttled color run

    private func scheduleColorVisible() {
        throttle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.colorVisible() }
        throttle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func colorVisible() {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer,
              let storage = tv.textStorage,
              let scroll = scrollView else { return }

        // Visible character range (expanded a little to cover overscroll).
        let visibleRect = scroll.contentView.bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let total = storage.length
        let pad: Int = 2048
        let start = max(0, charRange.location - pad)
        let end = min(total, charRange.location + charRange.length + pad)
        if end <= start { return }

        // Translate to chunk indices; color only chunks not yet done.
        let firstChunk = start / Self.chunkSize
        let lastChunk = (end - 1) / Self.chunkSize
        for chunk in firstChunk...lastChunk {
            if coloredChunks.contains(chunk) { continue }
            let cStart = chunk * Self.chunkSize
            let cEnd = min(total, cStart + Self.chunkSize)
            colorRange(NSRange(location: cStart, length: cEnd - cStart), in: storage)
            coloredChunks.insert(chunk)
        }
    }

    private func invalidateChunks(around range: NSRange) {
        let first = max(0, range.location / Self.chunkSize)
        let last = max(0, (range.location + max(1, range.length) - 1) / Self.chunkSize)
        if first <= last {
            for c in first...last { coloredChunks.remove(c) }
        }
    }

    // MARK: Token classifier
    //
    // Single-pass state machine over the NSString characters in the
    // range. Maintains just enough state to distinguish:
    //   tag open  < ... >       (with Name, Attr, Value sub-tokens)
    //   tag close </name>
    //   comment   <!-- ... -->
    //   CDATA     <![CDATA[ ... ]]>   (treated as text)
    //   PI        <?xml ... ?>
    //   text      everything else between tags
    //
    // For each character, we know which color to apply; we batch runs
    // of the same color and call addAttribute once per run.
    private enum Mode { case text, inOpenTag, inCloseTag, inAttrName, inAttrEq, inAttrVal(quote: unichar), inComment, inPI }

    private func colorRange(_ range: NSRange, in storage: NSTextStorage) {
        let ns = storage.mutableString
        let start = range.location
        let end = range.location + range.length
        guard end <= ns.length, start >= 0, end > start else { return }

        // Determine mode at `start` by scanning back a small window, 
        // if we happen to begin inside an open tag or a comment we
        // need to continue that mode, not start fresh. 512 chars is
        // plenty for GCAM XML (tags are short). Worst case: minor
        // miscolor at chunk boundaries, auto-corrects next time the
        // full tag is re-processed.
        var mode: Mode = .text
        let backStart = max(0, start - 512)
        scan(from: backStart, to: start, in: ns, mode: &mode, applyFrom: nil, storage: nil)

        storage.beginEditing()
        scan(from: start, to: end, in: ns, mode: &mode, applyFrom: start, storage: storage)
        storage.endEditing()
        markLinks(in: range, storage: storage)
    }

    // MARK: Linked files as hyperlinks (v1.0.1)
    //
    // Any attribute value or element text in a colored chunk that names
    // a file next to the document (GCAM config entries such as
    // ../input/gcamdata/xml/foo.xml) is underlined, gets a tooltip and a
    // link attribute; ⌘-click in HighlightingTextView opens it. Only the
    // visible chunks are ever scanned, like the colors, and the file
    // system is asked only for path-looking text.
    static let linkKey = NSAttributedString.Key("xml-macker.linkedFile")
    var linkResolver: ((String) -> URL?)?
    private static let linkPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: ">([^<>\n]{2,400})<"),
        try! NSRegularExpression(pattern: "=\"([^\"\n]{2,400})\""),
    ]

    private func markLinks(in range: NSRange, storage: NSTextStorage) {
        guard let resolver = linkResolver else { return }
        let ns = storage.mutableString
        guard range.location >= 0, range.location + range.length <= ns.length else { return }
        // Work on the 4 KB chunk text; bridging the whole storage to a
        // Swift String would copy the entire document.
        let chunk = ns.substring(with: range) as NSString
        var hits: [(NSRange, URL)] = []
        for pattern in Self.linkPatterns {
            pattern.enumerateMatches(in: chunk as String, options: [],
                                     range: NSRange(location: 0, length: chunk.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1 else { return }
                let r = m.range(at: 1)
                let text = chunk.substring(with: r)
                guard text.contains("/") || text.lowercased().hasSuffix(".xml") else { return }
                guard let url = resolver(text) else { return }
                hits.append((NSRange(location: range.location + r.location, length: r.length), url))
            }
        }
        storage.beginEditing()
        storage.removeAttribute(Self.linkKey, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(.toolTip, range: range)
        for (r, url) in hits {
            storage.addAttributes([Self.linkKey: url,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: XMColor.accent,
                                   .toolTip: "⌘-click to open \(url.lastPathComponent)"], range: r)
        }
        storage.endEditing()
    }

    private func scan(from s: Int, to e: Int, in ns: NSMutableString,
                      mode: inout Mode, applyFrom: Int?, storage: NSTextStorage?) {
        var i = s
        var runStart = i
        var runColor: NSColor? = nil

        func flushRun(upTo limit: Int, newColor: NSColor?) {
            guard let storage = storage, applyFrom != nil, let color = runColor, limit > runStart else {
                runStart = limit
                runColor = newColor
                return
            }
            let len = limit - runStart
            if len > 0 {
                storage.addAttribute(.foregroundColor,
                                     value: color,
                                     range: NSRange(location: runStart, length: len))
            }
            runStart = limit
            runColor = newColor
        }

        while i < e {
            let c = ns.character(at: i)
            switch mode {
            case .text:
                if c == 0x3C {  // '<'
                    // Detect <!-- ... -->, <![CDATA[..., <?... ?>
                    if i + 3 < ns.length,
                       ns.character(at: i + 1) == 0x21, // '!'
                       ns.character(at: i + 2) == 0x2D, // '-'
                       ns.character(at: i + 3) == 0x2D { // '-'
                        flushRun(upTo: i, newColor: XMColor.syntaxCom)
                        mode = .inComment
                        i += 4
                        continue
                    }
                    if i + 1 < ns.length, ns.character(at: i + 1) == 0x3F { // '<?'
                        flushRun(upTo: i, newColor: XMColor.syntaxCom)
                        mode = .inPI
                        i += 2
                        continue
                    }
                    if i + 1 < ns.length, ns.character(at: i + 1) == 0x2F { // '</'
                        flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                        mode = .inCloseTag
                        // Set punct color for '</', then tag color starts.
                        i += 2
                        if let storage = storage, applyFrom != nil {
                            storage.addAttribute(.foregroundColor,
                                                 value: XMColor.syntaxPunct,
                                                 range: NSRange(location: i - 2, length: 2))
                        }
                        runStart = i
                        runColor = XMColor.syntaxTag
                        continue
                    }
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    runStart = i
                    runColor = XMColor.syntaxTag
                    mode = .inOpenTag
                    continue
                }
                // plain text
                if runColor !== XMColor.syntaxText {
                    flushRun(upTo: i, newColor: XMColor.syntaxText)
                }
                i += 1

            case .inOpenTag:
                // Reading tag name until whitespace, '/' or '>'.
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    i += 1
                    mode = .inAttrName
                    runStart = i
                    runColor = nil
                    continue
                }
                if c == 0x2F {  // '/'
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    i += 1
                    continue
                }
                if c == 0x3E {  // '>'
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    runStart = i
                    runColor = nil
                    mode = .text
                    continue
                }
                // tag-name char
                i += 1

            case .inAttrName:
                if c == 0x3E || c == 0x2F {  // '>' or '/'
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    // let tag finish
                    if c == 0x3E {
                        if let storage = storage, applyFrom != nil {
                            storage.addAttribute(.foregroundColor,
                                                 value: XMColor.syntaxPunct,
                                                 range: NSRange(location: i, length: 1))
                        }
                        i += 1
                        mode = .text
                    } else {
                        if let storage = storage, applyFrom != nil {
                            storage.addAttribute(.foregroundColor,
                                                 value: XMColor.syntaxPunct,
                                                 range: NSRange(location: i, length: 1))
                        }
                        i += 1
                        mode = .inOpenTag   // '/' before '>'
                    }
                    runStart = i
                    runColor = nil
                    continue
                }
                if c == 0x3D {  // '='
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    mode = .inAttrEq
                    runStart = i
                    runColor = nil
                    continue
                }
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    // separator between attributes
                    i += 1
                    runStart = i
                    runColor = nil
                    continue
                }
                // attribute-name char
                if runColor !== XMColor.syntaxAttr {
                    flushRun(upTo: i, newColor: XMColor.syntaxAttr)
                }
                i += 1

            case .inAttrEq:
                if c == 0x22 || c == 0x27 {  // '"' or '\''
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    mode = .inAttrVal(quote: c)
                    runStart = i
                    runColor = XMColor.syntaxVal
                    continue
                }
                i += 1

            case .inAttrVal(let q):
                if c == q {
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    mode = .inAttrName
                    runStart = i
                    runColor = nil
                    continue
                }
                i += 1

            case .inCloseTag:
                if c == 0x3E {  // '>'
                    flushRun(upTo: i, newColor: XMColor.syntaxPunct)
                    if let storage = storage, applyFrom != nil {
                        storage.addAttribute(.foregroundColor,
                                             value: XMColor.syntaxPunct,
                                             range: NSRange(location: i, length: 1))
                    }
                    i += 1
                    mode = .text
                    runStart = i
                    runColor = nil
                    continue
                }
                if runColor !== XMColor.syntaxTag {
                    flushRun(upTo: i, newColor: XMColor.syntaxTag)
                }
                i += 1

            case .inComment:
                if c == 0x2D, // '-'
                   i + 2 < ns.length,
                   ns.character(at: i + 1) == 0x2D,
                   ns.character(at: i + 2) == 0x3E {
                    i += 3
                    flushRun(upTo: i, newColor: nil)
                    mode = .text
                    runColor = nil
                    continue
                }
                if runColor !== XMColor.syntaxCom {
                    flushRun(upTo: i, newColor: XMColor.syntaxCom)
                }
                i += 1

            case .inPI:
                if c == 0x3F, // '?'
                   i + 1 < ns.length,
                   ns.character(at: i + 1) == 0x3E {
                    i += 2
                    flushRun(upTo: i, newColor: nil)
                    mode = .text
                    runColor = nil
                    continue
                }
                if runColor !== XMColor.syntaxCom {
                    flushRun(upTo: i, newColor: XMColor.syntaxCom)
                }
                i += 1
            }
        }
        flushRun(upTo: e, newColor: nil)
    }
}
