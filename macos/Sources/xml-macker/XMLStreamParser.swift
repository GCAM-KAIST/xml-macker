import Foundation
import Darwin

// Streaming XML parser backed by Foundation's XMLParser. For files up to
// a few hundred MB this reads straight from an InputStream without ever
// loading the whole thing as a String, so a 700 MB file opens without
// blowing heap.
//
// Truncation budget mirrors the Electron version: we cap depth and per-
// parent child count so the tree payload stays bounded even on adversarial
// input.
final class XMLStreamParser: NSObject, XMLParserDelegate {
    // A concrete, one-click repair for a lint error. `range` is the
    // absolute UTF-16 character range in the live document; `original`
    // is the exact text expected there so the apply step can verify
    // the document hasn't shifted since the lint ran (typing between
    // lint and click would otherwise corrupt the wrong spot).
    struct FixIt {
        let range: NSRange
        let original: String
        let replacement: String   // "" means delete
        let title: String         // human wording, e.g. Change to </period>
    }

    struct ParseError {
        let line: Int
        let column: Int
        let message: String
        var fix: FixIt? = nil
    }

    struct Result {
        let root: XMLTreeNode
        let errors: [ParseError]
        let nodeCount: Int
    }

    // Truncation / safety caps. These used to truncate the tree at
    // 500k nodes which silently dropped regions on large GCAM files.
    // Defaults now effectively unbounded; NSOutlineView virtualizes
    // rendering so a multi-million-node tree costs no more to display.
    var maxDepth: Int = 64
    var childrenPerParentCap: Int = Int.max
    var hardNodeCap: Int = Int.max

    // Internal state.
    private let buildsTree: Bool
    private var nextId: Int = 0
    private let document = XMLTreeNode(id: 0, kind: .document, name: "#document")
    private var stack: [XMLTreeNode?] = []
    private var errors: [ParseError] = []
    private var truncatedCount: Int = 0
    // XMLParser reports its location after it has consumed an opening
    // tag. For a tag whose attributes span several lines, that is the
    // line containing '>', not the line containing '<'. Keep a
    // memory-bounded lexical cursor over the same bytes so every start
    // callback can be paired with the tag's real opening line.
    private var startLineTracker: XMLStartLineTracker?

    // XMLParser itself is confined to the parsing queue. The UI polls this
    // synchronized snapshot instead of calling XMLParser.lineNumber from a
    // different thread (XMLParser does not promise cross-thread safety).
    // Delegate callbacks publish at most once per 256 input lines, keeping
    // lock traffic negligible on multi-million-node GCAM files.
    private let progressLock = NSLock()
    private var progressLineNumber: Int = 0
    private var lastPublishedProgressLine: Int = 0

    var currentLineNumber: Int {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progressLineNumber
    }

    override init() {
        buildsTree = true
        super.init()
        stack = [document]
    }

    private init(buildsTree: Bool) {
        self.buildsTree = buildsTree
        super.init()
        stack = [document]
    }

    /// Validate without retaining an element/attribute tree. This is the
    /// correct path for the standalone full-document validation window: the
    /// live document already owns a complete tree, and constructing another
    /// one can otherwise double peak memory for a large GCAM file.
    static func validateFile(at url: URL) -> [ParseError] {
        XMLStreamParser(buildsTree: false).parseFile(at: url).errors
    }

    /// In-memory counterpart to `validateFile(at:)` for unsaved editor text.
    static func validateText(_ text: String) -> [ParseError] {
        XMLStreamParser(buildsTree: false).parseText(text).errors
    }

    func parseFile(at url: URL) -> Result {
        guard let stream = InputStream(url: url) else {
            return Result(root: document, errors: [ParseError(line: 1, column: 1, message: "Cannot open file")], nodeCount: 0)
        }
        // Mapping does not copy a large document into a Swift String.
        // The tracker walks forward once and retains only its cursor.
        if buildsTree,
           let mapped = try? Data(contentsOf: url, options: [.alwaysMapped, .uncached]) {
            startLineTracker = XMLStartLineTracker(data: mapped)
        }
        let parser = XMLParser(stream: stream)
        return runParse(parser)
    }

    // Parse an in-memory XML string. Needed for live re-validation:
    // the re-validate flow used to re-read the file from disk, which
    // missed any edits made in the source editor since it was opened.
    // The validation window now hands us `sourceTextView.string`
    // directly so the errors reflect what's on screen.
    func parseText(_ text: String) -> Result {
        let data = Data(text.utf8)
        if buildsTree {
            startLineTracker = XMLStartLineTracker(data: data)
        }
        let parser = XMLParser(data: data)
        return runParse(parser)
    }

    // Parse a FRAGMENT of the source document and report errors with
    // absolute (whole-file) line numbers. Used by the scoped live
    // validator: instead of re-parsing 655 MB after every keystroke
    // (slow + noisy with unrelated errors), we parse ONLY the
    // currently-selected element's bytes, then offset the line
    // numbers so they line up with the source editor.
    //
    // Every call creates a fresh XMLStreamParser instance because
    // the delegate accumulates state internally and can't be reused
    // safely. Caller passes `baseLine`, the 1-based absolute line
    // number where the fragment starts in the source editor.
    static func parseFragment(text: String, baseLine: Int) -> Result {
        let parser = XMLStreamParser()
        let raw = parser.parseText(text)
        let offset = max(0, baseLine - 1)
        let shifted = raw.errors.map {
            ParseError(line: $0.line + offset, column: $0.column, message: $0.message)
        }
        return Result(root: raw.root, errors: shifted, nodeCount: raw.nodeCount)
    }

    private func runParse(_ parser: XMLParser) -> Result {
        // The tracker may retain a memory mapping for a very large file.
        // Its work is complete when this parse returns, so release it even
        // if XMLParser aborts on malformed input.
        defer { startLineTracker = nil }
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        resetProgress()
        _ = parser.parse()
        publishProgress(parser.lineNumber, force: true)
        // parser.parserError is the FINAL error if parsing aborted;
        // it's redundant with parser:parseErrorOccurred: in most
        // cases, so avoid duplicating if we already appended.
        if let err = parser.parserError {
            let msg = err.localizedDescription
            if !errors.contains(where: { $0.message == msg && $0.line == parser.lineNumber }) {
                errors.append(ParseError(
                    line: parser.lineNumber,
                    column: parser.columnNumber,
                    message: msg
                ))
            }
        }
        return Result(root: document, errors: errors, nodeCount: nextId)
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        publishProgress(parser.lineNumber)
        guard buildsTree else { return }
        if nextId >= hardNodeCap {
            stack.append(nil)
            truncatedCount += 1
            return
        }
        if stack.count - 1 >= maxDepth {
            stack.append(nil)
            truncatedCount += 1
            return
        }
        let parent = currentParent()
        if let parent, parent.children.count >= childrenPerParentCap {
            if parent.children.count == childrenPerParentCap {
                nextId += 1
                let placeholder = XMLTreeNode(id: nextId, kind: .comment, name: "#truncated")
                placeholder.textValue = "(more elements not shown, branch too large)"
                placeholder.isTruncationPlaceholder = true
                placeholder.parent = parent
                parent.children.append(placeholder)
                truncatedCount += 1
            }
            stack.append(nil)
            return
        }
        nextId += 1
        let node = XMLTreeNode(id: nextId, kind: .element, name: elementName)
        node.attributes = attributeDict.map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
        node.startLine = startLineTracker?.nextElementStartLine(
            named: elementName,
            reportedLine: parser.lineNumber
        ) ?? parser.lineNumber
        node.startOffset = 0 // XMLParser doesn't expose byte offsets directly
        if let parent {
            node.parent = parent
            parent.children.append(node)
        }
        stack.append(node)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        publishProgress(parser.lineNumber)
        guard buildsTree else { return }
        // Never pop the sentinel document node. Malformed fragments
        // (which the scoped live-validator feeds us constantly) can in
        // principle deliver more end-elements than start-elements, 
        // an unguarded removeLast() would eventually pop the document
        // and then crash on an empty stack.
        guard stack.count > 1 else { return }
        let top = stack.removeLast()
        if let top {
            top.endLine = parser.lineNumber
            // XMLParser may split one logical text value around entity
            // references and CDATA boundaries. Preserve each raw chunk
            // while parsing, then remove only the element's outer
            // indentation once all chunks have been joined.
            top.textValue = top.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        publishProgress(parser.lineNumber)
        guard buildsTree else { return }
        // We only record meaningful character data on elements whose text
        // content is non-whitespace. This matches what the inspector will
        // show. For whitespace-only runs we skip entirely to keep memory
        // down on heavily indented files.
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard let parent = currentParent() else { return }
        parent.textValue += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        publishProgress(parser.lineNumber)
        guard buildsTree else { return }
        // Foundation delivers the contents between <![CDATA[ and ]]>
        // separately from foundCharacters. Treat it as ordinary text;
        // entity-looking text inside CDATA must remain literal.
        let string = String(decoding: CDATABlock, as: UTF8.self)
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        currentParent()?.textValue += string
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        publishProgress(parser.lineNumber, force: true)
        errors.append(ParseError(
            line: parser.lineNumber,
            column: parser.columnNumber,
            message: parseError.localizedDescription
        ))
    }

    // MARK: helpers

    private func currentParent() -> XMLTreeNode? {
        for item in stack.reversed() where item != nil {
            return item
        }
        return nil
    }

    private func resetProgress() {
        progressLock.lock()
        progressLineNumber = 0
        lastPublishedProgressLine = 0
        progressLock.unlock()
    }

    private func publishProgress(_ line: Int, force: Bool = false) {
        let clamped = max(0, line)
        // Both fields below are mutated only by XMLParser's delegate queue.
        // Avoid taking the lock for callbacks on the same/similar line.
        guard force || lastPublishedProgressLine == 0 ||
              clamped >= lastPublishedProgressLine + 256 else { return }
        lastPublishedProgressLine = clamped
        progressLock.lock()
        progressLineNumber = clamped
        progressLock.unlock()
    }
}

// A forward-only, quote-aware cursor used solely to recover the line where
// each opening tag begins. It recognizes the encodings XML can identify
// without consulting the declaration (UTF-8/16/32), skips comments, CDATA,
// processing instructions and declarations, and never builds a second tree
// or a line-offset table. Work is O(document bytes) in total and retained
// state is O(1) beyond the memory-mapped input.
private final class XMLStartLineTracker {
    private enum ByteOrder { case big, little }

    private static let commentClose: [UInt32] = [0x2D, 0x2D, 0x3E]
    private static let cdataClose: [UInt32] = [0x5D, 0x5D, 0x3E]
    private static let processingClose: [UInt32] = [0x3F, 0x3E]

    // NSData gives the tight scanning loop stable contiguous storage.
    // Retaining `storage` guarantees that `bytes` remains valid.
    private let storage: NSData
    private let bytes: UnsafePointer<UInt8>
    private let length: Int
    private let unitWidth: Int
    private let byteOrder: ByteOrder
    private var offset: Int

    init(data: Data) {
        let backing = data as NSData
        storage = backing
        bytes = backing.bytes.assumingMemoryBound(to: UInt8.self)
        length = backing.length

        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            unitWidth = 4; byteOrder = .big; offset = 4
        } else if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            unitWidth = 4; byteOrder = .little; offset = 4
        } else if prefix.starts(with: [0xFE, 0xFF]) {
            unitWidth = 2; byteOrder = .big; offset = 2
        } else if prefix.starts(with: [0xFF, 0xFE]) {
            unitWidth = 2; byteOrder = .little; offset = 2
        } else if prefix.starts(with: [0x00, 0x00, 0x00, 0x3C]) {
            unitWidth = 4; byteOrder = .big; offset = 0
        } else if prefix.starts(with: [0x3C, 0x00, 0x00, 0x00]) {
            unitWidth = 4; byteOrder = .little; offset = 0
        } else if prefix.starts(with: [0x00, 0x3C, 0x00, 0x3F]) {
            unitWidth = 2; byteOrder = .big; offset = 0
        } else if prefix.starts(with: [0x3C, 0x00, 0x3F, 0x00]) {
            unitWidth = 2; byteOrder = .little; offset = 0
        } else {
            unitWidth = 1; byteOrder = .big
            offset = prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        }
    }

    func nextElementStartLine(named expectedName: String,
                              reportedLine: Int) -> Int? {
        while seekToNextLessThan() {
            let marker = peek(ahead: 1)

            if marker == 0x3F { // '<?'
                skip(until: Self.processingClose)
                continue
            }
            if marker == 0x2F { // '</'
                skipTag()
                continue
            }
            if marker == 0x21 { // '<!'
                if peek(ahead: 2) == 0x2D, peek(ahead: 3) == 0x2D {
                    skip(until: Self.commentClose)
                } else if isCDATAOpen() {
                    skip(until: Self.cdataClose)
                } else {
                    skipDeclaration()
                }
                continue
            }

            guard let next = marker, isPlausibleNameStart(next) else {
                _ = advance()
                continue
            }

            // Internal entities can expand to element callbacks even
            // though their markup does not appear at the reference site.
            // Do not consume the next real source tag for such a callback:
            // when its ASCII name differs, fall back to XMLParser's line,
            // which points at the physical entity reference and is the
            // only useful source location for a generated node.
            if let namesMatch = asciiTagNameMatches(expectedName),
               !namesMatch {
                return nil
            }
            let linesInsideTag = skipTag()
            return max(1, reportedLine - linesInsideTag)
        }
        return nil
    }

    // Text between elements accounts for nearly all bytes in large GCAM
    // documents. On UTF-8 input, let libc's vectorized memchr jump straight
    // to the next '<' rather than visiting every text byte in Swift.
    @inline(__always)
    private func seekToNextLessThan() -> Bool {
        guard offset < length else { return false }
        if unitWidth == 1 {
            guard let raw = memchr(bytes.advanced(by: offset), 0x3C, length - offset) else {
                offset = length
                return false
            }
            let found = raw.assumingMemoryBound(to: UInt8.self)
            offset = bytes.distance(to: UnsafePointer(found))
            return true
        }
        while let c = peek() {
            if c == 0x3C { return true }
            offset += unitWidth
        }
        return false
    }

    @inline(__always)
    private func isCDATAOpen() -> Bool {
        // We already know offsets 0 and 1 are '<!'.
        let tail: [UInt32] = [0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B]
        for (index, expected) in tail.enumerated() {
            if peek(ahead: index + 2) != expected { return false }
        }
        return true
    }

    private func isPlausibleNameStart(_ c: UInt32) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F || c == 0x3A || c > 0x7F
    }

    private func asciiTagNameMatches(_ expected: String) -> Bool? {
        var expectedIterator = expected.utf8.makeIterator()
        var ahead = 1 // skip '<'
        while let c = peek(ahead: ahead) {
            if c > 0x7F { return nil }
            let isNameChar =
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
                (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x3A ||
                c == 0x2D || c == 0x2E
            if !isNameChar { break }
            guard let expectedByte = expectedIterator.next(),
                  UInt8(c) == expectedByte else { return false }
            ahead += 1
        }
        return expectedIterator.next() == nil
    }

    @discardableResult
    private func skipTag() -> Int {
        var quote: UInt32?
        var newlineCount = 0
        var previousWasCR = false
        while let c = advance() {
            if c == 0x0D {
                newlineCount += 1
                previousWasCR = true
            } else if c == 0x0A {
                if !previousWasCR { newlineCount += 1 }
                previousWasCR = false
            } else {
                previousWasCR = false
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 { // double/single quote
                quote = c
            } else if c == 0x3E { // '>'
                return newlineCount
            }
        }
        return newlineCount
    }

    private func skipDeclaration() {
        var quote: UInt32?
        var subsetDepth = 0
        while peek() != nil {
            if quote == nil,
               peek() == 0x3C, peek(ahead: 1) == 0x21,
               peek(ahead: 2) == 0x2D, peek(ahead: 3) == 0x2D {
                skip(until: Self.commentClose)
                continue
            }
            guard let c = advance() else { return }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x5B { // '[', DOCTYPE internal subset
                subsetDepth += 1
            } else if c == 0x5D, subsetDepth > 0 { // ']'
                subsetDepth -= 1
            } else if c == 0x3E, subsetDepth == 0 {
                return
            }
        }
    }

    private func skip(until units: [UInt32]) {
        while peek() != nil {
            if matches(units) {
                for _ in units { _ = advance() }
                return
            }
            _ = advance()
        }
    }

    @inline(__always)
    private func matches(_ units: [UInt32]) -> Bool {
        for (index, expected) in units.enumerated() {
            if peek(ahead: index) != expected { return false }
        }
        return true
    }

    @inline(__always)
    private func peek(ahead: Int = 0) -> UInt32? {
        let at = offset + ahead * unitWidth
        guard at >= 0, at + unitWidth <= length else { return nil }
        switch unitWidth {
        case 1:
            return UInt32(bytes[at])
        case 2:
            let a = UInt32(bytes[at])
            let b = UInt32(bytes[at + 1])
            return byteOrder == .big ? (a << 8) | b : (b << 8) | a
        default:
            let a = UInt32(bytes[at])
            let b = UInt32(bytes[at + 1])
            let c = UInt32(bytes[at + 2])
            let d = UInt32(bytes[at + 3])
            return byteOrder == .big
                ? (a << 24) | (b << 16) | (c << 8) | d
                : (d << 24) | (c << 16) | (b << 8) | a
        }
    }

    @discardableResult
    @inline(__always)
    private func advance() -> UInt32? {
        guard let c = peek() else { return nil }
        offset += unitWidth
        return c
    }
}
