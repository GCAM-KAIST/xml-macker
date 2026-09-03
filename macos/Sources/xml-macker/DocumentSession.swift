import Cocoa

// One open file = one session (Chrome-style tabs, v0.35.0).
//
// Ownership contract: the ACTIVE tab's canonical state lives in the
// live UI (SourceViewController's text storage, MainWindowController's
// currentTree/currentSelectedNode). A session's fields below are the
// PARKED snapshot, captured by snapshotActiveSession() at the moment
// the user switches away, and poured back by switchToTab(). So a
// freshly created session is mostly empty until its first switch-away.
//
// Memory: a parked session keeps its full NSTextStorage and parsed
// tree alive so switching back is instant (no re-read, no re-parse).
// That's the Chrome trade: N open tabs cost N documents of RAM.
final class DocumentSession {
    // Stable identity keeps asynchronous load/save/validation completions
    // attached to the tab that started them, even after tab switches or Save As.
    let id = UUID()
    var url: URL                    // var: Save As… re-points the active tab
    /// A document that has never been saved anywhere the user chose. It
    /// lives as a real file in a private scratch folder so the ordinary
    /// file-loading path works unchanged, but Save asks where to put it,
    /// it never joins Recent Files or the reopen-at-launch list, and the
    /// scratch copy is thrown away when the app quits.
    var isUntitled = false
    /// The marker strokes of this document, kept per tab so switching
    /// away and back brings them with it.
    let highlights = TextHighlights()
    var fileSize: Int
    var textEncoding: XMLTextEncoding = .utf8
    var fileModificationDate: Date?

    var storage: NSTextStorage?
    var lineStarts: [Int] = [0]
    var tree: XMLTreeNode?
    var parseErrors: [XMLStreamParser.ParseError] = []
    var selectedNode: XMLTreeNode?
    var scrollOrigin: NSPoint = .zero
    var isDirty = false
    // Incremented for every edit. A save clears dirty state only when this
    // revision still matches the snapshot that was actually written.
    var editRevision: UInt64 = 0
    // Set when the document was edited while PARKED (diff copy-hunk):
    // the snapshot tree is stale, so activation triggers a reparse.
    var needsReparse = false

    // Each tab has its OWN undo stack, a shared one would try to
    // replay edit ranges from one document inside another.
    let undoManager = UndoManager()

    // True from loadFile until the parse + text load complete; tab
    // switching is refused while any load is in flight.
    var isLoading = false

    init(url: URL, fileSize: Int) {
        self.url = url
        self.fileSize = fileSize
    }
}
